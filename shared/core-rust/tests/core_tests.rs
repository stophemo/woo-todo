use std::collections::HashSet;

use chrono::NaiveDate;
use rusqlite::Connection;
use tempfile::tempdir;
use woo_todo_core::{
    QuestLine, Recurrence, ReminderTime, TaskRepository, TaskState, TimeType, TodoTask,
    notification_plans, occurrence_id, settle,
};

fn date(value: &str) -> NaiveDate {
    NaiveDate::parse_from_str(value, "%Y-%m-%d").expect("测试日期应有效")
}

fn task(id: &str, start: &str, repeats: bool, now: i64) -> TodoTask {
    TodoTask::create(
        "每日复盘",
        TimeType::Day,
        date(start),
        QuestLine::Main,
        repeats,
        0,
        now,
        Some(ReminderTime::new(9, 30).expect("测试提醒时间应有效")),
        None,
        Some(id.to_owned()),
    )
    .expect("测试任务应有效")
}

#[test]
fn occurrence_id_matches_existing_clients() {
    assert_eq!(
        occurrence_id(
            "00000000-0000-4000-8000-000000000001",
            TimeType::Day,
            date("2026-07-16"),
        ),
        "62903272-1c56-5012-9f10-103da3868d05"
    );
}

#[test]
fn settlement_catches_up_and_is_idempotent_across_periods() {
    let mut original = task(
        "00000000-0000-4000-8000-000000000001",
        "2026-07-20",
        true,
        1,
    );
    original.deadline_date = Some(date("2026-07-21"));
    let first = settle(&[original], date("2026-07-24"), 2, &HashSet::new());
    assert_eq!(first.tasks.len(), 5);
    assert_eq!(first.changed_task_ids.len(), 4);
    assert_eq!(first.generated_task_ids.len(), 4);
    assert!(first.tasks.iter().any(|task| {
        task.period_start == Some(date("2026-07-24")) && task.state == TaskState::Pending
    }));
    assert!(
        first
            .tasks
            .iter()
            .filter(|task| task.period_start != Some(date("2026-07-20")))
            .all(|task| task.deadline_date.is_none())
    );

    let second = settle(&first.tasks, date("2026-07-24"), 3, &HashSet::new());
    assert_eq!(second.tasks, first.tasks);
    assert!(second.changed_task_ids.is_empty());
    assert!(second.generated_task_ids.is_empty());
}

#[test]
fn settlement_does_not_restore_deleted_occurrence() {
    let original = task(
        "00000000-0000-4000-8000-000000000099",
        "2026-07-23",
        true,
        1,
    );
    let deleted = occurrence_id(&original.series_id, TimeType::Day, date("2026-07-24"));
    let reserved = HashSet::from([deleted.clone()]);
    let result = settle(&[original], date("2026-07-24"), 2, &reserved);
    assert_eq!(result.tasks.len(), 1);
    assert!(result.tasks.iter().all(|task| task.id != deleted));
}

#[test]
fn overdue_once_task_stays_pending_until_user_settles_it() {
    let original = task(
        "00000000-0000-4000-8000-000000000098",
        "2026-07-20",
        false,
        1,
    );

    let result = settle(
        std::slice::from_ref(&original),
        date("2026-07-24"),
        2,
        &HashSet::new(),
    );

    assert_eq!(result.tasks, vec![original]);
    assert!(result.changed_task_ids.is_empty());
    assert!(result.generated_task_ids.is_empty());
}

#[test]
fn notification_plan_is_stable_and_only_contains_pending_scheduled_tasks() {
    let pending = task(
        "00000000-0000-4000-8000-000000000010",
        "2026-07-24",
        false,
        1,
    );
    let mut completed = task(
        "00000000-0000-4000-8000-000000000011",
        "2026-07-24",
        false,
        1,
    );
    completed.state = TaskState::Completed;
    completed.settled_at = Some(2);
    completed.updated_at = 2;
    let plans = notification_plans(&[completed, pending.clone()]);
    assert_eq!(plans.len(), 1);
    assert_eq!(plans[0].task_id, pending.id);
    assert_eq!(plans[0].fire_date, "2026-07-24");
    assert_eq!(plans[0].fire_time, "09:30");
    assert_eq!(
        plans[0].id,
        "task-reminder:00000000-0000-4000-8000-000000000010:2026-07-24:09:30"
    );
    assert_eq!(notification_plans(&[pending]), plans);
}

