using WooTodo.Core;
using WooTodo.Storage;

namespace WooTodo.Core.Tests;

public sealed class TaskRepositoryTests
{
    [Fact]
    public void Repository_RoundTripsAndSettlesIdempotently()
    {
        var directory = Path.Combine(Path.GetTempPath(), "woo-todo-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var database = Path.Combine(directory, "tasks.sqlite3");
        try
        {
            long now = 1;
            using (var repository = new TaskRepository(database, () => now++))
            {
                var id = repository.Create("月度复盘", TaskTimeType.Month, new DateOnly(2026, 5, 22), QuestLine.Main, repeats: true);
                Assert.Equal("月度复盘", repository.Find(id)!.Title);
                var result = repository.SettleExpired(new DateOnly(2026, 7, 24));
                Assert.Equal(3, result.Tasks.Count);
            }

            using (var reopened = new TaskRepository(database, () => now++))
            {
                Assert.Equal(3, reopened.FetchAll().Count);
                var result = reopened.SettleExpired(new DateOnly(2026, 7, 24));
                Assert.Empty(result.ChangedTaskIds);
                Assert.Empty(result.GeneratedTaskIds);
            }
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void DeletingPendingOccurrenceReservesItsDeterministicId()
    {
        var database = Path.Combine(Path.GetTempPath(), $"woo-todo-{Guid.NewGuid():N}.sqlite3");
        try
        {
            using var repository = new TaskRepository(database, () => 100);
            var series = Guid.Parse("00000000-0000-4000-8000-000000000099");
            var task = TodoTask.Create("每日任务", TaskTimeType.Day, new DateOnly(2026, 7, 23), QuestLine.Main, true, 0, 1, id: series);
            repository.Save(task);
            repository.SettleExpired(new DateOnly(2026, 7, 24));
            var generated = OccurrenceId.Create(series, TaskTimeType.Day, new DateOnly(2026, 7, 24));
            Assert.True(repository.Delete(generated));

            repository.SettleExpired(new DateOnly(2026, 7, 24));
            Assert.Null(repository.Find(generated));
        }
        finally
        {
            foreach (var suffix in new[] { "", "-shm", "-wal" })
            {
                var path = database + suffix;
                if (File.Exists(path)) File.Delete(path);
            }
        }
    }

    [Fact]
    public void DeletedTaskCannotBeSavedBackAfterRestart()
    {
        var database = Path.Combine(Path.GetTempPath(), $"woo-todo-{Guid.NewGuid():N}.sqlite3");
        var task = TodoTask.Create(
            "不可复活",
            TaskTimeType.Day,
            new DateOnly(2026, 7, 24),
            QuestLine.Main,
            repeats: false,
            sortOrder: 0,
            now: 1,
            id: Guid.Parse("00000000-0000-4000-8000-000000000077"));
        try
        {
            using (var repository = new TaskRepository(database, () => 2))
            {
                repository.Save(task);
                Assert.True(repository.Delete(task.Id));
                Assert.Throws<InvalidOperationException>(() => repository.Save(task));
                Assert.Null(repository.Find(task.Id));
            }
            using (var reopened = new TaskRepository(database, () => 3))
            {
                Assert.Throws<InvalidOperationException>(() => reopened.Save(task));
                Assert.Null(reopened.Find(task.Id));
            }
        }
        finally
        {
            DeleteDatabaseFiles(database);
        }
    }

    [Theory]
    [InlineData(TaskState.Completed)]
    [InlineData(TaskState.Pass)]
    public void SettledTaskIsImmutableAndCanBeSavedIdempotently(TaskState state)
    {
        var database = Path.Combine(Path.GetTempPath(), $"woo-todo-{Guid.NewGuid():N}.sqlite3");
        try
        {
            using var repository = new TaskRepository(database, () => 10);
            var id = repository.Create("只结算一次", TaskTimeType.Day, new DateOnly(2026, 7, 24), QuestLine.Main, repeats: false);
            var pending = repository.Find(id)!;
            Assert.True(state == TaskState.Completed ? repository.Complete(id) : repository.Pass(id));

            var settled = repository.Find(id)!;
            repository.Save(settled);
            Assert.Throws<InvalidOperationException>(() => repository.Save(pending));
            Assert.Throws<InvalidOperationException>(() => repository.Save(settled with { Title = "不能修改历史" }));
            Assert.Equal(state, repository.Find(id)!.State);
            Assert.Equal("只结算一次", repository.Find(id)!.Title);
        }
        finally
        {
            DeleteDatabaseFiles(database);
        }
    }

    [Fact]
    public void SaveManyRollsBackWhenAnyTaskIsRejected()
    {
        var database = Path.Combine(Path.GetTempPath(), $"woo-todo-{Guid.NewGuid():N}.sqlite3");
        var date = new DateOnly(2026, 7, 24);
        var deleted = TodoTask.Create("已删除", TaskTimeType.Day, date, QuestLine.Main, false, 0, 1);
        var newTask = TodoTask.Create("不应写入", TaskTimeType.Day, date, QuestLine.Side, false, 0, 2);
        try
        {
            using var repository = new TaskRepository(database, () => 3);
            repository.Save(deleted);
            Assert.True(repository.Delete(deleted.Id));

            Assert.Throws<InvalidOperationException>(() => repository.SaveMany(new[] { newTask, deleted }));
            Assert.Null(repository.Find(newTask.Id));
            Assert.Null(repository.Find(deleted.Id));
        }
        finally
        {
            DeleteDatabaseFiles(database);
        }
    }

    [Fact]
    public void TasksChanged_IsRaisedOnlyAfterSuccessfulMutations()
    {
        var database = Path.Combine(Path.GetTempPath(), $"woo-todo-{Guid.NewGuid():N}.sqlite3");
        try
        {
            using var repository = new TaskRepository(database, () => 10);
            var changes = 0;
            repository.TasksChanged += () => changes += 1;

            var id = repository.Create(
                "带提醒任务",
                TaskTimeType.Day,
                new DateOnly(2026, 7, 24),
                QuestLine.Main,
                repeats: false,
                reminderTime: new TimeOnly(9, 30));
            Assert.Equal(1, changes);

            Assert.False(repository.Update(
                Guid.NewGuid(),
                "不存在",
                TaskTimeType.Day,
                new DateOnly(2026, 7, 24),
                QuestLine.Main,
                repeats: false));
            Assert.Equal(1, changes);

            Assert.True(repository.Complete(id));
            Assert.Equal(2, changes);
            Assert.False(repository.Complete(id));
            Assert.Equal(2, changes);
        }
        finally
        {
            DeleteDatabaseFiles(database);
        }
    }

    private static void DeleteDatabaseFiles(string database)
    {
        foreach (var suffix in new[] { "", "-shm", "-wal" })
        {
            var path = database + suffix;
            if (File.Exists(path)) File.Delete(path);
        }
    }
}
