use chrono::NaiveDate;
use woo_todo_core::{QuestLine, TaskState, TimeType, TodoTask};

pub fn time_type_label(value: TimeType) -> &'static str {
    match value {
        TimeType::Day => "每日",
        TimeType::Week => "每周",
        TimeType::Month => "每月",
        TimeType::Someday => "闲时",
    }
}

pub fn quest_line_label(value: QuestLine) -> &'static str {
    match value {
        QuestLine::Main => "主线",
        QuestLine::Side => "支线",
        QuestLine::Extra => "外传",
    }
}

pub fn state_label(value: TaskState) -> &'static str {
    match value {
        TaskState::Pending => "待完成",
        TaskState::Completed => "已完成",
        TaskState::Pass => "Pass",
    }
}

pub fn period_label(task: &TodoTask) -> String {
    match task.time_type {
        TimeType::Day => format_date(task.period_start),
        TimeType::Week => task
            .period_start
            .map(|date| format!("{} 起一周", date.format("%m-%d")))
            .unwrap_or_default(),
        TimeType::Month => task
            .period_start
            .map(|date| date.format("%Y-%m").to_string())
            .unwrap_or_default(),
        TimeType::Someday => "无截止时间".to_owned(),
    }
}

fn format_date(value: Option<NaiveDate>) -> String {
    value
        .map(|date| date.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use woo_todo_core::{Recurrence, ReminderTime};

    #[test]
    fn period_labels_match_existing_windows_wording() {
        let task = TodoTask {
            id: "00000000-0000-4000-8000-000000000001".to_owned(),
            series_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            title: "测试".to_owned(),
            time_type: TimeType::Week,
            period_start: NaiveDate::from_ymd_opt(2026, 7, 27),
            timezone: "Asia/Shanghai".to_owned(),
            quest_line: QuestLine::Main,
            state: TaskState::Pending,
            recurrence: Recurrence::Once,
            sort_order: 0,
            created_at: 1,
            updated_at: 1,
            settled_at: None,
            reminder_time: ReminderTime::new(9, 30).ok(),
        };
        assert_eq!(time_type_label(TimeType::Week), "每周");
        assert_eq!(quest_line_label(QuestLine::Main), "主线");
        assert_eq!(state_label(TaskState::Pending), "待完成");
        assert_eq!(period_label(&task), "07-27 起一周");
    }
}
