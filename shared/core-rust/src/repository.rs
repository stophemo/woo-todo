use std::collections::HashSet;
use std::path::Path;

use chrono::{NaiveDate, Utc};
use rusqlite::types::Type;
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};

use crate::error::{CoreError, CoreResult};
use crate::model::{
    QuestLine, Recurrence, ReminderTime, TIMEZONE, TaskState, TimeType, TodoTask, sort_tasks,
    validate_title,
};
use crate::period::{is_expired, normalize_start, today_shanghai};
use crate::settlement::{SettlementResult, settle};
use crate::sync::{OperationCodec, SyncConfiguration, SyncState, WebDavOperation};
use crate::wire::{
    DISPLAY_CONFIGURATION_ENTITY_ID, OperationKind, SyncPulledOperation, SyncPushOperation,
    WireDisplayConfigurationPayload, WireEntity, WireTaskPayload, WireTombstonePayload,
    canonical_entity_id,
};

/// 客户端保留的“已应用操作”记录窗口。窗口外的重复应用由 opId 幂等
/// 与 LWW 合并保证安全，因此可以在此窗口外裁剪以控制表体积。
const APPLIED_OPERATION_RETENTION: i64 = 10_000;

pub struct TaskRepository {
    connection: Connection,
    sync_configuration: Option<SyncConfiguration>,
    has_persisted_sync_identity: bool,
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
        let mut repository = Self {
            connection,
            sync_configuration: None,
            has_persisted_sync_identity: false,
        };
        repository.migrate()?;
        repository.has_persisted_sync_identity = repository.persisted_sync_identity()?.is_some();
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
                let overdue_once = normalize_start(time_type, today_shanghai()) == current
                    && task.state == TaskState::Pending
                    && task.recurrence == Recurrence::Once
                    && task.period_start < current;
                if include_planned {
                    task.period_start >= current || overdue_once
                } else {
                    task.period_start == current || overdue_once
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
        deadline_date: Option<NaiveDate>,
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
            deadline_date,
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
        deadline_date: Option<NaiveDate>,
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
        current.deadline_date = deadline_date;
        self.save(&current)?;
        Ok(true)
    }

    pub fn complete(&mut self, id: &str, now: i64) -> CoreResult<bool> {
        self.settle_one(id, TaskState::Completed, now)
    }

    pub fn pass(&mut self, id: &str, now: i64) -> CoreResult<bool> {
        self.settle_one(id, TaskState::Pass, now)
    }

