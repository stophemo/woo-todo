namespace WooTodo.Core;

public sealed record SettlementResult(
    IReadOnlyList<TodoTask> Tasks,
    IReadOnlySet<Guid> ChangedTaskIds,
    IReadOnlySet<Guid> GeneratedTaskIds);

public static class SettlementEngine
{
    public static SettlementResult Settle(
        IEnumerable<TodoTask> source,
        DateOnly referenceDate,
        long now,
        IReadOnlySet<Guid>? reservedTaskIds = null) =>
        SharedCoreBridge.Settle(source, referenceDate, now, reservedTaskIds);
}
public static class TaskOrdering
{
    public static IComparer<TodoTask> Comparer { get; } = Comparer<TodoTask>.Create((left, right) =>
    {
        var result = left.QuestLine.CompareTo(right.QuestLine);
        if (result != 0) return result;
        result = left.State.CompareTo(right.State);
        if (result != 0) return result;
        result = left.SortOrder.CompareTo(right.SortOrder);
        if (result != 0) return result;
        result = left.CreatedAt.CompareTo(right.CreatedAt);
        return result != 0 ? result : left.Id.CompareTo(right.Id);
    });
}