#[test]
fn repository_round_trips_and_settles_idempotently() {
    let directory = tempdir().expect("应创建临时目录");
    let database = directory.path().join("tasks.sqlite3");
    let mut repository = TaskRepository::open(&database).expect("应打开数据库");
    let id = repository
        .create(
            "月度复盘",
            TimeType::Month,
            date("2026-05-22"),
            QuestLine::Main,
            true,
            None,
            None,
            1,
        )
        .expect("应创建任务");
    assert_eq!(repository.find(&id).unwrap().unwrap().title, "月度复盘");
    let first = repository
        .settle_expired(date("2026-07-24"), 2)
        .expect("应结算任务");
    assert_eq!(first.tasks.len(), 3);
    drop(repository);

    let mut reopened = TaskRepository::open(&database).expect("应重新打开数据库");
    assert_eq!(reopened.fetch_all().unwrap().len(), 3);
    let second = reopened
        .settle_expired(date("2026-07-24"), 3)
        .expect("重复结算应成功");
    assert!(second.changed_task_ids.is_empty());
    assert!(second.generated_task_ids.is_empty());
}

#[test]
fn repository_round_trips_optional_deadline() {
    let directory = tempdir().expect("应创建临时目录");
    let database = directory.path().join("deadline.sqlite3");
    let mut repository = TaskRepository::open(&database).expect("应打开数据库");
    let deadline = date("2026-08-05");

    let once_id = repository
        .create(
            "带截止日期的任务",
            TimeType::Day,
            date("2026-07-28"),
            QuestLine::Main,
            false,
            None,
            Some(deadline),
            1,
        )
        .expect("应创建一次性任务");
    assert_eq!(
        repository.find(&once_id).unwrap().unwrap().deadline_date,
        Some(deadline)
    );

    drop(repository);
    let reopened = TaskRepository::open(&database).expect("应重新打开数据库");
    assert_eq!(
        reopened.find(&once_id).unwrap().unwrap().deadline_date,
        Some(deadline)
    );
}

#[test]
fn repository_keeps_overdue_once_tasks_in_current_scope() {
    let directory = tempdir().expect("应创建临时目录");
    let database = directory.path().join("overdue-once.sqlite3");
    let mut repository = TaskRepository::open(&database).expect("应打开数据库");
    let today = woo_todo_core::today_shanghai();
    let yesterday = today.pred_opt().expect("今天应有前一天");
    let once_id = repository
        .create(
            "跨日后仍待办",
            TimeType::Day,
            yesterday,
            QuestLine::Main,
            false,
            None,
            None,
            1,
        )
        .unwrap();
    let repeat_id = repository
        .create(
            "跨日重复任务",
            TimeType::Day,
            yesterday,
            QuestLine::Side,
            true,
            None,
            None,
            1,
        )
        .unwrap();

    let first = repository.settle_expired(today, 2).unwrap();
    assert_eq!(
        first.changed_task_ids,
        HashSet::from([repeat_id]).into_iter().collect()
    );
    assert_eq!(
        repository.find(&once_id).unwrap().unwrap().state,
        TaskState::Pending
    );
    let visible = repository
        .fetch_scope(TimeType::Day, today, false)
        .expect("应读取今日任务");
    assert!(visible.iter().any(|task| task.id == once_id));

    let second = repository.settle_expired(today, 3).unwrap();
    assert!(second.changed_task_ids.is_empty());
    assert!(second.generated_task_ids.is_empty());

    assert!(repository.complete(&once_id, 4).unwrap());
    assert!(repository.reopen_completed(&once_id, today, 5).unwrap());
    assert!(repository.pass(&once_id, 6).unwrap());
    let visible = repository
        .fetch_scope(TimeType::Day, today, false)
        .expect("应重新读取今日任务");
    assert!(visible.iter().all(|task| task.id != once_id));
}

