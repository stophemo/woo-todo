use std::env;
use std::path::Path;

use woo_todo_core::{TaskRepository, TaskState};

fn main() -> Result<(), String> {
    let mut arguments = env::args().skip(1);
    let database = arguments
        .next()
        .ok_or_else(|| "缺少数据库路径".to_owned())?;
    let expected_title = arguments.next().ok_or_else(|| "缺少任务标题".to_owned())?;
    let expected_state = arguments.next().ok_or_else(|| "缺少任务状态".to_owned())?;
    if arguments.next().is_some() {
        return Err("参数过多".to_owned());
    }

    let repository = TaskRepository::open(Path::new(&database))
        .map_err(|error| format!("无法打开烟测数据库：{error}"))?;
    let tasks = repository
        .fetch_all()
        .map_err(|error| format!("无法读取烟测任务：{error}"))?;
    if tasks.len() != 1 {
        return Err(format!(
            "预期数据库只有 1 条任务，实际为 {} 条",
            tasks.len()
        ));
    }
    let task = &tasks[0];
    if task.title != expected_title {
        return Err(format!(
            "任务标题不匹配：预期 {expected_title:?}，实际 {:?}",
            task.title
        ));
    }
    let actual_state = match task.state {
        TaskState::Pending => "pending",
        TaskState::Completed => "completed",
        TaskState::Pass => "pass",
    };
    if actual_state != expected_state {
        return Err(format!(
            "任务状态不匹配：预期 {expected_state}，实际 {actual_state}"
        ));
    }

    println!("任务数据符合预期：{} / {}", task.title, actual_state);
    Ok(())
}
