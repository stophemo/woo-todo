use std::collections::HashSet;

use chrono::{FixedOffset, NaiveDate, NaiveTime, TimeZone, Utc};
use sha2::{Digest, Sha256};
use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::DateTime;
use windows::UI::Notifications::{ScheduledToastNotification, ToastNotificationManager};
use windows::core::{HSTRING, Result};
use woo_todo_core::{NotificationPlan, TodoTask, notification_plans};

const APP_ID: &str = "stophemo.WooTodo";
const WINDOWS_EPOCH_OFFSET_SECONDS: i64 = 11_644_473_600;
const MAXIMUM_SCHEDULED_NOTIFICATIONS: usize = 4_096;

pub fn reconcile(tasks: &[TodoTask]) -> Result<()> {
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_ID))?;
    let now = Utc::now().timestamp();
    let desired = notification_plans(tasks)
        .into_iter()
        .filter_map(|plan| {
            let unix_seconds = delivery_timestamp(&plan.fire_date, &plan.fire_time)?;
            let ticks = windows_ticks(unix_seconds)?;
            (unix_seconds > now + 2).then_some((schedule_id(&plan), plan, ticks))
        })
        .take(MAXIMUM_SCHEDULED_NOTIFICATIONS)
        .collect::<Vec<_>>();
    let desired_ids = desired
        .iter()
        .map(|(id, _, _)| id.clone())
        .collect::<HashSet<_>>();
    let existing = notifier
        .GetScheduledToastNotifications()?
        .into_iter()
        .map(|notification| {
            let id = notification.Id()?.to_string();
            Ok((id, notification))
        })
        .collect::<Result<Vec<_>>>()?;
    let existing_ids = existing
        .iter()
        .map(|(id, _)| id.clone())
        .collect::<HashSet<_>>();

    // 先补齐新计划，再删除旧计划；中途失败时不会先清空用户已有的提醒。
    for (id, plan, ticks) in &desired {
        if !existing_ids.contains(id) {
            notifier.AddToSchedule(&build_notification(id, plan, *ticks)?)?;
        }
    }
    for (id, notification) in existing {
        if id.starts_with("woo-") && !desired_ids.contains(&id) {
            notifier.RemoveFromSchedule(&notification)?;
        }
    }
    Ok(())
}

fn build_notification(
    id: &str,
    plan: &NotificationPlan,
    delivery_ticks: i64,
) -> Result<ScheduledToastNotification> {
    let xml = format!(
        "<toast activationType=\"protocol\" launch=\"{}\"><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual></toast>",
        xml_escape(&plan.deep_link),
        xml_escape(&plan.title),
        xml_escape(&plan.body),
    );
    let document = XmlDocument::new()?;
    document.LoadXml(&HSTRING::from(xml))?;
    let delivery = DateTime {
        UniversalTime: delivery_ticks,
    };
    let notification =
        ScheduledToastNotification::CreateScheduledToastNotification(&document, delivery)?;
    notification.SetId(&HSTRING::from(id))?;
    Ok(notification)
}

fn delivery_timestamp(date: &str, time: &str) -> Option<i64> {
    let date = NaiveDate::parse_from_str(date, "%Y-%m-%d").ok()?;
    let time = NaiveTime::parse_from_str(time, "%H:%M").ok()?;
    let offset = FixedOffset::east_opt(8 * 60 * 60)?;
    offset
        .from_local_datetime(&date.and_time(time))
        .single()
        .map(|value| value.timestamp())
}

fn windows_ticks(unix_seconds: i64) -> Option<i64> {
    unix_seconds
        .checked_add(WINDOWS_EPOCH_OFFSET_SECONDS)?
        .checked_mul(10_000_000)
}

fn schedule_id(plan: &NotificationPlan) -> String {
    let fingerprint = [
        plan.id.as_str(),
        plan.title.as_str(),
        plan.body.as_str(),
        plan.deep_link.as_str(),
    ]
    .join("\n");
    let digest = Sha256::digest(fingerprint.as_bytes());
    // Windows ScheduledToastNotification::Id 最多 16 个字符；前缀 4 个字符后保留 48 位摘要。
    let suffix = digest[..6]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    format!("woo-{suffix}")
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_identifier_is_short_and_stable() {
        let plan = NotificationPlan {
            id: "task-reminder:abc:2026-07-27:09:30".to_owned(),
            task_id: "abc".to_owned(),
            fire_date: "2026-07-27".to_owned(),
            fire_time: "09:30".to_owned(),
            title: "待办提醒".to_owned(),
            body: "完成文档".to_owned(),
            deep_link: "wootodo://task-reminder/abc".to_owned(),
        };
        let first = schedule_id(&plan);
        assert_eq!(first, schedule_id(&plan));
        assert!(first.starts_with("woo-"));
        assert_eq!(first.len(), 16);

        let mut changed = plan.clone();
        changed.body = "完成发布文档".to_owned();
        assert_ne!(first, schedule_id(&changed));
    }

    #[test]
    fn xml_values_are_escaped() {
        assert_eq!(
            xml_escape("A&B <C> \"D\""),
            "A&amp;B &lt;C&gt; &quot;D&quot;"
        );
    }
}
