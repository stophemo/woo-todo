use std::cmp::Ordering;

use chrono::{Datelike, NaiveDate};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::period::normalize_start;

pub const TIMEZONE: &str = "Asia/Shanghai";
pub const MAXIMUM_TITLE_CODE_POINTS: usize = 120;
pub const MAXIMUM_JSON_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TimeType {
    Day,
    Week,
    Month,
    Someday,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QuestLine {
    Main,
    Side,
    Extra,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskState {
    Pending,
    Completed,
    Pass,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Recurrence {
    Once,
    Repeat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ReminderTime {
    pub hour: u8,
    pub minute: u8,
}

impl ReminderTime {
    pub fn new(hour: u8, minute: u8) -> CoreResult<Self> {
        if hour > 23 || minute > 59 {
            return Err(CoreError::validation("提醒时间必须是有效的 HH:mm 墙钟时间"));
        }
        Ok(Self { hour, minute })
    }

    pub fn parse(value: &str) -> CoreResult<Self> {
        let (hour, minute) = value
            .split_once(':')
            .ok_or_else(|| CoreError::validation("提醒时间必须使用 HH:mm 格式"))?;
        if hour.len() != 2 || minute.len() != 2 {
            return Err(CoreError::validation("提醒时间必须使用 HH:mm 格式"));
        }
        Self::new(
            hour.parse()
                .map_err(|_| CoreError::validation("提醒小时无效"))?,
            minute
                .parse()
                .map_err(|_| CoreError::validation("提醒分钟无效"))?,
        )
    }

    pub fn wire_value(self) -> String {
        format!("{:02}:{:02}", self.hour, self.minute)
    }
}

impl Serialize for ReminderTime {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.wire_value())
    }
}

impl<'de> Deserialize<'de> for ReminderTime {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoTask {
    pub id: String,
    pub series_id: String,
    pub title: String,
    pub time_type: TimeType,
    pub period_start: Option<NaiveDate>,
    #[serde(default = "default_timezone")]
    pub timezone: String,
    pub quest_line: QuestLine,
    pub state: TaskState,
    pub recurrence: Recurrence,
    pub sort_order: i32,
    pub created_at: i64,
    pub updated_at: i64,
    pub settled_at: Option<i64>,
    #[serde(default)]
    pub reminder_time: Option<ReminderTime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deadline_date: Option<NaiveDate>,
}

impl TodoTask {
    #[allow(clippy::too_many_arguments)]
    pub fn create(
        title: &str,
        time_type: TimeType,
        reference_date: NaiveDate,
        quest_line: QuestLine,
        repeats: bool,
        sort_order: i32,
        now: i64,
        reminder_time: Option<ReminderTime>,
        deadline_date: Option<NaiveDate>,
        id: Option<String>,
    ) -> CoreResult<Self> {
        let id = id.unwrap_or_else(|| Uuid::new_v4().hyphenated().to_string());
        let task = Self {
            series_id: id.clone(),
            id,
            title: validate_title(title)?,
            time_type,
            period_start: normalize_start(time_type, reference_date),
            timezone: TIMEZONE.to_owned(),
            quest_line,
            state: TaskState::Pending,
            recurrence: if repeats && time_type != TimeType::Someday {
                Recurrence::Repeat
            } else {
                Recurrence::Once
            },
            sort_order: sort_order.max(0),
            created_at: now,
            updated_at: now,
            settled_at: None,
            reminder_time: if time_type == TimeType::Someday {
                None
            } else {
                reminder_time
            },
            deadline_date,
        };
        task.validate()?;
        Ok(task)
    }

    pub fn validate(&self) -> CoreResult<()> {
        validate_identifier(&self.id, "任务 ID")?;
        validate_identifier(&self.series_id, "重复序列 ID")?;
        validate_title(&self.title)?;
        if self.sort_order < 0 {
            return Err(CoreError::validation("任务排序值不能为负数"));
        }
        validate_timestamp(self.created_at, "createdAt")?;
        validate_timestamp(self.updated_at, "updatedAt")?;
        if let Some(value) = self.settled_at {
            validate_timestamp(value, "settledAt")?;
        }
        if (self.time_type == TimeType::Someday) != self.period_start.is_none() {
            return Err(CoreError::validation(
                "日、周、月任务必须指定周期，闲时任务不能指定周期",
            ));
        }
        if let Some(start) = self.period_start
            && normalize_start(self.time_type, start) != Some(start)
        {
            return Err(CoreError::validation("任务周期起点未按日、周或月归一化"));
        }
        if self
            .deadline_date
            .is_some_and(|deadline| !(1..=9999).contains(&deadline.year()))
        {
            return Err(CoreError::validation(
                "deadlineDate 必须是 0001-01-01 到 9999-12-31 之间的日期",
            ));
        }
        if self.timezone != TIMEZONE {
            return Err(CoreError::validation("任务时区必须是 Asia/Shanghai"));
        }
        if self.time_type == TimeType::Someday
            && (self.recurrence != Recurrence::Once || self.reminder_time.is_some())
        {
            return Err(CoreError::validation("闲时任务不能重复或设置提醒"));
        }
        match (self.state, self.settled_at) {
            (TaskState::Pending, None) | (TaskState::Completed | TaskState::Pass, Some(_)) => {
                Ok(())
            }
            _ => Err(CoreError::validation(
                "pending 任务不能有结算时间，completed/pass 任务必须有结算时间",
            )),
        }
    }
}

fn default_timezone() -> String {
    TIMEZONE.to_owned()
}

pub fn validate_title(value: &str) -> CoreResult<String> {
    let normalized = value.trim();
    if normalized.is_empty() {
        return Err(CoreError::validation("任务标题不能为空"));
    }
    if normalized.chars().count() > MAXIMUM_TITLE_CODE_POINTS {
        return Err(CoreError::validation(
            "任务标题不能超过 120 个 Unicode code point",
        ));
    }
    Ok(normalized.to_owned())
}

fn validate_identifier(value: &str, label: &str) -> CoreResult<()> {
    if !(8..=128).contains(&value.len())
        || !value.bytes().all(|value| {
            value.is_ascii_alphanumeric() || matches!(value, b'.' | b'_' | b':' | b'-')
        })
    {
        return Err(CoreError::validation(format!(
            "{label} 必须是 8 到 128 位 ASCII 安全标识符"
        )));
    }
    Ok(())
}

fn validate_timestamp(value: i64, field: &str) -> CoreResult<()> {
    if !(0..=MAXIMUM_JSON_INTEGER).contains(&value) {
        return Err(CoreError::validation(format!(
            "{field} 必须位于 JSON safe integer 范围"
        )));
    }
    Ok(())
}

pub fn compare_tasks(left: &TodoTask, right: &TodoTask) -> Ordering {
    left.quest_line
        .cmp(&right.quest_line)
        .then_with(|| left.state.cmp(&right.state))
        .then_with(|| left.sort_order.cmp(&right.sort_order))
        .then_with(|| left.created_at.cmp(&right.created_at))
        .then_with(|| left.id.cmp(&right.id))
}

pub fn sort_tasks(tasks: &mut [TodoTask]) {
    tasks.sort_by(compare_tasks);
}