    pub fn reopen_completed(
        &mut self,
        id: &str,
        reference_date: NaiveDate,
        now: i64,
    ) -> CoreResult<bool> {
        let Some(current) = self.find(id)? else {
            return Ok(false);
        };
        if current.state != TaskState::Completed
            || (current.recurrence == Recurrence::Repeat && is_expired(&current, reference_date))
        {
            return Ok(false);
        }
        let configuration = self.sync_configuration.clone();
        let has_identity = self.has_persisted_sync_identity;
        let transaction = self.connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE tasks SET status = 'pending', updated_at = ?2, settled_at = NULL WHERE id = ?1 AND status = 'completed'",
            params![id, now],
        )? == 1;
        if changed {
            let mut reopened = current;
            reopened.state = TaskState::Pending;
            reopened.updated_at = now;
            reopened.settled_at = None;
            record_local_task_change(
                &transaction,
                &reopened,
                OperationKind::Reopen,
                configuration.as_ref(),
                has_identity,
            )?;
        }
        transaction.commit()?;
        Ok(changed)
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
        let configuration = self.sync_configuration.clone();
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
            let entity_id = canonical_entity_id(id);
            if let Some(configuration) = configuration.as_ref() {
                enqueue_local_tombstone(&transaction, &entity_id, now, configuration)?;
            } else {
                remove_deferred_upsert(&transaction, &entity_id)?;
                record_deferred_deletion(&transaction, &entity_id, now)?;
            }
        }
        transaction.commit()?;
        Ok(changed)
    }

    pub fn clear_history(&mut self, ids: Option<&HashSet<String>>, now: i64) -> CoreResult<usize> {
        if ids.is_some_and(HashSet::is_empty) {
            return Ok(0);
        }
        let requested_ids = ids.map(|values| {
            values
                .iter()
                .map(|id| canonical_entity_id(id))
                .collect::<HashSet<_>>()
        });
        let target_ids = {
            let mut statement = self
                .connection
                .prepare("SELECT id FROM tasks WHERE status IN ('completed', 'pass')")?;
            statement
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .filter(|id| {
                    requested_ids
                        .as_ref()
                        .is_none_or(|values| values.contains(&canonical_entity_id(id)))
                })
                .collect::<Vec<_>>()
        };
        if target_ids.is_empty() {
            return Ok(0);
        }

        let configuration = self.sync_configuration.clone();
        let transaction = self.connection.transaction()?;
        let mut deleted_count = 0;
        for id in target_ids {
            let changed = transaction.execute(
                "DELETE FROM tasks WHERE id = ?1 AND status IN ('completed', 'pass')",
                [&id],
            )? == 1;
            if !changed {
                continue;
            }
            transaction.execute(
                "INSERT OR REPLACE INTO deleted_tasks(id, deleted_at) VALUES(?1, ?2)",
                params![id, now],
            )?;
            let entity_id = canonical_entity_id(&id);
            if let Some(configuration) = configuration.as_ref() {
                enqueue_local_tombstone(&transaction, &entity_id, now, configuration)?;
            } else {
                remove_deferred_upsert(&transaction, &entity_id)?;
                record_deferred_deletion(&transaction, &entity_id, now)?;
            }
            deleted_count += 1;
        }
        transaction.commit()?;
        Ok(deleted_count)
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
        let configuration = self.sync_configuration.clone();
        let has_identity = self.has_persisted_sync_identity;
        let transaction = self.connection.transaction()?;
        for task in tasks {
            task.validate()?;
            if is_deleted(&transaction, &task.id)? {
                return Err(CoreError::invalid_state("已删除任务不能恢复"));
            }
            let existing = find_in_transaction(&transaction, &task.id)?;
            if existing.as_ref() == Some(task) {
                continue;
            }
            if let Some(existing) = existing.as_ref()
                && existing.state != TaskState::Pending
            {
                return Err(CoreError::invalid_state("已结算任务不可修改"));
            }
            upsert(&transaction, task)?;
            record_local_task_change(
                &transaction,
                task,
                operation_kind(existing.as_ref(), task),
                configuration.as_ref(),
                has_identity,
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn validate_sync_binding(&self, vault_id: &str, device_id: &str) -> CoreResult<()> {
        validate_sync_identity(vault_id, device_id)?;
        if let Some((stored_vault, stored_device)) = self.persisted_sync_identity()?
            && (stored_vault != vault_id || stored_device != device_id)
        {
            return Err(CoreError::new(
                "sync_identity_mismatch",
                "本地数据库已绑定到另一同步空间或设备",
            ));
        }
        Ok(())
    }

    pub fn configure_sync(&mut self, configuration: SyncConfiguration) -> CoreResult<()> {
        self.validate_sync_binding(&configuration.vault_id, &configuration.device_id)?;
        if self.persisted_sync_identity()?.is_some() {
            let transaction = self.connection.transaction()?;
            recover_deferred_changes(&transaction, &configuration)?;
            transaction.commit()?;
            self.sync_configuration = Some(configuration);
            self.has_persisted_sync_identity = true;
            return Ok(());
        }

        let transaction = self.connection.transaction()?;
        bind_unbound_sync(&transaction, &configuration)?;
        transaction.commit()?;
        self.sync_configuration = Some(configuration);
        self.has_persisted_sync_identity = true;
        Ok(())
    }

    pub fn reset_sync_binding(&mut self) -> CoreResult<()> {
        let transaction = self.connection.transaction()?;
        reset_sync_metadata(&transaction)?;
        transaction.commit()?;
        self.sync_configuration = None;
        self.has_persisted_sync_identity = false;
        Ok(())
    }

    /// 清空本地任务（含删除记录），不生成任何同步操作。
    ///
    /// 用于加入已有同步空间时以远端数据为准：本地任务从本机移除，
    /// 同步 outbox 与延迟写入队列一并清空，因此不会上传、不会影响
    /// 其他设备的真实数据；之后的首次同步会把同步空间的全部数据
    /// 拉到本机。应在 [`Self::replace_sync_binding_with_lamport_floor`]
    /// 之后调用，否则绑定过程会把保留的本地任务重新写入 outbox。
    pub fn clear_local_tasks(&mut self) -> CoreResult<()> {
        let transaction = self.connection.transaction()?;
        transaction.execute("DELETE FROM tasks", [])?;
        transaction.execute("DELETE FROM deleted_tasks", [])?;
        transaction.execute("DELETE FROM sync_outbox", [])?;
        transaction.execute("DELETE FROM sync_deferred_upserts", [])?;
        transaction.execute("DELETE FROM sync_deferred_deletions", [])?;
        transaction.commit()?;
        Ok(())
    }

    pub fn replace_sync_binding(&mut self, configuration: SyncConfiguration) -> CoreResult<()> {
        self.replace_sync_binding_with_lamport_floor(configuration, 0)
    }

    pub fn replace_sync_binding_with_lamport_floor(
        &mut self,
        configuration: SyncConfiguration,
        lamport_floor: i64,
    ) -> CoreResult<()> {
        validate_sync_identity(&configuration.vault_id, &configuration.device_id)?;
        if !(0..i64::MAX).contains(&lamport_floor) {
            return Err(CoreError::validation("Lamport 下限必须为非负且可递增"));
        }
        let transaction = self.connection.transaction()?;
        reset_sync_metadata(&transaction)?;
        transaction.execute(
            "UPDATE sync_state SET lamport = ?1 WHERE singleton = 1",
            [lamport_floor],
        )?;
        bind_unbound_sync(&transaction, &configuration)?;
        transaction.commit()?;
        self.sync_configuration = Some(configuration);
        self.has_persisted_sync_identity = true;
        Ok(())
    }

    pub fn clear_runtime_sync_key(&mut self) {
        self.sync_configuration = None;
    }

    pub fn sync_state(&self) -> CoreResult<SyncState> {
        self.connection
            .query_row(
                r#"
                SELECT vault_id, device_id, cursor, lamport,
                  (SELECT COUNT(*) FROM sync_outbox),
                  (SELECT COUNT(*) FROM sync_entity_versions),
                  (SELECT COUNT(*) FROM sync_applied_operations),
                  (SELECT COUNT(*) FROM sync_deferred_upserts),
                  (SELECT COUNT(*) FROM sync_deferred_deletions),
                  EXISTS(SELECT 1 FROM sync_deferred_display_configuration)
                FROM sync_state WHERE singleton = 1
                "#,
                [],
                |row| {
                    Ok(SyncState {
                        vault_id: row.get(0)?,
                        device_id: row.get(1)?,
                        cursor: row.get(2)?,
                        lamport: row.get(3)?,
                        outbox_count: row.get(4)?,
                        entity_version_count: row.get(5)?,
                        applied_operation_count: row.get(6)?,
                        deferred_upsert_count: row.get(7)?,
                        deferred_deletion_count: row.get(8)?,
                        has_deferred_display_configuration: row.get::<_, i64>(9)? != 0,
                    })
                },
            )
            .map_err(Into::into)
    }

    pub fn pending_operations(&self, limit: usize) -> CoreResult<Vec<SyncPushOperation>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let mut statement = self.connection.prepare(
            r#"
            SELECT op_id, entity_id, kind, lamport, ciphertext, nonce
            FROM sync_outbox ORDER BY lamport, op_id LIMIT ?1
            "#,
        )?;
        statement
            .query_map([i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
                let kind = parse_operation_kind(&row.get::<_, String>(2)?)?;
                Ok(SyncPushOperation {
                    op_id: row.get(0)?,
                    entity_id: row.get(1)?,
                    kind,
                    lamport: row.get(3)?,
                    ciphertext: row.get(4)?,
                    nonce: row.get(5)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub fn acknowledge_operations(&mut self, operation_ids: &[String]) -> CoreResult<()> {
        if operation_ids.is_empty() {
            return Ok(());
        }
        let unique = operation_ids.iter().collect::<HashSet<_>>();
        let transaction = self.connection.transaction()?;
        for operation_id in unique {
            transaction.execute("DELETE FROM sync_outbox WHERE op_id = ?1", [operation_id])?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn current_cursor(&self) -> CoreResult<i64> {
        sync_state_number(&self.connection, "cursor")
    }

    /// 把本地同步游标重置为 0（服务端游标被重置或丢失时使用）。
    ///
    /// 仅在服务端返回 `CURSOR_AHEAD`（客户端游标超过服务端最新序号）时由
    /// 同步运行时调用：重置后从 0 重新拉取，配合已应用的 opId 记录去重，
    /// 不会重复应用已有操作；本地任务与 outbox 不受影响。
    pub fn reset_cursor(&mut self) -> CoreResult<()> {
        let transaction = self.connection.transaction()?;
        transaction.execute("UPDATE sync_state SET cursor = 0 WHERE singleton = 1", [])?;
        transaction.commit()?;
        Ok(())
    }

    pub fn apply_remote_operations(
        &mut self,
        operations: &[SyncPulledOperation],
        cursor: i64,
    ) -> CoreResult<()> {
        let configuration = self
            .sync_configuration
            .clone()
            .ok_or_else(|| CoreError::new("sync_credentials_unavailable", "同步密钥当前不可用"))?;
        let previous_cursor = self.current_cursor()?;
        validate_remote_page(operations, previous_cursor, cursor)?;
        let transaction = self.connection.transaction()?;
        for operation in operations {
            if is_operation_applied(&transaction, &operation.op_id)? {
                continue;
            }
            apply_remote_operation(&transaction, operation, &configuration)?;
            transaction.execute(
                "INSERT INTO sync_applied_operations(op_id, server_seq, applied_at) VALUES(?1, ?2, ?3)",
                params![operation.op_id, operation.server_seq, now_millis()],
            )?;
            transaction.execute(
                "UPDATE sync_state SET lamport = MAX(lamport, ?1) WHERE singleton = 1",
                [operation.lamport],
            )?;
        }
        // 同一事务内裁剪窗口外的已应用记录，恰好保留最近 10000 条，
        // 避免 applied 表长期膨胀；窗口外重复应用由 opId 幂等与
        // LWW 合并保证安全。
        transaction.execute(
            "DELETE FROM sync_applied_operations WHERE server_seq <= ?1",
            [cursor - APPLIED_OPERATION_RETENTION],
        )?;
        transaction.execute(
            "UPDATE sync_state SET cursor = ?1 WHERE singleton = 1",
            [cursor],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn apply_webdav_operations(&mut self, operations: &[WebDavOperation]) -> CoreResult<()> {
        let configuration = self
            .sync_configuration
            .clone()
            .ok_or_else(|| CoreError::new("sync_credentials_unavailable", "同步密钥当前不可用"))?;
        let transaction = self.connection.transaction()?;
        for operation in operations {
            operation.validate()?;
            if operation.vault_id != configuration.vault_id {
                return Err(CoreError::new(
                    "invalid_remote_page",
                    "WebDAV 同步空间不匹配",
                ));
            }
            if is_webdav_operation_applied(&transaction, &operation.op_id)? {
                continue;
            }
            if !is_operation_applied(&transaction, &operation.op_id)? {
                apply_remote_operation(
                    &transaction,
                    &operation.as_pulled(1, now_millis()),
                    &configuration,
                )?;
                transaction.execute(
                    "UPDATE sync_state SET lamport = MAX(lamport, ?1) WHERE singleton = 1",
                    [operation.lamport],
                )?;
            }
            transaction.execute(
                "INSERT INTO sync_webdav_applied_operations(op_id, applied_at) VALUES(?1, ?2)",
                params![operation.op_id, now_millis()],
            )?;
        }
        // 同一事务内只保留最近 N 条已应用记录（按应用时间倒序），
        // 避免 WebDAV 长期同步后表无限膨胀。
        transaction.execute(
            r#"
            DELETE FROM sync_webdav_applied_operations WHERE op_id NOT IN (
              SELECT op_id FROM sync_webdav_applied_operations
              ORDER BY applied_at DESC, op_id DESC LIMIT ?1
            )
            "#,
            [APPLIED_OPERATION_RETENTION],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn display_configuration(&self) -> CoreResult<Option<WireDisplayConfigurationPayload>> {
        self.connection
            .query_row(
                r#"
                SELECT header_template, subtitle_template, start_date, deadline_date
                FROM sync_display_configuration WHERE entity_id = ?1 LIMIT 1
                "#,
                [DISPLAY_CONFIGURATION_ENTITY_ID],
                |row| {
                    let start = parse_date(&row.get::<_, String>(2)?)?;
                    let deadline = parse_date(&row.get::<_, String>(3)?)?;
                    WireDisplayConfigurationPayload::new(
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        start,
                        deadline,
                    )
                    .map_err(sql_conversion)
                },
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn seed_display_configuration(
        &mut self,
        payload: &WireDisplayConfigurationPayload,
    ) -> CoreResult<bool> {
        payload.validate()?;
        if self.display_configuration()?.is_some() {
            return Ok(false);
        }
        let transaction = self.connection.transaction()?;
        upsert_display_configuration(&transaction, payload, false)?;
        transaction.commit()?;
        Ok(true)
    }

    pub fn save_display_configuration(
        &mut self,
        payload: &WireDisplayConfigurationPayload,
    ) -> CoreResult<()> {
        payload.validate()?;
        let configuration = self.sync_configuration.clone();
        let has_identity = self.has_persisted_sync_identity;
        let transaction = self.connection.transaction()?;
        upsert_display_configuration(&transaction, payload, true)?;
        if let Some(configuration) = configuration.as_ref() {
            enqueue_local_display_configuration(&transaction, payload, configuration)?;
        } else if has_identity {
            transaction.execute(
                "INSERT OR REPLACE INTO sync_deferred_display_configuration(singleton, is_dirty) VALUES(1, 1)",
                [],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn make_backup_snapshot(
        &self,
        exported_at: i64,
        sync_credentials: Option<crate::backup::BackupSyncCredentials>,
    ) -> CoreResult<crate::backup::BackupSnapshot> {
        // A backup must represent one SQLite snapshot. Without an explicit read
        // transaction a concurrent sync could change the database between the
        // task and tombstone queries, producing a backup that contains both (or
        // neither) sides of the same deletion.
        let transaction = self.connection.unchecked_transaction()?;
        if let Some(credentials) = &sync_credentials {
            credentials.validate()?;
            let identity = persisted_sync_identity_in_connection(&transaction)?
                .ok_or_else(|| CoreError::new("invalid_state", "数据库未绑定同步身份"))?;
            if identity.0 != credentials.vault_id || identity.1 != credentials.device_id {
                return Err(CoreError::new(
                    "sync_identity_mismatch",
                    "备份凭据与数据库同步身份不一致",
                ));
            }
        }
        let mut task_models = fetch_all_in_transaction(&transaction)?;
        sort_tasks(&mut task_models);
        let tasks = task_models
            .iter()
            .map(WireTaskPayload::from_task)
            .collect::<CoreResult<Vec<_>>>()?;
        let tombstones = backup_tombstones(&transaction)?;
        let snapshot = crate::backup::BackupSnapshot {
            exported_at,
            protocol_version: crate::backup::BACKUP_PROTOCOL_VERSION,
            sync_credentials,
            tasks,
            tombstones,
        };
        snapshot.validate()?;
        transaction.commit()?;
        Ok(snapshot)
    }

    pub fn create_encrypted_backup(
        &self,
        exported_at: i64,
        sync_credentials: Option<crate::backup::BackupSyncCredentials>,
        passphrase: &str,
    ) -> CoreResult<Vec<u8>> {
        let snapshot = self.make_backup_snapshot(exported_at, sync_credentials)?;
        crate::backup::seal_backup(
            &snapshot,
            passphrase,
            crate::backup::BackupSealOptions::default(),
        )
    }

    pub fn restore_backup_snapshot(
        &mut self,
        snapshot: &crate::backup::BackupSnapshot,
    ) -> CoreResult<()> {
        self.restore_backup_snapshot_and_configure(snapshot, None)
    }

    pub fn restore_backup_snapshot_and_configure(
        &mut self,
        snapshot: &crate::backup::BackupSnapshot,
        configuration: Option<SyncConfiguration>,
    ) -> CoreResult<()> {
        snapshot.validate()?;
        if !is_pristine_backup_destination(&self.connection)? {
            return Err(CoreError::new(
                "backup_destination_not_empty",
                "仅支持向没有任务与同步历史的全新任务库恢复备份",
            ));
        }
        if let Some(configuration) = configuration.as_ref() {
            validate_sync_identity(&configuration.vault_id, &configuration.device_id)?;
            if let Some(credentials) = snapshot.sync_credentials.as_ref() {
                let expected_key = credentials.decoded_vault_key()?;
                if credentials.vault_id != configuration.vault_id
                    || credentials.device_id != configuration.device_id
                    || expected_key != configuration.vault_key
                {
                    return Err(CoreError::new(
                        "sync_identity_mismatch",
                        "备份凭据与待恢复同步配置不一致",
                    ));
                }
            }
        }
        let tasks = snapshot
            .tasks
            .clone()
            .into_iter()
            .map(WireTaskPayload::into_task)
            .collect::<CoreResult<Vec<_>>>()?;
        let transaction = self.connection.transaction()?;
        for task in &tasks {
            upsert(&transaction, task)?;
        }
        for tombstone in &snapshot.tombstones {
            transaction.execute(
                "INSERT INTO deleted_tasks(id, deleted_at) VALUES(?1, ?2)",
                params![canonical_entity_id(&tombstone.id), tombstone.deleted_at],
            )?;
            record_deferred_deletion(
                &transaction,
                &canonical_entity_id(&tombstone.id),
                tombstone.deleted_at,
            )?;
        }
        if let Some(configuration) = configuration.as_ref() {
            bind_unbound_sync(&transaction, configuration)?;
        }
        transaction.commit()?;
        if let Some(configuration) = configuration {
            self.sync_configuration = Some(configuration);
            self.has_persisted_sync_identity = true;
        }
        Ok(())
    }

    pub fn restore_encrypted_backup(
        &mut self,
        data: &[u8],
        passphrase: &str,
    ) -> CoreResult<Option<crate::backup::BackupSyncCredentials>> {
        if !is_pristine_backup_destination(&self.connection)? {
            return Err(CoreError::new(
                "backup_destination_not_empty",
                "仅支持向没有任务与同步历史的全新任务库恢复备份",
            ));
        }
        let snapshot = crate::backup::open_backup(data, passphrase)?;
        self.restore_backup_snapshot_and_configure(&snapshot, None)?;
        Ok(snapshot.sync_credentials)
    }

    pub fn restore_encrypted_backup_and_configure(
        &mut self,
        data: &[u8],
        passphrase: &str,
        configuration: Option<SyncConfiguration>,
    ) -> CoreResult<Option<crate::backup::BackupSyncCredentials>> {
        if !is_pristine_backup_destination(&self.connection)? {
            return Err(CoreError::new(
                "backup_destination_not_empty",
                "仅支持向没有任务与同步历史的全新任务库恢复备份",
            ));
        }
        let snapshot = crate::backup::open_backup(data, passphrase)?;
        self.restore_backup_snapshot_and_configure(&snapshot, configuration)?;
        Ok(snapshot.sync_credentials)
    }

    fn persisted_sync_identity(&self) -> CoreResult<Option<(String, String)>> {
        persisted_sync_identity_in_connection(&self.connection)
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
              deadline_date TEXT,
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
            CREATE TABLE IF NOT EXISTS sync_state(
              singleton INTEGER NOT NULL PRIMARY KEY CHECK(singleton = 1),
              vault_id TEXT,
              device_id TEXT,
              cursor INTEGER NOT NULL DEFAULT 0 CHECK(cursor >= 0),
              lamport INTEGER NOT NULL DEFAULT 0 CHECK(lamport >= 0),
              CHECK((vault_id IS NULL) = (device_id IS NULL))
            );
            INSERT OR IGNORE INTO sync_state(singleton, cursor, lamport) VALUES(1, 0, 0);
            CREATE TABLE IF NOT EXISTS sync_outbox(
              op_id TEXT NOT NULL PRIMARY KEY,
              entity_id TEXT NOT NULL,
              kind TEXT NOT NULL CHECK(kind IN ('upsert','delete','complete','pass','reopen','reorder')),
              lamport INTEGER NOT NULL CHECK(lamport >= 1),
              ciphertext TEXT NOT NULL,
              nonce TEXT NOT NULL,
              created_at INTEGER NOT NULL CHECK(created_at >= 0)
            );
            CREATE INDEX IF NOT EXISTS idx_sync_outbox_order ON sync_outbox(lamport, op_id);
            CREATE TABLE IF NOT EXISTS sync_entity_versions(
              entity_id TEXT NOT NULL PRIMARY KEY,
              lamport INTEGER NOT NULL CHECK(lamport >= 1),
              device_id TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0 CHECK(is_deleted IN (0, 1)),
              deleted_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS sync_applied_operations(
              op_id TEXT NOT NULL PRIMARY KEY,
              server_seq INTEGER NOT NULL UNIQUE CHECK(server_seq >= 1),
              applied_at INTEGER NOT NULL CHECK(applied_at >= 0)
            );
            CREATE TABLE IF NOT EXISTS sync_webdav_applied_operations(
              op_id TEXT NOT NULL PRIMARY KEY,
              applied_at INTEGER NOT NULL CHECK(applied_at >= 0)
            );
            CREATE TABLE IF NOT EXISTS sync_deferred_upserts(
              entity_id TEXT NOT NULL PRIMARY KEY,
              kind TEXT NOT NULL DEFAULT 'upsert'
                CHECK(kind IN ('upsert','complete','pass','reopen','reorder'))
            );
            CREATE TABLE IF NOT EXISTS sync_deferred_deletions(
              entity_id TEXT NOT NULL PRIMARY KEY,
              deleted_at INTEGER NOT NULL CHECK(deleted_at >= 0)
            );
            CREATE TABLE IF NOT EXISTS sync_deferred_display_configuration(
              singleton INTEGER NOT NULL PRIMARY KEY CHECK(singleton = 1),
              is_dirty INTEGER NOT NULL CHECK(is_dirty = 1)
            );
            CREATE TABLE IF NOT EXISTS sync_display_configuration(
              entity_id TEXT NOT NULL PRIMARY KEY,
              header_template TEXT NOT NULL,
              subtitle_template TEXT NOT NULL,
              start_date TEXT NOT NULL,
              deadline_date TEXT NOT NULL,
              is_local_override INTEGER NOT NULL DEFAULT 0 CHECK(is_local_override IN (0, 1))
            );
            "#,
        )?;
        if !self.has_tasks_column("deadline_date")? {
            self.connection
                .execute("ALTER TABLE tasks ADD COLUMN deadline_date TEXT", [])?;
        }
        let version: i64 = self
            .connection
            .pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version < 3 {
            self.connection.pragma_update(None, "user_version", 3)?;
        }
        Ok(())
    }

    fn has_tasks_column(&self, expected: &str) -> CoreResult<bool> {
        let mut statement = self.connection.prepare("PRAGMA table_info(tasks)")?;
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(columns.iter().any(|column| column == expected))
    }
}

fn now_millis() -> i64 {
    Utc::now().timestamp_millis()
}

fn validate_sync_identity(vault_id: &str, device_id: &str) -> CoreResult<()> {
    if !(1..=128).contains(&vault_id.chars().count())
        || !(1..=128).contains(&device_id.chars().count())
    {
        return Err(CoreError::validation(
            "vaultId 与 deviceId 必须为 1 到 128 个字符",
        ));
    }
    Ok(())
}

fn operation_kind(previous: Option<&TodoTask>, current: &TodoTask) -> OperationKind {
    let Some(previous) = previous else {
        return OperationKind::Upsert;
    };
    if previous.state != current.state {
        return match current.state {
            TaskState::Pending => OperationKind::Reopen,
            TaskState::Completed => OperationKind::Complete,
            TaskState::Pass => OperationKind::Pass,
        };
    }
    if previous.sort_order != current.sort_order {
        let mut without_order = current.clone();
        without_order.sort_order = previous.sort_order;
        without_order.updated_at = previous.updated_at;
        if &without_order == previous {
            return OperationKind::Reorder;
        }
    }
    OperationKind::Upsert
}

fn record_local_task_change(
    transaction: &Transaction<'_>,
    task: &TodoTask,
    kind: OperationKind,
    configuration: Option<&SyncConfiguration>,
    has_identity: bool,
) -> CoreResult<()> {
    let entity_id = canonical_entity_id(&task.id);
    if let Some(configuration) = configuration {
        enqueue_local_task(transaction, task, kind, configuration)
    } else if has_identity {
        record_deferred_upsert(transaction, &entity_id, kind)
    } else {
        Ok(())
    }
}

fn enqueue_local_task(
    transaction: &Transaction<'_>,
    task: &TodoTask,
    kind: OperationKind,
    configuration: &SyncConfiguration,
) -> CoreResult<()> {
    let entity_id = canonical_entity_id(&task.id);
    let lamport = next_lamport(transaction)?;
    let operation_id = uuid::Uuid::new_v4().hyphenated().to_string();
    let entity = WireEntity::Task(WireTaskPayload::from_task(task)?);
    let envelope = OperationCodec::seal(
        &entity,
        configuration,
        &operation_id,
        &entity_id,
        kind,
        lamport,
        None,
    )?;
    insert_outbox(
        transaction,
        &operation_id,
        &entity_id,
        kind,
        lamport,
        &envelope,
    )?;
    upsert_entity_version(
        transaction,
        &EntityVersion {
            entity_id,
            lamport,
            device_id: configuration.device_id.clone(),
            is_deleted: false,
            deleted_at: None,
        },
    )
}

fn enqueue_local_tombstone(
    transaction: &Transaction<'_>,
    entity_id: &str,
    deleted_at: i64,
    configuration: &SyncConfiguration,
) -> CoreResult<()> {
    let entity_id = canonical_entity_id(entity_id);
    let lamport = next_lamport(transaction)?;
    let operation_id = uuid::Uuid::new_v4().hyphenated().to_string();
    let entity = WireEntity::Tombstone(WireTombstonePayload::new(entity_id.clone(), deleted_at)?);
    let envelope = OperationCodec::seal(
        &entity,
        configuration,
        &operation_id,
        &entity_id,
        OperationKind::Delete,
        lamport,
        None,
    )?;
    insert_outbox(
        transaction,
        &operation_id,
        &entity_id,
        OperationKind::Delete,
        lamport,
        &envelope,
    )?;
    upsert_entity_version(
        transaction,
        &EntityVersion {
            entity_id,
            lamport,
            device_id: configuration.device_id.clone(),
            is_deleted: true,
            deleted_at: Some(deleted_at),
        },
    )
}

fn enqueue_local_display_configuration(
    transaction: &Transaction<'_>,
    payload: &WireDisplayConfigurationPayload,
    configuration: &SyncConfiguration,
) -> CoreResult<()> {
    let lamport = next_lamport(transaction)?;
    let operation_id = uuid::Uuid::new_v4().hyphenated().to_string();
    let entity = WireEntity::DisplayConfiguration(payload.clone());
    let envelope = OperationCodec::seal(
        &entity,
        configuration,
        &operation_id,
        DISPLAY_CONFIGURATION_ENTITY_ID,
        OperationKind::Upsert,
        lamport,
        None,
    )?;
    insert_outbox(
        transaction,
        &operation_id,
        DISPLAY_CONFIGURATION_ENTITY_ID,
        OperationKind::Upsert,
        lamport,
        &envelope,
    )?;
    upsert_entity_version(
        transaction,
        &EntityVersion {
            entity_id: DISPLAY_CONFIGURATION_ENTITY_ID.to_owned(),
            lamport,
            device_id: configuration.device_id.clone(),
            is_deleted: false,
            deleted_at: None,
        },
    )
}

fn next_lamport(transaction: &Transaction<'_>) -> CoreResult<i64> {
    let current: i64 = transaction.query_row(
        "SELECT lamport FROM sync_state WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    let next = current
        .checked_add(1)
        .ok_or_else(|| CoreError::invalid_state("Lamport 时钟已溢出"))?;
    transaction.execute(
        "UPDATE sync_state SET lamport = ?1 WHERE singleton = 1",
        [next],
    )?;
    Ok(next)
}

fn insert_outbox(
    transaction: &Transaction<'_>,
    operation_id: &str,
    entity_id: &str,
    kind: OperationKind,
    lamport: i64,
    envelope: &crate::wire::EncryptedEnvelope,
) -> CoreResult<()> {
    transaction.execute(
        r#"
        INSERT INTO sync_outbox(op_id, entity_id, kind, lamport, ciphertext, nonce, created_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        "#,
        params![
            operation_id,
            entity_id,
            kind.wire_value(),
            lamport,
            envelope.ciphertext,
            envelope.nonce,
            now_millis()
        ],
    )?;
    Ok(())
}

fn record_deferred_upsert(
    transaction: &Transaction<'_>,
    entity_id: &str,
    kind: OperationKind,
) -> CoreResult<()> {
    if kind == OperationKind::Delete {
        return Err(CoreError::invalid_state(
            "删除操作必须写入 deferred deletion",
        ));
    }
    transaction.execute(
        r#"
        INSERT INTO sync_deferred_upserts(entity_id, kind) VALUES(?1, ?2)
        ON CONFLICT(entity_id) DO UPDATE SET kind = CASE
          WHEN sync_deferred_upserts.kind = 'reopen'
            AND excluded.kind IN ('upsert','reorder') THEN 'reopen'
          ELSE excluded.kind
        END
        "#,
        params![entity_id, kind.wire_value()],
    )?;
    Ok(())
}

fn remove_deferred_upsert(transaction: &Transaction<'_>, entity_id: &str) -> CoreResult<()> {
    transaction.execute(
        "DELETE FROM sync_deferred_upserts WHERE entity_id = ?1",
        [entity_id],
    )?;
    Ok(())
}

fn record_deferred_deletion(
    transaction: &Transaction<'_>,
    entity_id: &str,
    deleted_at: i64,
) -> CoreResult<()> {
    transaction.execute(
        r#"
        INSERT INTO sync_deferred_deletions(entity_id, deleted_at) VALUES(?1, ?2)
        ON CONFLICT(entity_id) DO UPDATE SET deleted_at = excluded.deleted_at
        "#,
        params![entity_id, deleted_at],
    )?;
    Ok(())
}

fn bind_unbound_sync(
    transaction: &Transaction<'_>,
    configuration: &SyncConfiguration,
) -> CoreResult<()> {
    transaction.execute(
        "UPDATE sync_state SET vault_id = ?1, device_id = ?2 WHERE singleton = 1",
        params![configuration.vault_id, configuration.device_id],
    )?;
    for task in fetch_all_in_transaction(transaction)? {
        enqueue_local_task(transaction, &task, OperationKind::Upsert, configuration)?;
    }
    if let Some((payload, local_override)) = display_configuration_in_transaction(transaction)?
        && local_override
    {
        enqueue_local_display_configuration(transaction, &payload, configuration)?;
    }
    for tombstone in deferred_and_local_tombstones(transaction)? {
        enqueue_local_tombstone(
            transaction,
            &tombstone.id,
            tombstone.deleted_at,
            configuration,
        )?;
    }
    clear_deferred_changes(transaction)
}

fn recover_deferred_changes(
    transaction: &Transaction<'_>,
    configuration: &SyncConfiguration,
) -> CoreResult<()> {
    let mut statement = transaction
        .prepare("SELECT entity_id, kind FROM sync_deferred_upserts ORDER BY entity_id")?;
    let deferred = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                parse_operation_kind(&row.get::<_, String>(1)?)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for (entity_id, kind) in deferred {
        let task = transaction
            .query_row(
                "SELECT * FROM tasks WHERE lower(id) = lower(?1) LIMIT 1",
                [&entity_id],
                read_task,
            )
            .optional()?
            .ok_or_else(|| CoreError::invalid_state("待同步任务正文已丢失"))?;
        enqueue_local_task(transaction, &task, kind, configuration)?;
    }
    let has_display: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sync_deferred_display_configuration)",
        [],
        |row| Ok(row.get::<_, i64>(0)? != 0),
    )?;
    if has_display {
        let payload = display_configuration_in_transaction(transaction)?
            .map(|value| value.0)
            .ok_or_else(|| CoreError::invalid_state("待同步显示配置正文已丢失"))?;
        enqueue_local_display_configuration(transaction, &payload, configuration)?;
    }
    let mut statement = transaction
        .prepare("SELECT entity_id, deleted_at FROM sync_deferred_deletions ORDER BY entity_id")?;
    let deletions = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for (entity_id, deleted_at) in deletions {
        transaction.execute(
            "DELETE FROM tasks WHERE lower(id) = lower(?1)",
            [&entity_id],
        )?;
        enqueue_local_tombstone(transaction, &entity_id, deleted_at, configuration)?;
    }
    clear_deferred_changes(transaction)
}

fn clear_deferred_changes(transaction: &Transaction<'_>) -> CoreResult<()> {
    transaction.execute("DELETE FROM sync_deferred_upserts", [])?;
    transaction.execute("DELETE FROM sync_deferred_deletions", [])?;
    transaction.execute("DELETE FROM sync_deferred_display_configuration", [])?;
    Ok(())
}

fn reset_sync_metadata(transaction: &Transaction<'_>) -> CoreResult<()> {
    for table in [
        "sync_outbox",
        "sync_entity_versions",
        "sync_applied_operations",
        "sync_webdav_applied_operations",
        "sync_deferred_upserts",
        "sync_deferred_deletions",
        "sync_deferred_display_configuration",
    ] {
        transaction.execute(&format!("DELETE FROM {table}"), [])?;
    }
    transaction.execute(
        r#"
        UPDATE sync_state SET vault_id = NULL, device_id = NULL, cursor = 0, lamport = 0
        WHERE singleton = 1
        "#,
        [],
    )?;
    transaction.execute(
        "UPDATE sync_display_configuration SET is_local_override = 1",
        [],
    )?;
    Ok(())
}

fn fetch_all_in_transaction(transaction: &Transaction<'_>) -> CoreResult<Vec<TodoTask>> {
    let mut statement = transaction.prepare("SELECT * FROM tasks")?;
    Ok(statement
        .query_map([], read_task)?
        .collect::<Result<Vec<_>, _>>()?)
}

fn deferred_and_local_tombstones(
    transaction: &Transaction<'_>,
) -> CoreResult<Vec<WireTombstonePayload>> {
    let mut statement = transaction.prepare(
        r#"
        SELECT id, MAX(deleted_at) FROM (
          SELECT id, deleted_at FROM deleted_tasks
          UNION ALL
          SELECT entity_id AS id, deleted_at FROM sync_deferred_deletions
        ) GROUP BY id ORDER BY id
        "#,
    )?;
    statement
        .query_map([], |row| {
            WireTombstonePayload::new(row.get::<_, String>(0)?, row.get::<_, i64>(1)?)
                .map_err(sql_conversion)
        })?
        .collect::<Result<Vec<_>, _>>()
        .map_err(Into::into)
}

fn upsert_display_configuration(
    transaction: &Transaction<'_>,
    payload: &WireDisplayConfigurationPayload,
    local_override: bool,
) -> CoreResult<()> {
    payload.validate()?;
    transaction.execute(
        r#"
        INSERT INTO sync_display_configuration(
          entity_id, header_template, subtitle_template, start_date, deadline_date,
          is_local_override
        ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(entity_id) DO UPDATE SET
          header_template = excluded.header_template,
          subtitle_template = excluded.subtitle_template,
          start_date = excluded.start_date,
          deadline_date = excluded.deadline_date,
          is_local_override = excluded.is_local_override
        "#,
        params![
            payload.id,
            payload.header_template,
            payload.subtitle_template,
            payload.start_date.format("%Y-%m-%d").to_string(),
            payload.deadline_date.format("%Y-%m-%d").to_string(),
            i64::from(local_override)
        ],
    )?;
    Ok(())
}

fn display_configuration_in_transaction(
    transaction: &Transaction<'_>,
) -> CoreResult<Option<(WireDisplayConfigurationPayload, bool)>> {
    transaction
        .query_row(
            r#"
            SELECT header_template, subtitle_template, start_date, deadline_date,
                   is_local_override
            FROM sync_display_configuration WHERE entity_id = ?1 LIMIT 1
            "#,
            [DISPLAY_CONFIGURATION_ENTITY_ID],
            |row| {
                Ok((
                    WireDisplayConfigurationPayload::new(
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        parse_date(&row.get::<_, String>(2)?)?,
                        parse_date(&row.get::<_, String>(3)?)?,
                    )
                    .map_err(sql_conversion)?,
                    row.get::<_, i64>(4)? != 0,
                ))
            },
        )
        .optional()
        .map_err(Into::into)
}

fn sync_state_number(connection: &Connection, column: &str) -> CoreResult<i64> {
    if !matches!(column, "cursor" | "lamport") {
        return Err(CoreError::validation("未知同步状态字段"));
    }
    connection
        .query_row(
            &format!("SELECT {column} FROM sync_state WHERE singleton = 1"),
            [],
            |row| row.get(0),
        )
        .map_err(Into::into)
}

fn validate_remote_page(
    operations: &[SyncPulledOperation],
    previous_cursor: i64,
    target_cursor: i64,
) -> CoreResult<()> {
    if target_cursor < previous_cursor {
        return Err(CoreError::new("invalid_remote_page", "cursor 发生回退"));
    }
    if operations.is_empty() {
        if target_cursor != previous_cursor {
            return Err(CoreError::new("invalid_remote_page", "空页不能推进 cursor"));
        }
        return Ok(());
    }
    let mut sequence = previous_cursor;
    for operation in operations {
        operation.validate()?;
        if operation.server_seq <= sequence || operation.server_seq > target_cursor {
            return Err(CoreError::new("invalid_remote_page", "远端操作序号无效"));
        }
        sequence = operation.server_seq;
    }
    if sequence != target_cursor {
        return Err(CoreError::new(
            "invalid_remote_page",
            "页尾序号与 cursor 不一致",
        ));
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct EntityVersion {
    entity_id: String,
    lamport: i64,
    device_id: String,
    is_deleted: bool,
    deleted_at: Option<i64>,
}

fn entity_version(
    transaction: &Transaction<'_>,
    entity_id: &str,
) -> CoreResult<Option<EntityVersion>> {
    transaction
        .query_row(
            r#"
            SELECT lamport, device_id, is_deleted, deleted_at
            FROM sync_entity_versions WHERE entity_id = ?1
            "#,
            [entity_id],
            |row| {
                Ok(EntityVersion {
                    entity_id: entity_id.to_owned(),
                    lamport: row.get(0)?,
                    device_id: row.get(1)?,
                    is_deleted: row.get::<_, i64>(2)? != 0,
                    deleted_at: row.get(3)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn upsert_entity_version(transaction: &Transaction<'_>, version: &EntityVersion) -> CoreResult<()> {
    transaction.execute(
        r#"
        INSERT INTO sync_entity_versions(entity_id, lamport, device_id, is_deleted, deleted_at)
        VALUES(?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(entity_id) DO UPDATE SET
          lamport = excluded.lamport, device_id = excluded.device_id,
          is_deleted = excluded.is_deleted, deleted_at = excluded.deleted_at
        "#,
        params![
            version.entity_id,
            version.lamport,
            version.device_id,
            i64::from(version.is_deleted),
            version.deleted_at
        ],
    )?;
    Ok(())
}

fn remote_version_wins(lamport: i64, device_id: &str, current: Option<&EntityVersion>) -> bool {
    let Some(current) = current else {
        return true;
    };
    lamport > current.lamport
        || (lamport == current.lamport && device_id > current.device_id.as_str())
}

fn maximum_version(
    current: Option<&EntityVersion>,
    operation: &SyncPulledOperation,
    entity_id: &str,
) -> EntityVersion {
    if let Some(current) = current
        && !remote_version_wins(operation.lamport, &operation.device_id, Some(current))
    {
        return EntityVersion {
            entity_id: entity_id.to_owned(),
            lamport: current.lamport,
            device_id: current.device_id.clone(),
            is_deleted: false,
            deleted_at: None,
        };
    }
    EntityVersion {
        entity_id: entity_id.to_owned(),
        lamport: operation.lamport,
        device_id: operation.device_id.clone(),
        is_deleted: false,
        deleted_at: None,
    }
}

fn apply_remote_operation(
    transaction: &Transaction<'_>,
    operation: &SyncPulledOperation,
    configuration: &SyncConfiguration,
) -> CoreResult<()> {
    let entity = OperationCodec::open_pulled(operation, configuration)?;
    let entity_id = canonical_entity_id(&operation.entity_id);
    let current_version = entity_version(transaction, &entity_id)?;
    match entity {
        WireEntity::Task(payload) => {
            if operation.kind == OperationKind::Delete
                || entity_id == DISPLAY_CONFIGURATION_ENTITY_ID
                || canonical_entity_id(&payload.id) != entity_id
            {
                return Err(CoreError::new(
                    "invalid_remote_page",
                    "任务正文与外层元数据不一致",
                ));
            }
            if (operation.kind == OperationKind::Complete && payload.state != TaskState::Completed)
                || (operation.kind == OperationKind::Pass && payload.state != TaskState::Pass)
                || (operation.kind == OperationKind::Reopen && payload.state != TaskState::Pending)
            {
                return Err(CoreError::new(
                    "invalid_remote_page",
                    "任务操作类型与正文状态不一致",
                ));
            }
            if current_version
                .as_ref()
                .is_some_and(|version| version.is_deleted)
            {
                if remote_version_wins(
                    operation.lamport,
                    &operation.device_id,
                    current_version.as_ref(),
                ) {
                    let current = current_version.as_ref().unwrap();
                    upsert_entity_version(
                        transaction,
                        &EntityVersion {
                            entity_id,
                            lamport: operation.lamport,
                            device_id: operation.device_id.clone(),
                            is_deleted: true,
                            deleted_at: current.deleted_at,
                        },
                    )?;
                }
                return Ok(());
            }
            let incoming = payload.into_task()?;
            let current_task = find_in_transaction(transaction, &incoming.id)?;
            let incoming_wins = remote_version_wins(
                operation.lamport,
                &operation.device_id,
                current_version.as_ref(),
            );
            if operation.kind == OperationKind::Reopen {
                if !valid_remote_reopen(&incoming) {
                    return Err(CoreError::new(
                        "invalid_remote_page",
                        "reopen 操作超出可撤销周期",
                    ));
                }
                if incoming_wins {
                    upsert(transaction, &incoming)?;
                    upsert_entity_version(
                        transaction,
                        &EntityVersion {
                            entity_id,
                            lamport: operation.lamport,
                            device_id: operation.device_id.clone(),
                            is_deleted: false,
                            deleted_at: None,
                        },
                    )?;
                }
                return Ok(());
            }
            if let Some(current_task) = current_task.as_ref()
                && let Some(merged) =
                    merge_completed_over_pass(&incoming, current_task, incoming_wins)
            {
                upsert(transaction, &merged)?;
                upsert_entity_version(
                    transaction,
                    &maximum_version(current_version.as_ref(), operation, &entity_id),
                )?;
                return Ok(());
            }
            if let Some(current_task) = current_task.as_ref()
                && let Some(settled) = merge_settled_over_pending(&incoming, current_task)
            {
                upsert(transaction, &settled)?;
                upsert_entity_version(
                    transaction,
                    &maximum_version(current_version.as_ref(), operation, &entity_id),
                )?;
                return Ok(());
            }
            if incoming_wins {
                upsert(transaction, &incoming)?;
                upsert_entity_version(
                    transaction,
                    &EntityVersion {
                        entity_id,
                        lamport: operation.lamport,
                        device_id: operation.device_id.clone(),
                        is_deleted: false,
                        deleted_at: None,
                    },
                )?;
            }
        }
        WireEntity::Tombstone(payload) => {
            if operation.kind != OperationKind::Delete
                || entity_id == DISPLAY_CONFIGURATION_ENTITY_ID
                || canonical_entity_id(&payload.id) != entity_id
            {
                return Err(CoreError::new(
                    "invalid_remote_page",
                    "tombstone 与外层元数据不一致",
                ));
            }
            if let Some(current) = current_version.as_ref()
                && current.is_deleted
                && !remote_version_wins(operation.lamport, &operation.device_id, Some(current))
            {
                return Ok(());
            }
            let horizon = maximum_version(current_version.as_ref(), operation, &entity_id);
            transaction.execute(
                "DELETE FROM tasks WHERE lower(id) = lower(?1)",
                [&entity_id],
            )?;
            transaction.execute(
                "INSERT OR REPLACE INTO deleted_tasks(id, deleted_at) VALUES(?1, ?2)",
                params![entity_id, payload.deleted_at],
            )?;
            upsert_entity_version(
                transaction,
                &EntityVersion {
                    entity_id,
                    lamport: horizon.lamport,
                    device_id: horizon.device_id,
                    is_deleted: true,
                    deleted_at: Some(payload.deleted_at),
                },
            )?;
        }
        WireEntity::DisplayConfiguration(payload) => {
            if operation.kind != OperationKind::Upsert
                || payload.id != entity_id
                || entity_id != DISPLAY_CONFIGURATION_ENTITY_ID
            {
                return Err(CoreError::new(
                    "invalid_remote_page",
                    "显示配置正文与外层元数据不一致",
                ));
            }
            if remote_version_wins(
                operation.lamport,
                &operation.device_id,
                current_version.as_ref(),
            ) {
                upsert_display_configuration(transaction, &payload, false)?;
                upsert_entity_version(
                    transaction,
                    &EntityVersion {
                        entity_id,
                        lamport: operation.lamport,
                        device_id: operation.device_id.clone(),
                        is_deleted: false,
                        deleted_at: None,
                    },
                )?;
            }
        }
    }
    Ok(())
}

fn period_end_millis(task: &TodoTask) -> Option<i64> {
    let end = crate::period::next_start(task.time_type, task.period_start?)?;
    let utc_midnight = end.and_hms_opt(0, 0, 0)?.and_utc().timestamp_millis();
    utc_midnight.checked_sub(8 * 60 * 60 * 1_000)
}

fn valid_remote_reopen(task: &TodoTask) -> bool {
    task.state == TaskState::Pending
        && task.settled_at.is_none()
        && (task.recurrence == Recurrence::Once
            || match period_end_millis(task) {
                Some(end) => task.updated_at < end,
                None => task.time_type == TimeType::Someday,
            })
}

fn completion_within_period(task: &TodoTask) -> bool {
    if task.state != TaskState::Completed {
        return false;
    }
    let Some(settled_at) = task.settled_at else {
        return false;
    };
    task.time_type == TimeType::Someday
        || period_end_millis(task).is_some_and(|end| settled_at < end)
}

fn merge_completed_over_pass(
    incoming: &TodoTask,
    current: &TodoTask,
    incoming_wins: bool,
) -> Option<TodoTask> {
    let completed = match (incoming.state, current.state) {
        (TaskState::Completed, TaskState::Pass) => incoming,
        (TaskState::Pass, TaskState::Completed) => current,
        _ => return None,
    };
    if !completion_within_period(completed) {
        return None;
    }
    let mut merged = if incoming_wins {
        incoming.clone()
    } else {
        current.clone()
    };
    merged.state = TaskState::Completed;
    merged.settled_at = completed.settled_at;
    merged.updated_at = merged.updated_at.max(completed.updated_at);
    Some(merged)
}

fn merge_settled_over_pending(incoming: &TodoTask, current: &TodoTask) -> Option<TodoTask> {
    match (incoming.state, current.state) {
        (TaskState::Pending, TaskState::Completed | TaskState::Pass) => Some(current.clone()),
        (TaskState::Completed | TaskState::Pass, TaskState::Pending) => Some(incoming.clone()),
        _ => None,
    }
}

fn is_operation_applied(transaction: &Transaction<'_>, operation_id: &str) -> CoreResult<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM sync_applied_operations WHERE op_id = ?1 LIMIT 1",
            [operation_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn is_webdav_operation_applied(
    transaction: &Transaction<'_>,
    operation_id: &str,
) -> CoreResult<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM sync_webdav_applied_operations WHERE op_id = ?1 LIMIT 1",
            [operation_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn parse_operation_kind(value: &str) -> rusqlite::Result<OperationKind> {
    match value {
        "upsert" => Ok(OperationKind::Upsert),
        "delete" => Ok(OperationKind::Delete),
        "complete" => Ok(OperationKind::Complete),
        "pass" => Ok(OperationKind::Pass),
        "reopen" => Ok(OperationKind::Reopen),
        "reorder" => Ok(OperationKind::Reorder),
        _ => Err(sql_conversion(CoreError::validation(
            "数据库同步操作类型无效",
        ))),
    }
}

fn backup_tombstones(connection: &Connection) -> CoreResult<Vec<WireTombstonePayload>> {
    let mut statement = connection.prepare(
        r#"
        SELECT entity_id, MAX(deleted_at) FROM (
          SELECT id AS entity_id, deleted_at FROM deleted_tasks
          UNION ALL
          SELECT entity_id, deleted_at FROM sync_entity_versions WHERE is_deleted = 1
          UNION ALL
          SELECT entity_id, deleted_at FROM sync_deferred_deletions
        ) WHERE deleted_at IS NOT NULL GROUP BY entity_id ORDER BY entity_id
        "#,
    )?;
    statement
        .query_map([], |row| {
            WireTombstonePayload::new(row.get::<_, String>(0)?, row.get::<_, i64>(1)?)
                .map_err(sql_conversion)
        })?
        .collect::<Result<Vec<_>, _>>()
        .map_err(Into::into)
}

fn persisted_sync_identity_in_connection(
    connection: &Connection,
) -> CoreResult<Option<(String, String)>> {
    connection
        .query_row(
            "SELECT vault_id, device_id FROM sync_state WHERE singleton = 1",
            [],
            |row| {
                let vault: Option<String> = row.get(0)?;
                let device: Option<String> = row.get(1)?;
                match (vault, device) {
                    (None, None) => Ok(None),
                    (Some(vault), Some(device)) => Ok(Some((vault, device))),
                    _ => Err(rusqlite::Error::InvalidQuery),
                }
            },
        )
        .map_err(Into::into)
}

fn is_pristine_backup_destination(connection: &Connection) -> CoreResult<bool> {
    connection
        .query_row(
            r#"
            SELECT NOT EXISTS(SELECT 1 FROM tasks)
              AND NOT EXISTS(SELECT 1 FROM deleted_tasks)
              AND NOT EXISTS(SELECT 1 FROM sync_outbox)
              AND NOT EXISTS(SELECT 1 FROM sync_entity_versions)
              AND NOT EXISTS(SELECT 1 FROM sync_applied_operations)
              AND NOT EXISTS(SELECT 1 FROM sync_webdav_applied_operations)
              AND NOT EXISTS(SELECT 1 FROM sync_deferred_upserts)
              AND NOT EXISTS(SELECT 1 FROM sync_deferred_deletions)
              AND vault_id IS NULL AND device_id IS NULL AND cursor = 0 AND lamport = 0
            FROM sync_state WHERE singleton = 1
            "#,
            [],
            |row| Ok(row.get::<_, i64>(0)? != 0),
        )
        .map_err(Into::into)
}

fn read_task(row: &Row<'_>) -> rusqlite::Result<TodoTask> {
    let period_start: Option<String> = row.get("period_start")?;
    let reminder_time: Option<String> = row.get("reminder_time")?;
    let deadline_date: Option<String> = row.get("deadline_date")?;
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
        deadline_date: deadline_date.map(|value| parse_date(&value)).transpose()?,
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
          recurrence, sort_order, created_at, updated_at, settled_at, reminder_time,
          deadline_date
        ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
        ON CONFLICT(id) DO UPDATE SET
          series_id = excluded.series_id, title = excluded.title,
          time_type = excluded.time_type, period_start = excluded.period_start,
          quest_line = excluded.quest_line, status = excluded.status,
          recurrence = excluded.recurrence, sort_order = excluded.sort_order,
          created_at = excluded.created_at, updated_at = excluded.updated_at,
          settled_at = excluded.settled_at, reminder_time = excluded.reminder_time,
          deadline_date = excluded.deadline_date
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
            task.deadline_date
                .map(|value| value.format("%Y-%m-%d").to_string()),
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
