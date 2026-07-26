using WooTodo.Core;

namespace WooTodo.WindowsApp;

internal static class UiLabels
{
    public static string Label(this TaskTimeType value) => value switch
    {
        TaskTimeType.Day => "每日",
        TaskTimeType.Week => "每周",
        TaskTimeType.Month => "每月",
        TaskTimeType.Someday => "闲时",
        _ => value.ToString(),
    };

    public static string Label(this QuestLine value) => value switch
    {
        QuestLine.Main => "主线",
        QuestLine.Side => "支线",
        QuestLine.Extra => "外传",
        _ => value.ToString(),
    };

    public static string Label(this TaskState value) => value switch
    {
        TaskState.Pending => "待完成",
        TaskState.Completed => "已完成",
        TaskState.Pass => "Pass",
        _ => value.ToString(),
    };

    public static string PeriodLabel(this TodoTask task) => task.TimeType switch
    {
        TaskTimeType.Day => task.PeriodStart?.ToString("yyyy-MM-dd") ?? string.Empty,
        TaskTimeType.Week => task.PeriodStart is { } date ? $"{date:MM-dd} 起一周" : string.Empty,
        TaskTimeType.Month => task.PeriodStart?.ToString("yyyy-MM") ?? string.Empty,
        TaskTimeType.Someday => "无截止时间",
        _ => string.Empty,
    };
}
