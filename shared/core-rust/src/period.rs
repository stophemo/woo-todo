use chrono::{Datelike, Duration, FixedOffset, Months, NaiveDate, Utc, Weekday};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::model::{TimeType, TodoTask};

pub fn today_shanghai() -> NaiveDate {
    let offset = FixedOffset::east_opt(8 * 60 * 60).expect("UTC+8 必须有效");
    Utc::now().with_timezone(&offset).date_naive()
}

pub fn normalize_start(time_type: TimeType, date: NaiveDate) -> Option<NaiveDate> {
    match time_type {
        TimeType::Day => Some(date),
        TimeType::Week => {
            let offset = match date.weekday() {
                Weekday::Mon => 0,
                Weekday::Tue => 1,
                Weekday::Wed => 2,
                Weekday::Thu => 3,
                Weekday::Fri => 4,
                Weekday::Sat => 5,
                Weekday::Sun => 6,
            };
            Some(date - Duration::days(offset))
        }
        TimeType::Month => NaiveDate::from_ymd_opt(date.year(), date.month(), 1),
        TimeType::Someday => None,
    }
}

pub fn next_start(time_type: TimeType, start: NaiveDate) -> Option<NaiveDate> {
    match time_type {
        TimeType::Day => start.checked_add_signed(Duration::days(1)),
        TimeType::Week => start.checked_add_signed(Duration::days(7)),
        TimeType::Month => start.checked_add_months(Months::new(1)),
        TimeType::Someday => None,
    }
}

pub fn is_expired(task: &TodoTask, reference_date: NaiveDate) -> bool {
    task.period_start
        .and_then(|start| next_start(task.time_type, start))
        .is_some_and(|end| end <= reference_date)
}

pub fn occurrence_id(series_id: &str, time_type: TimeType, period_start: NaiveDate) -> String {
    let source = format!(
        "woo-todo-occurrence-v1|{}|{}|{}",
        series_id.to_lowercase(),
        time_type_wire(time_type),
        period_start.format("%Y-%m-%d")
    );
    let mut digest: [u8; 32] = Sha256::digest(source.as_bytes()).into();
    digest[6] = (digest[6] & 0x0f) | 0x50;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    Uuid::from_bytes(bytes).hyphenated().to_string()
}

pub fn time_type_wire(value: TimeType) -> &'static str {
    match value {
        TimeType::Day => "day",
        TimeType::Week => "week",
        TimeType::Month => "month",
        TimeType::Someday => "someday",
    }
}
