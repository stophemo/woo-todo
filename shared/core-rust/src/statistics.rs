use std::collections::BTreeMap;

use chrono::{Duration, Months, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::model::{QuestLine, TaskState, TimeType, TodoTask};
use crate::period::{is_expired, next_start, normalize_start};

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusCounts {
    pub pending: usize,
    pub completed: usize,
    pub pass: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdherenceMetric {
    pub completed: usize,
    pub pass: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendBucket {
    pub start: NaiveDate,
    pub end_exclusive: NaiveDate,
    pub completed: usize,
    pub pass: usize,
    pub is_ended: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatisticsSnapshot {
    pub ended_periods: AdherenceMetric,
    pub main_ended_periods: AdherenceMetric,
    pub by_time_type: BTreeMap<TimeType, StatusCounts>,
    pub by_quest_line: BTreeMap<QuestLine, StatusCounts>,
    pub daily_trend: Vec<TrendBucket>,
    pub weekly_trend: Vec<TrendBucket>,
    pub monthly_trend: Vec<TrendBucket>,
    pub recent_history: Vec<TodoTask>,
}

pub fn calculate_statistics(
    tasks: &[TodoTask],
    reference_date: NaiveDate,
    history_limit: usize,
) -> StatisticsSnapshot {
    let ended: Vec<&TodoTask> = tasks
        .iter()
        .filter(|task| task.state != TaskState::Pending && is_expired(task, reference_date))
        .collect();
    let mut by_time_type = BTreeMap::new();
    for value in [
        TimeType::Day,
        TimeType::Week,
        TimeType::Month,
        TimeType::Someday,
    ] {
        by_time_type.insert(
            value,
            counts(tasks.iter().filter(|task| task.time_type == value)),
        );
    }
    let mut by_quest_line = BTreeMap::new();
    for value in [QuestLine::Main, QuestLine::Side, QuestLine::Extra] {
        by_quest_line.insert(
            value,
            counts(tasks.iter().filter(|task| task.quest_line == value)),
        );
    }
    let mut history: Vec<TodoTask> = tasks
        .iter()
        .filter(|task| task.state != TaskState::Pending && task.settled_at.is_some())
        .cloned()
        .collect();
    history.sort_by(|left, right| {
        right
            .settled_at
            .cmp(&left.settled_at)
            .then_with(|| right.updated_at.cmp(&left.updated_at))
            .then_with(|| left.id.cmp(&right.id))
    });
    history.truncate(history_limit);

    StatisticsSnapshot {
        ended_periods: metric(ended.iter().copied()),
        main_ended_periods: metric(
            ended
                .iter()
                .copied()
                .filter(|task| task.quest_line == QuestLine::Main),
        ),
        by_time_type,
        by_quest_line,
        daily_trend: trend(tasks, TimeType::Day, 7, reference_date),
        weekly_trend: trend(tasks, TimeType::Week, 8, reference_date),
        monthly_trend: trend(tasks, TimeType::Month, 6, reference_date),
        recent_history: history,
    }
}

fn metric<'a>(tasks: impl Iterator<Item = &'a TodoTask>) -> AdherenceMetric {
    let mut value = AdherenceMetric::default();
    for task in tasks {
        match task.state {
            TaskState::Completed => value.completed += 1,
            TaskState::Pass => value.pass += 1,
            TaskState::Pending => {}
        }
    }
    value
}

fn counts<'a>(tasks: impl Iterator<Item = &'a TodoTask>) -> StatusCounts {
    let mut value = StatusCounts::default();
    for task in tasks {
        match task.state {
            TaskState::Pending => value.pending += 1,
            TaskState::Completed => value.completed += 1,
            TaskState::Pass => value.pass += 1,
        }
    }
    value
}

fn trend(
    tasks: &[TodoTask],
    time_type: TimeType,
    count: usize,
    reference_date: NaiveDate,
) -> Vec<TrendBucket> {
    let Some(current) = normalize_start(time_type, reference_date) else {
        return Vec::new();
    };
    (0..count)
        .rev()
        .filter_map(|offset| {
            let start = match time_type {
                TimeType::Day => current.checked_sub_signed(Duration::days(offset as i64)),
                TimeType::Week => current.checked_sub_signed(Duration::days((offset * 7) as i64)),
                TimeType::Month => current.checked_sub_months(Months::new(offset as u32)),
                TimeType::Someday => None,
            }?;
            let end = next_start(time_type, start)?;
            let outcomes = tasks.iter().filter(|task| {
                task.time_type == time_type
                    && task.period_start == Some(start)
                    && task.state != TaskState::Pending
            });
            let metric = metric(outcomes);
            Some(TrendBucket {
                start,
                end_exclusive: end,
                completed: metric.completed,
                pass: metric.pass,
                is_ended: end <= reference_date,
            })
        })
        .collect()
}
