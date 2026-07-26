namespace WooTodo.Core;

public static class PeriodRules
{
    public static DateOnly Today() => SharedCoreBridge.Today();

    public static DateOnly? NormalizeStart(TaskTimeType type, DateOnly date) =>
        SharedCoreBridge.NormalizeStart(type, date);

    public static DateOnly NextStart(TaskTimeType type, DateOnly start) =>
        SharedCoreBridge.NextStart(type, start)
            ?? throw new ArgumentException("闲时任务没有下一周期", nameof(type));

    public static bool IsExpired(TodoTask task, DateOnly referenceDate) =>
        task.PeriodStart is { } start && NextStart(task.TimeType, start) <= referenceDate;
}
public static class OccurrenceId
{
    public static Guid Create(Guid seriesId, TaskTimeType type, DateOnly periodStart) =>
        SharedCoreBridge.OccurrenceId(seriesId, type, periodStart);
}