#[test]
fn repository_migrates_v1_database_without_losing_tasks() {
    let directory = tempdir().expect("应创建临时目录");
    let database = directory.path().join("legacy.sqlite3");
    let connection = Connection::open(&database).expect("应创建旧数据库");
    connection
        .execute_batch(
            r#"
            CREATE TABLE tasks(
              id TEXT NOT NULL PRIMARY KEY, series_id TEXT NOT NULL, title TEXT NOT NULL,
              time_type TEXT NOT NULL, period_start TEXT, quest_line TEXT NOT NULL,
              status TEXT NOT NULL, recurrence TEXT NOT NULL, sort_order INTEGER NOT NULL,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, settled_at INTEGER,
              reminder_time TEXT
            );
            CREATE TABLE deleted_tasks(
              id TEXT NOT NULL PRIMARY KEY, deleted_at INTEGER NOT NULL
            );
            INSERT INTO tasks VALUES(
              '00000000-0000-4000-8000-000000000088',
              '00000000-0000-4000-8000-000000000088',
              '旧版任务', 'day', '2026-07-28', 'main', 'pending', 'once',
              0, 1, 1, NULL, NULL
            );
            PRAGMA user_version = 1;
            "#,
        )
        .expect("应写入旧数据库");
    drop(connection);

    let repository = TaskRepository::open(&database).expect("应迁移旧数据库");
    let restored = repository.fetch_all().expect("应读取迁移后的任务");
    assert_eq!(restored.len(), 1);
    assert_eq!(restored[0].title, "旧版任务");
    assert_eq!(restored[0].deadline_date, None);
    drop(repository);

    let connection = Connection::open(&database).unwrap();
    let version: i64 = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, 3);
}

#[test]
fn task_json_accepts_missing_deadline_and_round_trips_present_deadline() {
    let without_deadline = task(
        "00000000-0000-4000-8000-000000000087",
        "2026-07-28",
        false,
        1,
    );
    let mut legacy_json = serde_json::to_value(&without_deadline).unwrap();
    legacy_json
        .as_object_mut()
        .expect("任务 JSON 应为对象")
        .remove("deadlineDate");
    let decoded: TodoTask = serde_json::from_value(legacy_json).expect("应兼容旧正文");
    assert_eq!(decoded.deadline_date, None);

    let mut with_deadline = without_deadline;
    with_deadline.deadline_date = Some(date("2026-08-05"));
    let encoded = serde_json::to_value(&with_deadline).expect("应编码任务");
    assert_eq!(encoded["deadlineDate"], "2026-08-05");
    assert_eq!(
        serde_json::from_value::<TodoTask>(encoded)
            .unwrap()
            .deadline_date,
        with_deadline.deadline_date
    );

    with_deadline.deadline_date = NaiveDate::from_ymd_opt(0, 1, 1);
    assert!(with_deadline.validate().is_err());
}

#[test]
fn repository_rejects_deleted_and_mutated_settled_tasks_transactionally() {
    let directory = tempdir().expect("应创建临时目录");
    let database = directory.path().join("tasks.sqlite3");
    let mut repository = TaskRepository::open(&database).expect("应打开数据库");
    let deleted = task(
        "00000000-0000-4000-8000-000000000077",
        "2026-07-24",
        false,
        1,
    );
    repository.save(&deleted).unwrap();
    assert!(repository.delete(&deleted.id, 2).unwrap());
    assert!(repository.save(&deleted).is_err());

    let settled_id = repository
        .create(
            "只结算一次",
            TimeType::Day,
            date("2026-07-24"),
            QuestLine::Main,
            false,
            None,
            None,
            3,
        )
        .unwrap();
    assert!(repository.complete(&settled_id, 4).unwrap());
    let settled = repository.find(&settled_id).unwrap().unwrap();
    repository.save(&settled).expect("相同历史应幂等保存");
    let mut mutated = settled.clone();
    mutated.title = "不能修改历史".to_owned();
    assert!(repository.save(&mutated).is_err());

    let valid = task(
        "00000000-0000-4000-8000-000000000078",
        "2026-07-24",
        false,
        5,
    );
    assert!(repository.save_many(&[valid.clone(), deleted]).is_err());
    assert!(repository.find(&valid.id).unwrap().is_none());
}

