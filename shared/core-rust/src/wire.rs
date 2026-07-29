use std::collections::BTreeSet;

use chrono::{Datelike, NaiveDate, Weekday};
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

use crate::error::{CoreError, CoreResult};
use crate::model::{
    MAXIMUM_JSON_INTEGER, QuestLine, Recurrence, ReminderTime, TIMEZONE, TaskState, TimeType,
    TodoTask,
};

pub const PROTOCOL_VERSION: i32 = 1;
pub const DISPLAY_CONFIGURATION_ENTITY_ID: &str = "display.today.configuration";
pub const MAXIMUM_SORT_ORDER: i64 = i32::MAX as i64;
pub const MAXIMUM_CIPHERTEXT_BYTES: usize = 32 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OperationKind {
    Upsert,
    Delete,
    Complete,
    Pass,
    Reopen,
    Reorder,
}

impl OperationKind {
    pub const fn wire_value(self) -> &'static str {
        match self {
            Self::Upsert => "upsert",
            Self::Delete => "delete",
            Self::Complete => "complete",
            Self::Pass => "pass",
            Self::Reopen => "reopen",
            Self::Reorder => "reorder",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EncryptedEnvelope {
    pub ciphertext: String,
    pub nonce: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncPushOperation {
    pub op_id: String,
    pub entity_id: String,
    pub kind: OperationKind,
    pub lamport: i64,
    pub ciphertext: String,
    pub nonce: String,
}

impl SyncPushOperation {
    pub fn validate(&self) -> CoreResult<()> {
        validate_sync_identifier(&self.op_id, "opId")?;
        validate_sync_identifier(&self.entity_id, "entityId")?;
        if self.lamport < 1 {
            return Err(CoreError::validation("lamport 必须大于等于 1"));
        }
        validate_envelope(&self.nonce, &self.ciphertext)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncPulledOperation {
    pub server_seq: i64,
    pub op_id: String,
    pub device_id: String,
    pub entity_id: String,
    pub kind: OperationKind,
    pub lamport: i64,
    pub ciphertext: String,
    pub nonce: String,
    pub created_at: i64,
}

impl SyncPulledOperation {
    pub fn validate(&self) -> CoreResult<()> {
        if self.server_seq < 1 {
            return Err(CoreError::validation("serverSeq 必须大于等于 1"));
        }
        validate_sync_identifier(&self.op_id, "opId")?;
        validate_sync_identifier(&self.device_id, "deviceId")?;
        validate_sync_identifier(&self.entity_id, "entityId")?;
        if self.lamport < 1 {
            return Err(CoreError::validation("lamport 必须大于等于 1"));
        }
        validate_wire_timestamp(self.created_at, "createdAt")?;
        validate_envelope(&self.nonce, &self.ciphertext)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncRequest {
    pub cursor: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ack: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pull_limit: Option<usize>,
    pub push: Vec<SyncPushOperation>,
}

impl SyncRequest {
    pub fn validate(&self) -> CoreResult<()> {
        if self.cursor < 0 || self.ack.is_some_and(|value| value < 0) {
            return Err(CoreError::validation("cursor 与 ack 不能为负数"));
        }
        if self
            .pull_limit
            .is_some_and(|value| !(1..=100).contains(&value))
        {
            return Err(CoreError::validation("pullLimit 必须是 1 到 100"));
        }
        if self.push.len() > 50 {
            return Err(CoreError::validation("单次 push 不能超过 50 条操作"));
        }
        self.push.iter().try_for_each(SyncPushOperation::validate)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncPushSummary {
    pub received: usize,
    pub inserted: usize,
    pub duplicates: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncData {
    pub push: SyncPushSummary,
    pub pull: Vec<SyncPulledOperation>,
    pub cursor: i64,
    pub has_more: bool,
    pub server_time: i64,
}

impl SyncData {
    pub fn validate(&self) -> CoreResult<()> {
        if self.pull.len() > 100 {
            return Err(CoreError::validation("单次 pull 不能超过 100 条操作"));
        }
        if self.cursor < 0 {
            return Err(CoreError::validation("cursor 不能为负数"));
        }
        validate_wire_timestamp(self.server_time, "serverTime")?;
        self.pull.iter().try_for_each(SyncPulledOperation::validate)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireTaskPayload {
    pub protocol_version: i32,
    pub entity_type: String,
    pub id: String,
    pub series_id: String,
    pub title: String,
    pub time_type: TimeType,
    pub period_start: Option<NaiveDate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deadline_date: Option<NaiveDate>,
    pub timezone: String,
    pub quest_line: QuestLine,
    pub state: TaskState,
    pub recurrence: Recurrence,
    pub sort_order: i64,
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reminder_time: Option<ReminderTime>,
    pub settled_at: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireTaskPayloadUnchecked {
    protocol_version: i32,
    entity_type: String,
    id: String,
    series_id: String,
    title: String,
    time_type: TimeType,
    period_start: Value,
    #[serde(default)]
    deadline_date: Option<NaiveDate>,
    timezone: String,
    quest_line: QuestLine,
    state: TaskState,
    recurrence: Recurrence,
    sort_order: i64,
    created_at: i64,
    updated_at: i64,
    #[serde(default)]
    reminder_time: Option<ReminderTime>,
    settled_at: Value,
}

impl<'de> Deserialize<'de> for WireTaskPayload {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = WireTaskPayloadUnchecked::deserialize(deserializer)?;
        let period_start = nullable_value(raw.period_start).map_err(D::Error::custom)?;
        let settled_at = nullable_value(raw.settled_at).map_err(D::Error::custom)?;
        let payload = Self {
            protocol_version: raw.protocol_version,
            entity_type: raw.entity_type,
            id: raw.id,
            series_id: raw.series_id,
            title: raw.title,
            time_type: raw.time_type,
            period_start,
            deadline_date: raw.deadline_date,
            timezone: raw.timezone,
            quest_line: raw.quest_line,
            state: raw.state,
            recurrence: raw.recurrence,
            sort_order: raw.sort_order,
            created_at: raw.created_at,
            updated_at: raw.updated_at,
            reminder_time: raw.reminder_time,
            settled_at,
        };
        payload.validate().map_err(D::Error::custom)?;
        Ok(payload)
    }
}

impl WireTaskPayload {
    pub fn from_task(task: &TodoTask) -> CoreResult<Self> {
        task.validate()?;
        Ok(Self {
            protocol_version: PROTOCOL_VERSION,
            entity_type: "task".to_owned(),
            id: canonical_entity_id(&task.id),
            series_id: canonical_entity_id(&task.series_id),
            title: task.title.clone(),
            time_type: task.time_type,
            period_start: task.period_start,
            deadline_date: task.deadline_date,
            timezone: task.timezone.clone(),
            quest_line: task.quest_line,
            state: task.state,
            recurrence: task.recurrence,
            sort_order: i64::from(task.sort_order),
            created_at: task.created_at,
            updated_at: task.updated_at,
            reminder_time: task.reminder_time,
            settled_at: task.settled_at,
        })
    }

    pub fn into_task(self) -> CoreResult<TodoTask> {
        self.validate()?;
        let sort_order = i32::try_from(self.sort_order)
            .map_err(|_| CoreError::validation("sortOrder 超出 Int32 范围"))?;
        let task = TodoTask {
            id: canonical_entity_id(&self.id),
            series_id: canonical_entity_id(&self.series_id),
            title: self.title,
            time_type: self.time_type,
            period_start: self.period_start,
            timezone: self.timezone,
            quest_line: self.quest_line,
            state: self.state,
            recurrence: self.recurrence,
            sort_order,
            created_at: self.created_at,
            updated_at: self.updated_at,
            settled_at: self.settled_at,
            reminder_time: self.reminder_time,
            deadline_date: self.deadline_date,
        };
        task.validate()?;
        Ok(task)
    }

    pub fn validate(&self) -> CoreResult<()> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(CoreError::validation("不支持的任务正文协议版本"));
        }
        if self.entity_type != "task" {
            return Err(CoreError::validation("任务正文 entityType 无效"));
        }
        validate_task_identifier(&self.id, "id")?;
        validate_task_identifier(&self.series_id, "seriesId")?;
        if !(1..=120).contains(&self.title.chars().count()) {
            return Err(CoreError::validation(
                "任务标题必须为 1 到 120 个 Unicode 字符",
            ));
        }
        if self.timezone != TIMEZONE {
            return Err(CoreError::validation("任务时区必须是 Asia/Shanghai"));
        }
        if !(0..=MAXIMUM_SORT_ORDER).contains(&self.sort_order) {
            return Err(CoreError::validation("sortOrder 超出范围"));
        }
        validate_wire_timestamp(self.created_at, "createdAt")?;
        validate_wire_timestamp(self.updated_at, "updatedAt")?;
        if let Some(settled_at) = self.settled_at {
            validate_wire_timestamp(settled_at, "settledAt")?;
        }
        if let Some(date) = self.period_start {
            validate_period_start(date, self.time_type)?;
        }
        if self.time_type == TimeType::Someday {
            if self.period_start.is_some()
                || self.recurrence != Recurrence::Once
                || self.reminder_time.is_some()
            {
                return Err(CoreError::validation(
                    "闲时任务的周期、重复或提醒字段组合无效",
                ));
            }
        } else if self.period_start.is_none() {
            return Err(CoreError::validation("日、周、月任务必须包含 periodStart"));
        }
        match (self.state, self.settled_at) {
            (TaskState::Pending, None) | (TaskState::Completed | TaskState::Pass, Some(_)) => {
                Ok(())
            }
            _ => Err(CoreError::validation("任务状态与 settledAt 组合无效")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WireTombstonePayload {
    pub protocol_version: i32,
    pub entity_type: String,
    pub id: String,
    pub deleted_at: i64,
}

impl WireTombstonePayload {
    pub fn new(id: impl Into<String>, deleted_at: i64) -> CoreResult<Self> {
        let value = Self {
            protocol_version: PROTOCOL_VERSION,
            entity_type: "tombstone".to_owned(),
            id: canonical_entity_id(&id.into()),
            deleted_at,
        };
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> CoreResult<()> {
        if self.protocol_version != PROTOCOL_VERSION || self.entity_type != "tombstone" {
            return Err(CoreError::validation("删除正文协议或实体类型无效"));
        }
        validate_task_identifier(&self.id, "id")?;
        validate_wire_timestamp(self.deleted_at, "deletedAt")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WireDisplayConfigurationPayload {
    pub protocol_version: i32,
    pub entity_type: String,
    pub id: String,
    pub header_template: String,
    pub subtitle_template: String,
    pub start_date: NaiveDate,
    pub deadline_date: NaiveDate,
}

impl WireDisplayConfigurationPayload {
    pub fn new(
        header_template: impl Into<String>,
        subtitle_template: impl Into<String>,
        start_date: NaiveDate,
        deadline_date: NaiveDate,
    ) -> CoreResult<Self> {
        let value = Self {
            protocol_version: PROTOCOL_VERSION,
            entity_type: "displayConfiguration".to_owned(),
            id: DISPLAY_CONFIGURATION_ENTITY_ID.to_owned(),
            header_template: header_template.into(),
            subtitle_template: subtitle_template.into(),
            start_date,
            deadline_date,
        };
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> CoreResult<()> {
        if self.protocol_version != PROTOCOL_VERSION
            || self.entity_type != "displayConfiguration"
            || self.id != DISPLAY_CONFIGURATION_ENTITY_ID
        {
            return Err(CoreError::validation("显示配置协议、类型或 ID 无效"));
        }
        if self.header_template.chars().count() > 80
            || self.subtitle_template.chars().count() > 160
            || self.header_template.chars().any(is_json_newline)
            || self.subtitle_template.chars().any(is_json_newline)
        {
            return Err(CoreError::validation("显示模板长度超限或包含换行"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum WireEntity {
    Task(WireTaskPayload),
    Tombstone(WireTombstonePayload),
    DisplayConfiguration(WireDisplayConfigurationPayload),
}

impl<'de> Deserialize<'de> for WireEntity {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        let entity_type = value
            .as_object()
            .and_then(|object| object.get("entityType"))
            .and_then(Value::as_str)
            .ok_or_else(|| D::Error::custom("正文缺少 entityType"))?;
        match entity_type {
            "task" => serde_json::from_value(value)
                .map(Self::Task)
                .map_err(D::Error::custom),
            "tombstone" => {
                let payload: WireTombstonePayload =
                    serde_json::from_value(value).map_err(D::Error::custom)?;
                payload.validate().map_err(D::Error::custom)?;
                Ok(Self::Tombstone(payload))
            }
            "displayConfiguration" => {
                let payload: WireDisplayConfigurationPayload =
                    serde_json::from_value(value).map_err(D::Error::custom)?;
                payload.validate().map_err(D::Error::custom)?;
                Ok(Self::DisplayConfiguration(payload))
            }
            _ => Err(D::Error::custom("不支持的正文 entityType")),
        }
    }
}

pub fn encode_entity(entity: &WireEntity) -> CoreResult<Vec<u8>> {
    canonical_json(entity)
}

pub fn decode_entity(data: &[u8]) -> CoreResult<WireEntity> {
    serde_json::from_slice(data).map_err(Into::into)
}

pub fn decode_sync_request(data: &[u8]) -> CoreResult<SyncRequest> {
    let request: SyncRequest = serde_json::from_slice(data)?;
    request.validate()?;
    Ok(request)
}

pub fn decode_sync_data(data: &[u8]) -> CoreResult<SyncData> {
    let response: SyncData = serde_json::from_slice(data)?;
    response.validate()?;
    Ok(response)
}

pub(crate) fn canonical_json<T: Serialize>(value: &T) -> CoreResult<Vec<u8>> {
    let mut value = serde_json::to_value(value)?;
    sort_json(&mut value);
    serde_json::to_vec(&value).map_err(Into::into)
}

fn sort_json(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for nested in object.values_mut() {
                sort_json(nested);
            }
            let keys = object.keys().cloned().collect::<BTreeSet<_>>();
            let mut sorted = serde_json::Map::new();
            for key in keys {
                if let Some(value) = object.remove(&key) {
                    sorted.insert(key, value);
                }
            }
            *object = sorted;
        }
        Value::Array(values) => values.iter_mut().for_each(sort_json),
        _ => {}
    }
}

fn nullable_value<T>(value: Value) -> Result<Option<T>, serde_json::Error>
where
    T: for<'de> Deserialize<'de>,
{
    if value.is_null() {
        Ok(None)
    } else {
        serde_json::from_value(value).map(Some)
    }
}

fn validate_envelope(nonce: &str, ciphertext: &str) -> CoreResult<()> {
    let nonce_bytes = crate::crypto::base64url_decode(nonce)?;
    if nonce_bytes.len() != 12 {
        return Err(CoreError::validation("nonce 必须解码为 12 字节"));
    }
    let ciphertext_bytes = crate::crypto::base64url_decode(ciphertext)?;
    if !(16..=MAXIMUM_CIPHERTEXT_BYTES).contains(&ciphertext_bytes.len()) {
        return Err(CoreError::validation("ciphertext 长度无效"));
    }
    Ok(())
}

fn validate_sync_identifier(value: &str, field: &str) -> CoreResult<()> {
    if !(1..=128).contains(&value.chars().count()) {
        return Err(CoreError::validation(format!(
            "{field} 长度必须为 1 到 128"
        )));
    }
    Ok(())
}

fn validate_task_identifier(value: &str, field: &str) -> CoreResult<()> {
    if !(8..=128).contains(&value.len())
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
    {
        return Err(CoreError::validation(format!("{field} 不是安全任务标识符")));
    }
    Ok(())
}

fn validate_period_start(value: NaiveDate, time_type: TimeType) -> CoreResult<()> {
    let valid = match time_type {
        TimeType::Day => true,
        TimeType::Week => value.weekday() == Weekday::Mon,
        TimeType::Month => value.day() == 1,
        TimeType::Someday => false,
    };
    if valid {
        Ok(())
    } else {
        Err(CoreError::validation("periodStart 未按日、周或月归一化"))
    }
}

fn validate_wire_timestamp(value: i64, field: &str) -> CoreResult<()> {
    if !(0..=MAXIMUM_JSON_INTEGER).contains(&value) {
        return Err(CoreError::validation(format!(
            "{field} 超出 JSON safe integer 范围"
        )));
    }
    Ok(())
}

fn is_json_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\r' | '\u{000b}' | '\u{000c}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
    )
}

pub fn canonical_entity_id(value: &str) -> String {
    uuid::Uuid::parse_str(value)
        .map(|value| value.hyphenated().to_string())
        .unwrap_or_else(|_| value.to_owned())
}
