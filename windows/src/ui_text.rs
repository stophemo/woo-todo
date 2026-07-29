use chrono::NaiveDate;
use woo_todo_core::{QuestLine, Recurrence, TaskState, TimeType, TodoTask};

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

pub fn date_with_weekday(date: NaiveDate) -> String {
    use chrono::Datelike;

    let weekday = match date.weekday() {
        chrono::Weekday::Mon => "周一",
        chrono::Weekday::Tue => "周二",
        chrono::Weekday::Wed => "周三",
        chrono::Weekday::Thu => "周四",
        chrono::Weekday::Fri => "周五",
        chrono::Weekday::Sat => "周六",
        chrono::Weekday::Sun => "周日",
    };
    format!("{}月{}日 {weekday}", date.month(), date.day())
}

pub fn task_badges(task: &TodoTask, today: NaiveDate) -> String {
    let mut values = Vec::new();
    if task.recurrence == Recurrence::Repeat {
        values.push("重复".to_owned());
    }
    if let Some(reminder) = task.reminder_time {
        values.push(format!("提醒 {:02}:{:02}", reminder.hour, reminder.minute));
    }
    if let Some(deadline) = task.deadline_date {
        let days = deadline.signed_duration_since(today).num_days();
        let value = match days {
            value if value < 0 && task.state == TaskState::Pending => {
                format!("已逾期 {} 天", value.unsigned_abs())
            }
            value if value < 0 => format!("截止 {}", deadline.format("%m-%d")),
            0 => "今天截止".to_owned(),
            1 => "明天截止".to_owned(),
            value => format!("截止 {}（{} 天）", deadline.format("%m-%d"), value),
        };
        values.push(value);
    }
    values.join(" · ")
}

fn format_date(value: Option<NaiveDate>) -> String {
    value
        .map(|date| date.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use woo_todo_core::ReminderTime;

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
            deadline_date: None,
        };
        assert_eq!(time_type_label(TimeType::Week), "每周");
        assert_eq!(quest_line_label(QuestLine::Main), "主线");
        assert_eq!(state_label(TaskState::Pending), "待完成");
        assert_eq!(period_label(&task), "07-27 起一周");
        assert_eq!(
            date_with_weekday(NaiveDate::from_ymd_opt(2026, 7, 27).unwrap()),
            "7月27日 周一"
        );
        assert_eq!(
            task_badges(&task, NaiveDate::from_ymd_opt(2026, 7, 27).unwrap()),
            "提醒 09:30"
        );
    }

    #[test]
    fn task_badges_explain_deadline_state() {
        let mut task = TodoTask {
            id: "00000000-0000-4000-8000-000000000001".to_owned(),
            series_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            title: "测试".to_owned(),
            time_type: TimeType::Day,
            period_start: NaiveDate::from_ymd_opt(2026, 7, 27),
            timezone: "Asia/Shanghai".to_owned(),
            quest_line: QuestLine::Main,
            state: TaskState::Pending,
            recurrence: Recurrence::Once,
            sort_order: 0,
            created_at: 1,
            updated_at: 1,
            settled_at: None,
            reminder_time: None,
            deadline_date: NaiveDate::from_ymd_opt(2026, 7, 27),
        };
        let today = NaiveDate::from_ymd_opt(2026, 7, 27).unwrap();
        assert_eq!(task_badges(&task, today), "今天截止");
        task.deadline_date = NaiveDate::from_ymd_opt(2026, 7, 26);
        assert_eq!(task_badges(&task, today), "已逾期 1 天");
        task.deadline_date = NaiveDate::from_ymd_opt(2026, 8, 2);
        assert_eq!(task_badges(&task, today), "截止 08-02（6 天）");
    }
}
