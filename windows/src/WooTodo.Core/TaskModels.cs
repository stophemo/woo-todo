namespace WooTodo.Core;

public enum TaskTimeType
{
    Day,
    Week,
    Month,
    Someday,
}

public enum QuestLine
{
    Main,
    Side,
    Extra,
}

public enum TaskState
{
    Pending,
    Completed,
    Pass,
}

public enum Recurrence
{
    Once,
    Repeat,
}

public sealed record TodoTask(
    Guid Id,
    Guid SeriesId,
    string Title,
    TaskTimeType TimeType,
    DateOnly? PeriodStart,
    QuestLine QuestLine,
    TaskState State,
    Recurrence Recurrence,
    int SortOrder,
    long CreatedAt,
    long UpdatedAt,
    long? SettledAt,
    TimeOnly? ReminderTime = null)
{
    public const string Timezone = "Asia/Shanghai";
    public const int MaximumTitleCodePoints = 120;

    public static TodoTask Create(
        string title,
        TaskTimeType timeType,
        DateOnly referenceDate,
        QuestLine questLine,
        bool repeats,
        int sortOrder,
        long now,
        TimeOnly? reminderTime = null,
        Guid? id = null)
    {
        var normalized = ValidateTitle(title);
        var taskId = id ?? Guid.NewGuid();
        return new TodoTask(
            taskId,
            taskId,
            normalized,
            timeType,
            PeriodRules.NormalizeStart(timeType, referenceDate),
            questLine,
            TaskState.Pending,
            repeats && timeType != TaskTimeType.Someday ? Recurrence.Repeat : Recurrence.Once,
            Math.Max(0, sortOrder),
            now,
            now,
            null,
            timeType == TaskTimeType.Someday ? null : reminderTime);
    }

    public TodoTask Validate()
    {
        SharedCoreBridge.ValidateTask(this);
        return this;
    }

    public static string ValidateTitle(string title) => SharedCoreBridge.ValidateTitle(title);
}

public static class TaskWireValues
{
    public static string ToWire(this TaskTimeType value) => value switch
    {
        TaskTimeType.Day => "day",
        TaskTimeType.Week => "week",
        TaskTimeType.Month => "month",
        TaskTimeType.Someday => "someday",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static string ToWire(this QuestLine value) => value.ToString().ToLowerInvariant();
    public static string ToWire(this TaskState value) => value.ToString().ToLowerInvariant();
    public static string ToWire(this Recurrence value) => value == Recurrence.Once ? "once" : "repeat";

    public static TaskTimeType ParseTimeType(string value) => value switch
    {
        "day" => TaskTimeType.Day,
        "week" => TaskTimeType.Week,
        "month" => TaskTimeType.Month,
        "someday" => TaskTimeType.Someday,
        _ => throw new FormatException("未知时间类型"),
    };

    public static QuestLine ParseQuestLine(string value) => value switch
    {
        "main" => QuestLine.Main,
        "side" => QuestLine.Side,
        "extra" => QuestLine.Extra,
        _ => throw new FormatException("未知任务级别"),
    };

    public static TaskState ParseState(string value) => value switch
    {
        "pending" => TaskState.Pending,
        "completed" => TaskState.Completed,
        "pass" => TaskState.Pass,
        _ => throw new FormatException("未知任务状态"),
    };

    public static Recurrence ParseRecurrence(string value) => value switch
    {
        "once" => Recurrence.Once,
        "repeat" => Recurrence.Repeat,
        _ => throw new FormatException("未知重复规则"),
    };
}