#[test]
fn repository_clears_selected_and_all_history_idempotently() {
    let directory = tempdir().expect("应创建临时目录");
    let database = directory.path().join("clear-history.sqlite3");
    let mut repository = TaskRepository::open(&database).expect("应打开数据库");
    let completed_id = repository
        .create(
            "已完成",
            TimeType::Day,
            date("2026-07-24"),
            QuestLine::Main,
            false,
            None,
            None,
            1,
        )
        .unwrap();
    let passed_id = repository
        .create(
            "已 Pass",
            TimeType::Day,
            date("2026-07-24"),
            QuestLine::Side,
            false,
            None,
            None,
            2,
        )
        .unwrap();
    let pending_id = repository
        .create(
            "保留待办",
            TimeType::Day,
            date("2026-07-24"),
            QuestLine::Extra,
            false,
            None,
            None,
            3,
        )
        .unwrap();
    assert!(repository.complete(&completed_id, 4).unwrap());
    assert!(repository.pass(&passed_id, 5).unwrap());

    let selected = HashSet::from([completed_id.clone(), pending_id.clone()]);
    assert_eq!(repository.clear_history(Some(&selected), 6).unwrap(), 1);
    assert_eq!(repository.clear_history(Some(&selected), 7).unwrap(), 0);
    assert!(repository.find(&pending_id).unwrap().is_some());
    assert!(repository.find(&passed_id).unwrap().is_some());

    assert_eq!(repository.clear_history(None, 8).unwrap(), 1);
    assert_eq!(repository.clear_history(None, 9).unwrap(), 0);
    assert_eq!(repository.fetch_all().unwrap().len(), 1);
    assert_eq!(
        repository.deleted_task_ids().unwrap(),
        HashSet::from([completed_id, passed_id])
    );
}

#[test]
fn repository_reopens_only_current_completed_tasks_and_resettles_idempotently() {
    let directory = tempdir().expect("应创建临时目录");
    let database = directory.path().join("tasks.sqlite3");
    let mut repository = TaskRepository::open(&database).expect("应打开数据库");
    let id = repository
        .create(
            "误点完成的每日复盘",
            TimeType::Day,
            date("2026-07-24"),
            QuestLine::Main,
            true,
            None,
            None,
            1,
        )
        .unwrap();

    assert!(repository.complete(&id, 2).unwrap());
    assert!(
        repository
            .reopen_completed(&id, date("2026-07-24"), 3)
            .unwrap()
    );
    assert!(
        !repository
            .reopen_completed(&id, date("2026-07-24"), 4)
            .unwrap()
    );
    let reopened = repository.find(&id).unwrap().unwrap();
    assert_eq!(reopened.state, TaskState::Pending);
    assert_eq!(reopened.updated_at, 3);
    assert_eq!(reopened.settled_at, None);

    let first = repository
        .settle_expired(date("2026-07-25"), 5)
        .expect("跨日后应重新结算");
    assert_eq!(first.changed_task_ids.len(), 1);
    assert_eq!(first.generated_task_ids.len(), 1);
    assert_eq!(repository.fetch_all().unwrap().len(), 2);
    let second = repository
        .settle_expired(date("2026-07-25"), 6)
        .expect("重复结算应幂等");
    assert!(second.changed_task_ids.is_empty());
    assert!(second.generated_task_ids.is_empty());

    assert!(
        !repository
            .reopen_completed(&id, date("2026-07-25"), 7)
            .unwrap()
    );
    let next_id = first.generated_task_ids.iter().next().unwrap();
    assert!(repository.pass(next_id, 8).unwrap());
    assert!(
        !repository
            .reopen_completed(next_id, date("2026-07-25"), 9)
            .unwrap()
    );
}

#[test]
fn someday_task_cannot_repeat_or_schedule_notification() {
    let mut value = TodoTask::create(
        "闲时阅读",
        TimeType::Someday,
        date("2026-07-24"),
        QuestLine::Extra,
        true,
        0,
        1,
        Some(ReminderTime::new(8, 0).unwrap()),
        None,
        Some("00000000-0000-4000-8000-000000000090".to_owned()),
    )
    .unwrap();
    assert_eq!(value.recurrence, Recurrence::Once);
    assert!(value.reminder_time.is_none());
    assert!(notification_plans(&[value.clone()]).is_empty());

    value.recurrence = Recurrence::Repeat;
    assert!(value.validate().is_err());
}
