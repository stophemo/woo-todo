use std::collections::HashSet;
use std::path::Path;

use chrono::NaiveDate;
use rusqlite::types::Type;
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};

use crate::error::{CoreError, CoreResult};
use crate::model::{
    QuestLine, Recurrence, ReminderTime, TIMEZONE, TaskState, TimeType, TodoTask, sort_tasks,
    validate_title,
};
use crate::period::normalize_start;
use crate::settlement::{SettlementResult, settle};

pub struct TaskRepository {
    connection: Connection,
}

impl TaskRepository {
    pub fn open(path: impl AsRef<Path>) -> CoreResult<Self> {
        if let Some(directory) = path.as_ref().parent()
            && !directory.as_os_str().is_empty()
        {
            std::fs::create_dir_all(directory).map_err(|error| {
                CoreError::new("storage", format!("无法创建数据库目录：{error}"))
            })?;
        }
        let connection = Connection::open(path)?;
        connection.execute_batch(
            "PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;",
        )?;
        let repository = Self { connection };
        repository.migrate()?;
        Ok(repository)
    }

    pub fn fetch_all(&self) -> CoreResult<Vec<TodoTask>> {
        let mut statement = self.connection.prepare("SELECT * FROM tasks")?;
        let mut tasks: Vec<TodoTask> = statement
            .query_map([], read_task)?
            .collect::<Result<Vec<_>, _>>()?;
        sort_tasks(&mut tasks);
        Ok(tasks)
    }

    pub fn find(&self, id: &str) -> CoreResult<Option<TodoTask>> {
        self.connection
            .query_row("SELECT * FROM tasks WHERE id = ?1 LIMIT 1", [id], read_task)
            .optional()
            .map_err(Into::into)
    }

    pub fn deleted_task_ids(&self) -> CoreResult<HashSet<String>> {
        let mut statement = self.connection.prepare("SELECT id FROM deleted_tasks")?;
        Ok(statement
            .query_map([], |row| row.get(0))?
            .collect::<Result<HashSet<_>, _>>()?)
    }

