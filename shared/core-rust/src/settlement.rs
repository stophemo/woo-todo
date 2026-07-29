use std::collections::{BTreeSet, HashMap, HashSet};

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::model::{Recurrence, TaskState, TodoTask, sort_tasks};
use crate::period::{is_expired, next_start, occurrence_id};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettlementResult {
    pub tasks: Vec<TodoTask>,
    pub changed_task_ids: BTreeSet<String>,
    pub generated_task_ids: BTreeSet<String>,
}

pub fn settle(
    source: &[TodoTask],
    reference_date: NaiveDate,
    now: i64,
    reserved_task_ids: &HashSet<String>,
) -> SettlementResult {
    let mut tasks: HashMap<String, TodoTask> = source
        .iter()
        .cloned()
        .map(|task| (task.id.clone(), task))
        .collect();
    let mut occurrence_keys: HashSet<(String, crate::model::TimeType, NaiveDate)> = tasks
        .values()
        .filter_map(|task| {
            task.period_start
                .map(|start| (task.series_id.clone(), task.time_type, start))
        })
        .collect();
    let mut queue: Vec<TodoTask> = tasks.values().cloned().collect();
    queue.sort_by_key(|task| task.period_start.unwrap_or(NaiveDate::MAX));
    let mut changed = BTreeSet::new();
    let mut generated = BTreeSet::new();
    let mut index = 0;

    while index < queue.len() {
        let mut task = queue[index].clone();
        index += 1;
        if !is_expired(&task, reference_date) {
            continue;
        }
        if task.recurrence != Recurrence::Repeat {
            // 一次性任务由用户主动完成或 Pass，跨周期后仍保持原状态。
            continue;
        }
        if task.state == TaskState::Pending {
            task.state = TaskState::Pass;
            task.updated_at = now;
            task.settled_at = Some(now);
            tasks.insert(task.id.clone(), task.clone());
            changed.insert(task.id.clone());
        }
        let Some(current_start) = task.period_start else {
            continue;
        };
        let Some(next_period_start) = next_start(task.time_type, current_start) else {
            continue;
        };
        let key = (task.series_id.clone(), task.time_type, next_period_start);
        if !occurrence_keys.insert(key) {
            continue;
        }
        let next_id = occurrence_id(&task.series_id, task.time_type, next_period_start);
        if tasks.contains_key(&next_id) || reserved_task_ids.contains(&next_id) {
            continue;
        }
        let next_task = TodoTask {
            id: next_id.clone(),
            period_start: Some(next_period_start),
            state: TaskState::Pending,
            created_at: now,
            updated_at: now,
            settled_at: None,
            deadline_date: None,
            ..task
        };
        tasks.insert(next_id.clone(), next_task.clone());
        queue.push(next_task);
        generated.insert(next_id);
    }

    let mut values: Vec<TodoTask> = tasks.into_values().collect();
    sort_tasks(&mut values);
    SettlementResult {
        tasks: values,
        changed_task_ids: changed,
        generated_task_ids: generated,
    }
}
