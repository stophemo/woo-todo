use serde::{Deserialize, Serialize};

use crate::model::{TaskState, TodoTask};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationPlan {
    pub id: String,
    pub task_id: String,
    pub fire_date: String,
    pub fire_time: String,
    pub title: String,
    pub body: String,
    pub deep_link: String,
}

pub fn notification_plans(tasks: &[TodoTask]) -> Vec<NotificationPlan> {
    let mut plans: Vec<NotificationPlan> = tasks
        .iter()
        .filter_map(|task| {
            if task.state != TaskState::Pending {
                return None;
            }
            let date = task.period_start?;
            let time = task.reminder_time?;
            let fire_date = date.format("%Y-%m-%d").to_string();
            let fire_time = time.wire_value();
            Some(NotificationPlan {
                id: format!("task-reminder:{}:{fire_date}:{fire_time}", task.id),
                task_id: task.id.clone(),
                fire_date,
                fire_time,
                title: "待办提醒".to_owned(),
                body: task.title.clone(),
                deep_link: format!("wootodo://task-reminder/{}", task.id),
            })
        })
        .collect();
    plans.sort_by(|left, right| {
        left.fire_date
            .cmp(&right.fire_date)
            .then_with(|| left.fire_time.cmp(&right.fire_time))
            .then_with(|| left.task_id.cmp(&right.task_id))
    });
    plans
}