    pub fn fetch_scope(
        &self,
        time_type: TimeType,
        reference_date: NaiveDate,
        include_planned: bool,
    ) -> CoreResult<Vec<TodoTask>> {
        let mut tasks: Vec<TodoTask> = self
            .fetch_all()?
            .into_iter()
            .filter(|task| task.time_type == time_type && task.state != TaskState::Pass)
            .filter(|task| {
                if time_type == TimeType::Someday {
                    return true;
                }
                let current = normalize_start(time_type, reference_date);
                if include_planned {
                    task.period_start >= current
                } else {
                    task.period_start == current
                }
            })
            .collect();
        tasks.sort_by(|left, right| {
            left.period_start
                .cmp(&right.period_start)
                .then_with(|| crate::model::compare_tasks(left, right))
        });
        Ok(tasks)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create(
        &mut self,
        title: &str,
        time_type: TimeType,
        target_date: NaiveDate,
        quest_line: QuestLine,
        repeats: bool,
        reminder_time: Option<ReminderTime>,
        now: i64,
    ) -> CoreResult<String> {
        let period_start = normalize_start(time_type, target_date);
        let sort_order = self.next_sort_order(time_type, period_start, quest_line)?;
        let task = TodoTask::create(
            title,
            time_type,
            target_date,
            quest_line,
            repeats,
            sort_order,
            now,
            reminder_time,
            None,
        )?;
        let id = task.id.clone();
        self.save(&task)?;
        Ok(id)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn update(
        &mut self,
        id: &str,
        title: &str,
        time_type: TimeType,
        target_date: NaiveDate,
        quest_line: QuestLine,
        repeats: bool,
        reminder_time: Option<ReminderTime>,
        now: i64,
    ) -> CoreResult<bool> {
        let Some(mut current) = self.find(id)? else {
            return Ok(false);
        };
        if current.state != TaskState::Pending {
            return Ok(false);
        }
        let period_start = normalize_start(time_type, target_date);
        let moved = current.time_type != time_type
            || current.period_start != period_start
            || current.quest_line != quest_line;
        current.title = validate_title(title)?;
        current.time_type = time_type;
        current.period_start = period_start;
        current.quest_line = quest_line;
        current.recurrence = if repeats && time_type != TimeType::Someday {
            Recurrence::Repeat
        } else {
            Recurrence::Once
        };
        if moved {
            current.sort_order = self.next_sort_order(time_type, period_start, quest_line)?;
        }
        current.updated_at = now;
        current.reminder_time = if time_type == TimeType::Someday {
            None
        } else {
            reminder_time
        };
        self.save(&current)?;
        Ok(true)
    }

    pub fn complete(&mut self, id: &str, now: i64) -> CoreResult<bool> {
        self.settle_one(id, TaskState::Completed, now)
    }

    pub fn pass(&mut self, id: &str, now: i64) -> CoreResult<bool> {
        self.settle_one(id, TaskState::Pass, now)
    }

    pub fn move_task(&mut self, id: &str, offset: i32, now: i64) -> CoreResult<bool> {
        if !matches!(offset, -1 | 1) {
            return Err(CoreError::validation("移动偏移量只能是 -1 或 1"));
        }
        let Some(current) = self.find(id)? else {
            return Ok(false);
        };
        if current.state != TaskState::Pending {
            return Ok(false);
        }
        let mut group: Vec<TodoTask> = self
            .fetch_all()?
            .into_iter()
            .filter(|task| {
                task.state == TaskState::Pending
                    && task.time_type == current.time_type
                    && task.period_start == current.period_start
                    && task.quest_line == current.quest_line
            })
            .collect();
        group.sort_by(|left, right| {
            left.sort_order
                .cmp(&right.sort_order)
                .then_with(|| left.created_at.cmp(&right.created_at))
                .then_with(|| left.id.cmp(&right.id))
        });
        let Some(index) = group.iter().position(|task| task.id == id) else {
            return Ok(false);
        };
        let destination = index as i32 + offset;
        if destination < 0 || destination >= group.len() as i32 {
            return Ok(false);
        }
        group.swap(index, destination as usize);
        for (sort_order, task) in group.iter_mut().enumerate() {
            task.sort_order = sort_order as i32;
            task.updated_at = now;
        }
        self.save_many(&group)?;
        Ok(true)
    }

    pub fn delete(&mut self, id: &str, now: i64) -> CoreResult<bool> {
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "DELETE FROM tasks WHERE id = ?1 AND status = 'pending'",
            [id],
        )? == 1;
        if changed {
            transaction.execute(
                "INSERT OR REPLACE INTO deleted_tasks(id, deleted_at) VALUES(?1, ?2)",
                params![id, now],
            )?;
        }
        transaction.commit()?;
        Ok(changed)
    }

    pub fn settle_expired(
        &mut self,
        reference_date: NaiveDate,
        now: i64,
    ) -> CoreResult<SettlementResult> {
        let result = settle(
            &self.fetch_all()?,
            reference_date,
            now,
            &self.deleted_task_ids()?,
        );
        let affected: HashSet<&str> = result
            .changed_task_ids
            .iter()
            .chain(result.generated_task_ids.iter())
            .map(String::as_str)
            .collect();
        if !affected.is_empty() {
            let changed: Vec<TodoTask> = result
                .tasks
                .iter()
                .filter(|task| affected.contains(task.id.as_str()))
                .cloned()
                .collect();
            self.save_many(&changed)?;
        }
        Ok(result)
    }

    pub fn save(&mut self, task: &TodoTask) -> CoreResult<()> {
        self.save_many(std::slice::from_ref(task))
    }

    pub fn save_many(&mut self, tasks: &[TodoTask]) -> CoreResult<()> {
        let transaction = self.connection.transaction()?;
        for task in tasks {
            task.validate()?;
            if is_deleted(&transaction, &task.id)? {
                return Err(CoreError::invalid_state("已删除任务不能恢复"));
            }
            if let Some(existing) = find_in_transaction(&transaction, &task.id)?
                && existing.state != TaskState::Pending
                && existing != *task
            {
                return Err(CoreError::invalid_state("已结算任务不可修改"));
            }
            upsert(&transaction, task)?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn settle_one(&mut self, id: &str, state: TaskState, now: i64) -> CoreResult<bool> {
        if state == TaskState::Pending {
            return Err(CoreError::validation("结算状态不能是 pending"));
        }
        let Some(mut current) = self.find(id)? else {
            return Ok(false);
        };
        if current.state != TaskState::Pending {
            return Ok(false);
        }
        current.state = state;
        current.updated_at = now;
        current.settled_at = Some(now);
        self.save(&current)?;
        Ok(true)
    }

    fn next_sort_order(
        &self,
        time_type: TimeType,
        period_start: Option<NaiveDate>,
        quest_line: QuestLine,
    ) -> CoreResult<i32> {
        let value: i32 = self.connection.query_row(
            r#"
            SELECT COALESCE(MAX(sort_order), -1) + 1 FROM tasks
            WHERE time_type = ?1 AND quest_line = ?2
              AND ((?3 IS NULL AND period_start IS NULL) OR period_start = ?3)
            "#,
            params![
                time_type_wire(time_type),
                quest_line_wire(quest_line),
                period_start.map(|value| value.format("%Y-%m-%d").to_string())
            ],
            |row| row.get(0),
        )?;
        Ok(value)
    }

    fn migrate(&self) -> CoreResult<()> {
        self.connection.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS tasks(
              id TEXT NOT NULL PRIMARY KEY,
              series_id TEXT NOT NULL,
              title TEXT NOT NULL,
              time_type TEXT NOT NULL CHECK(time_type IN ('day','week','month','someday')),
              period_start TEXT,
              quest_line TEXT NOT NULL CHECK(quest_line IN ('main','side','extra')),
              status TEXT NOT NULL CHECK(status IN ('pending','completed','pass')),
              recurrence TEXT NOT NULL CHECK(recurrence IN ('once','repeat')),
              sort_order INTEGER NOT NULL CHECK(sort_order >= 0),
              created_at INTEGER NOT NULL CHECK(created_at >= 0),
              updated_at INTEGER NOT NULL CHECK(updated_at >= 0),
              settled_at INTEGER,
              reminder_time TEXT,
              CHECK((time_type = 'someday' AND period_start IS NULL AND recurrence = 'once' AND reminder_time IS NULL)
                 OR (time_type != 'someday' AND period_start IS NOT NULL)),
              CHECK((status = 'pending' AND settled_at IS NULL) OR (status != 'pending' AND settled_at IS NOT NULL))
            );
            CREATE INDEX IF NOT EXISTS idx_tasks_scope ON tasks(time_type, period_start);
            CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
            CREATE TABLE IF NOT EXISTS deleted_tasks(
              id TEXT NOT NULL PRIMARY KEY,
              deleted_at INTEGER NOT NULL CHECK(deleted_at >= 0)
            );
            PRAGMA user_version = 1;
            "#,
        )?;
        Ok(())
    }
}

fn read_task(row: &Row<'_>) -> rusqlite::Result<TodoTask> {
    let period_start: Option<String> = row.get("period_start")?;
    let reminder_time: Option<String> = row.get("reminder_time")?;
    Ok(TodoTask {
        id: row.get("id")?,
        series_id: row.get("series_id")?,
        title: row.get("title")?,
        time_type: parse_time_type(&row.get::<_, String>("time_type")?)?,
        period_start: period_start.map(|value| parse_date(&value)).transpose()?,
        timezone: TIMEZONE.to_owned(),
        quest_line: parse_quest_line(&row.get::<_, String>("quest_line")?)?,
        state: parse_state(&row.get::<_, String>("status")?)?,
        recurrence: parse_recurrence(&row.get::<_, String>("recurrence")?)?,
        sort_order: row.get("sort_order")?,
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
        settled_at: row.get("settled_at")?,
        reminder_time: reminder_time
            .map(|value| ReminderTime::parse(&value).map_err(sql_conversion))
            .transpose()?,
    })
}

fn find_in_transaction(transaction: &Transaction<'_>, id: &str) -> CoreResult<Option<TodoTask>> {
    transaction
        .query_row("SELECT * FROM tasks WHERE id = ?1 LIMIT 1", [id], read_task)
        .optional()
        .map_err(Into::into)
}

fn is_deleted(transaction: &Transaction<'_>, id: &str) -> CoreResult<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM deleted_tasks WHERE id = ?1 LIMIT 1",
            [id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn upsert(transaction: &Transaction<'_>, task: &TodoTask) -> CoreResult<()> {
    transaction.execute(
        r#"
        INSERT INTO tasks(
          id, series_id, title, time_type, period_start, quest_line, status,
          recurrence, sort_order, created_at, updated_at, settled_at, reminder_time
        ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
        ON CONFLICT(id) DO UPDATE SET
          series_id = excluded.series_id, title = excluded.title,
          time_type = excluded.time_type, period_start = excluded.period_start,
          quest_line = excluded.quest_line, status = excluded.status,
          recurrence = excluded.recurrence, sort_order = excluded.sort_order,
          created_at = excluded.created_at, updated_at = excluded.updated_at,
          settled_at = excluded.settled_at, reminder_time = excluded.reminder_time
        "#,
        params![
            task.id,
            task.series_id,
            task.title,
            time_type_wire(task.time_type),
            task.period_start
                .map(|value| value.format("%Y-%m-%d").to_string()),
            quest_line_wire(task.quest_line),
            state_wire(task.state),
            recurrence_wire(task.recurrence),
            task.sort_order,
            task.created_at,
            task.updated_at,
            task.settled_at,
            task.reminder_time.map(ReminderTime::wire_value),
        ],
    )?;
    Ok(())
}

fn parse_date(value: &str) -> rusqlite::Result<NaiveDate> {
    NaiveDate::parse_from_str(value, "%Y-%m-%d").map_err(sql_conversion)
}

fn parse_time_type(value: &str) -> rusqlite::Result<TimeType> {
    match value {
        "day" => Ok(TimeType::Day),
        "week" => Ok(TimeType::Week),
        "month" => Ok(TimeType::Month),
        "someday" => Ok(TimeType::Someday),
        _ => Err(sql_conversion(CoreError::validation(
            "数据库 time_type 无效",
        ))),
    }
}

fn parse_quest_line(value: &str) -> rusqlite::Result<QuestLine> {
    match value {
        "main" => Ok(QuestLine::Main),
        "side" => Ok(QuestLine::Side),
        "extra" => Ok(QuestLine::Extra),
        _ => Err(sql_conversion(CoreError::validation(
            "数据库 quest_line 无效",
        ))),
    }
}

fn parse_state(value: &str) -> rusqlite::Result<TaskState> {
    match value {
        "pending" => Ok(TaskState::Pending),
        "completed" => Ok(TaskState::Completed),
        "pass" => Ok(TaskState::Pass),
        _ => Err(sql_conversion(CoreError::validation("数据库 status 无效"))),
    }
}

fn parse_recurrence(value: &str) -> rusqlite::Result<Recurrence> {
    match value {
        "once" => Ok(Recurrence::Once),
        "repeat" => Ok(Recurrence::Repeat),
        _ => Err(sql_conversion(CoreError::validation(
            "数据库 recurrence 无效",
        ))),
    }
}

fn sql_conversion(error: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error))
}

fn time_type_wire(value: TimeType) -> &'static str {
    crate::period::time_type_wire(value)
}

fn quest_line_wire(value: QuestLine) -> &'static str {
    match value {
        QuestLine::Main => "main",
        QuestLine::Side => "side",
        QuestLine::Extra => "extra",
    }
}

fn state_wire(value: TaskState) -> &'static str {
    match value {
        TaskState::Pending => "pending",
        TaskState::Completed => "completed",
        TaskState::Pass => "pass",
    }
}

fn recurrence_wire(value: Recurrence) -> &'static str {
    match value {
        Recurrence::Once => "once",
        Recurrence::Repeat => "repeat",
    }
}
