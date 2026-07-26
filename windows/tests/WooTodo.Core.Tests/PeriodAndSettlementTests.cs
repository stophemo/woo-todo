using WooTodo.Core;

namespace WooTodo.Core.Tests;

public sealed class PeriodAndSettlementTests
{
    [Fact]
    public void NormalizeStart_MatchesCrossPeriodRules()
    {
        Assert.Equal(new DateOnly(2026, 7, 20), PeriodRules.NormalizeStart(TaskTimeType.Week, new DateOnly(2026, 7, 24)));
        Assert.Equal(new DateOnly(2026, 8, 1), PeriodRules.NormalizeStart(TaskTimeType.Month, new DateOnly(2026, 8, 31)));
        Assert.Null(PeriodRules.NormalizeStart(TaskTimeType.Someday, new DateOnly(2026, 7, 24)));
    }

    [Fact]
    public void OccurrenceId_MatchesSharedCrossClientAlgorithm()
    {
        var value = OccurrenceId.Create(
            Guid.Parse("00000000-0000-4000-8000-000000000001"),
            TaskTimeType.Day,
            new DateOnly(2026, 7, 16));
        Assert.Equal("62903272-1c56-5012-9f10-103da3868d05", value.ToString("D"));
    }

    [Fact]
    public void Settle_CatchesUpMissedPeriodsAndIsIdempotent()
    {
        var original = TodoTask.Create(
            "每日复盘",
            TaskTimeType.Day,
            new DateOnly(2026, 7, 20),
            QuestLine.Main,
            repeats: true,
            sortOrder: 0,
            now: 1,
            id: Guid.Parse("00000000-0000-4000-8000-000000000001"));

        var first = SettlementEngine.Settle(new[] { original }, new DateOnly(2026, 7, 24), now: 2);
        Assert.Equal(5, first.Tasks.Count);
        Assert.Equal(4, first.ChangedTaskIds.Count);
        Assert.Equal(4, first.GeneratedTaskIds.Count);
        Assert.Single(first.Tasks, task => task.PeriodStart == new DateOnly(2026, 7, 24) && task.State == TaskState.Pending);

        var second = SettlementEngine.Settle(first.Tasks, new DateOnly(2026, 7, 24), now: 3);
        Assert.Equal(first.Tasks, second.Tasks);
        Assert.Empty(second.ChangedTaskIds);
        Assert.Empty(second.GeneratedTaskIds);
    }

    [Fact]
    public void Settle_DoesNotRecreateReservedDeletedOccurrence()
    {
        var original = TodoTask.Create(
            "每周例会",
            TaskTimeType.Week,
            new DateOnly(2026, 7, 13),
            QuestLine.Side,
            repeats: true,
            sortOrder: 0,
            now: 1,
            id: Guid.Parse("2c99a18c-77d8-44e4-965b-0e08d93a8221"));
        var deleted = OccurrenceId.Create(original.SeriesId, TaskTimeType.Week, new DateOnly(2026, 7, 20));

        var result = SettlementEngine.Settle(
            new[] { original },
            new DateOnly(2026, 7, 27),
            now: 2,
            new HashSet<Guid> { deleted });

        Assert.Single(result.Tasks);
        Assert.DoesNotContain(result.Tasks, task => task.Id == deleted);
    }

    [Fact]
    public void NotificationPlan_IsStableAndOnlyContainsPendingScheduledTasks()
    {
        var taskId = Guid.Parse("48fdbbcb-96c5-45e7-af27-2f04bcd980fb");
        var pending = TodoTask.Create(
            "提交周报",
            TaskTimeType.Day,
            new DateOnly(2026, 7, 24),
            QuestLine.Main,
            repeats: false,
            sortOrder: 0,
            now: 1,
            reminderTime: new TimeOnly(9, 30),
            id: taskId);
        var settled = pending with
        {
            Id = Guid.Parse("42c19c52-c848-49fe-a67b-82fda5f9f8f1"),
            SeriesId = Guid.Parse("42c19c52-c848-49fe-a67b-82fda5f9f8f1"),
            State = TaskState.Completed,
            SettledAt = 2,
        };

        var first = TaskNotificationPolicy.BuildPlans(new[] { settled, pending });
        var plan = Assert.Single(first);

        Assert.Equal($"task-reminder:{taskId:D}:2026-07-24:09:30", plan.Id);
        Assert.Equal(taskId, plan.TaskId);
        Assert.Equal(new DateOnly(2026, 7, 24), plan.FireDate);
        Assert.Equal(new TimeOnly(9, 30), plan.FireTime);
        Assert.Equal("待办提醒", plan.Title);
        Assert.Equal("提交周报", plan.Body);
        Assert.Equal($"wootodo://task-reminder/{taskId:D}", plan.DeepLink);
        Assert.Equal(first, TaskNotificationPolicy.BuildPlans(new[] { pending, settled }));
    }
}
