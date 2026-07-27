use std::collections::HashSet;

use chrono::NaiveDate;
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
    let original = task(
        "00000000-0000-4000-8000-000000000001",
        "2026-07-20",
        true,
        1,
    );
    let first = settle(&[original], date("2026-07-24"), 2, &HashSet::new());
    assert_eq!(first.tasks.len(), 5);
    assert_eq!(first.changed_task_ids.len(), 4);
    assert_eq!(first.generated_task_ids.len(), 4);
    assert!(first.tasks.iter().any(|task| {
        task.period_start == Some(date("2026-07-24")) && task.state == TaskState::Pending
    }));

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
        Some("00000000-0000-4000-8000-000000000090".to_owned()),
    )
    .unwrap();
    assert_eq!(value.recurrence, Recurrence::Once);
    assert!(value.reminder_time.is_none());
    assert!(notification_plans(&[value.clone()]).is_empty());

    value.recurrence = Recurrence::Repeat;
    assert!(value.validate().is_err());
}
