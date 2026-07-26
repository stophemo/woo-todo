namespace WooTodo.Core;

public sealed record StatusCounts(int Pending = 0, int Completed = 0, int Pass = 0)
{
    public int Total => Pending + Completed + Pass;
}

public sealed record AdherenceMetric(int Completed, int Pass)
{
    public int Total => Completed + Pass;
    public double? Rate => Total == 0 ? null : (double)Completed / Total;
}

public sealed record TrendBucket(DateOnly Start, DateOnly EndExclusive, int Completed, int Pass, bool IsEnded)
{
    public int SampleCount => Completed + Pass;
    public double? Rate => IsEnded && SampleCount > 0 ? (double)Completed / SampleCount : null;
}

public sealed record StatisticsSnapshot(
    AdherenceMetric EndedPeriods,
    AdherenceMetric MainEndedPeriods,
    IReadOnlyDictionary<TaskTimeType, StatusCounts> ByTimeType,
    IReadOnlyDictionary<QuestLine, StatusCounts> ByQuestLine,
    IReadOnlyList<TrendBucket> DailyTrend,
    IReadOnlyList<TrendBucket> WeeklyTrend,
    IReadOnlyList<TrendBucket> MonthlyTrend,
    IReadOnlyList<TodoTask> RecentHistory);

public static class StatisticsEngine
{
    public static StatisticsSnapshot Calculate(
        IEnumerable<TodoTask> source,
        DateOnly referenceDate,
        int historyLimit = 30) =>
        SharedCoreBridge.CalculateStatistics(source, referenceDate, historyLimit);
}

public static class TaskNotificationPolicy
{
    public static IReadOnlyList<TaskNotificationPlan> BuildPlans(IEnumerable<TodoTask> tasks) =>
        SharedCoreBridge.NotificationPlans(tasks);
}
