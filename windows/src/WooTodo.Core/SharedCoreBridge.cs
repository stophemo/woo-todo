using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WooTodo.Core;

public sealed record TaskNotificationPlan(
    string Id,
    Guid TaskId,
    DateOnly FireDate,
    TimeOnly FireTime,
    string Title,
    string Body,
    string DeepLink);

internal static partial class SharedCoreBridge
{
    private const string LibraryName = "woo_todo_core";
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    internal static string ValidateTitle(string title) =>
        CoreCall<string>(new { action = "validateTitle", title });

    internal static void ValidateTask(TodoTask task) =>
        _ = CoreCall<bool>(new { action = "validateTask", task = TaskDto.From(task) });

    internal static DateOnly Today() => ParseDate(
        CoreCall<string>(new { action = "today" }));

    internal static DateOnly? NormalizeStart(TaskTimeType type, DateOnly date)
    {
        var value = CoreCall<string?>(new
        {
            action = "normalizeStart",
            timeType = type.ToWire(),
            date = FormatDate(date),
        });
        return value is null ? null : ParseDate(value);
    }

    internal static DateOnly? NextStart(TaskTimeType type, DateOnly date)
    {
        var value = CoreCall<string?>(new
        {
            action = "nextStart",
            timeType = type.ToWire(),
            date = FormatDate(date),
        });
        return value is null ? null : ParseDate(value);
    }

    internal static Guid OccurrenceId(Guid seriesId, TaskTimeType type, DateOnly periodStart) =>
        Guid.Parse(CoreCall<string>(new
        {
            action = "occurrenceId",
            seriesId = seriesId.ToString("D"),
            timeType = type.ToWire(),
            periodStart = FormatDate(periodStart),
        }));

    internal static SettlementResult Settle(
        IEnumerable<TodoTask> tasks,
        DateOnly referenceDate,
        long now,
        IReadOnlySet<Guid>? reservedTaskIds)
    {
        var result = CoreCall<SettlementDto>(new
        {
            action = "settle",
            tasks = tasks.Select(TaskDto.From).ToArray(),
            referenceDate = FormatDate(referenceDate),
            now,
            reservedTaskIds = (reservedTaskIds ?? new HashSet<Guid>())
                .Select(value => value.ToString("D"))
                .ToArray(),
        });
        return result.ToModel();
    }

    internal static StatisticsSnapshot CalculateStatistics(
        IEnumerable<TodoTask> tasks,
        DateOnly referenceDate,
        int historyLimit)
    {
        var result = CoreCall<StatisticsDto>(new
        {
            action = "statistics",
            tasks = tasks.Select(TaskDto.From).ToArray(),
            referenceDate = FormatDate(referenceDate),
            historyLimit = Math.Max(0, historyLimit),
        });
        return result.ToModel();
    }

    internal static IReadOnlyList<TaskNotificationPlan> NotificationPlans(
        IEnumerable<TodoTask> tasks) =>
        CoreCall<NotificationPlanDto[]>(new
        {
            action = "notificationPlan",
            tasks = tasks.Select(TaskDto.From).ToArray(),
        }).Select(value => value.ToModel()).ToArray();

    internal static ulong OpenRepository(string databasePath) =>
        Invoke<ulong>(RepositoryOpenNative(databasePath));

    internal static T RepositoryCall<T>(ulong handle, object request)
    {
        var json = JsonSerializer.Serialize(request, JsonOptions);
        return Invoke<T>(RepositoryCallNative(handle, json));
    }

    internal static void CloseRepository(ulong handle) =>
        _ = Invoke<bool>(RepositoryCloseNative(handle));

    internal static TaskDto ToDto(TodoTask task) => TaskDto.From(task);
    internal static TodoTask ToModel(TaskDto task) => task.ToModel();
    internal static SettlementResult ToModel(SettlementDto result) => result.ToModel();

    private static T CoreCall<T>(object request)
    {
        var json = JsonSerializer.Serialize(request, JsonOptions);
        return Invoke<T>(CoreCallNative(json));
    }

    private static T Invoke<T>(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero)
        {
            throw new InvalidOperationException("共享 Rust 核心没有返回结果");
        }
        try
        {
            var json = Marshal.PtrToStringUTF8(pointer)
                ?? throw new InvalidOperationException("共享 Rust 核心返回了无效 UTF-8");
            var envelope = JsonSerializer.Deserialize<Envelope>(json, JsonOptions)
                ?? throw new InvalidOperationException("共享 Rust 核心响应为空");
            if (!envelope.Ok)
            {
                ThrowCoreError(envelope.Error);
            }
            if (envelope.Value.ValueKind == JsonValueKind.Null &&
                (!typeof(T).IsValueType || Nullable.GetUnderlyingType(typeof(T)) is not null))
            {
                return default!;
            }
            return envelope.Value.Deserialize<T>(JsonOptions)
                ?? throw new InvalidOperationException("共享 Rust 核心响应缺少 value");
        }
        finally
        {
            StringFreeNative(pointer);
        }
    }

    private static void ThrowCoreError(ErrorDto? error)
    {
        var code = error?.Code ?? "internal";
        var message = error?.Message ?? "共享 Rust 核心发生未知错误";
        if (code == "validation") throw new ArgumentException(message);
        throw new InvalidOperationException(message);
    }

    internal static string FormatDate(DateOnly value) => value.ToString("yyyy-MM-dd");
    internal static DateOnly ParseDate(string value) => DateOnly.ParseExact(value, "yyyy-MM-dd");

    [LibraryImport(LibraryName, EntryPoint = "woo_todo_core_call", StringMarshalling = StringMarshalling.Utf8)]
    private static partial IntPtr CoreCallNative(string requestJson);

    [LibraryImport(LibraryName, EntryPoint = "woo_todo_repository_open", StringMarshalling = StringMarshalling.Utf8)]
    private static partial IntPtr RepositoryOpenNative(string databasePath);

    [LibraryImport(LibraryName, EntryPoint = "woo_todo_repository_call", StringMarshalling = StringMarshalling.Utf8)]
    private static partial IntPtr RepositoryCallNative(ulong handle, string requestJson);

    [LibraryImport(LibraryName, EntryPoint = "woo_todo_repository_close")]
    private static partial IntPtr RepositoryCloseNative(ulong handle);

    [LibraryImport(LibraryName, EntryPoint = "woo_todo_string_free")]
    private static partial void StringFreeNative(IntPtr value);

    private sealed record Envelope(bool Ok, JsonElement Value, ErrorDto? Error);
    private sealed record ErrorDto(string Code, string Message);

    internal sealed record TaskDto(
        string Id,
        string SeriesId,
        string Title,
        string TimeType,
        string? PeriodStart,
        string Timezone,
        string QuestLine,
        string State,
        string Recurrence,
        int SortOrder,
        long CreatedAt,
        long UpdatedAt,
        long? SettledAt,
        string? ReminderTime)
    {
        internal static TaskDto From(TodoTask task) => new(
            task.Id.ToString("D"),
            task.SeriesId.ToString("D"),
            task.Title,
            task.TimeType.ToWire(),
            task.PeriodStart is { } start ? FormatDate(start) : null,
            TodoTask.Timezone,
            task.QuestLine.ToWire(),
            task.State.ToWire(),
            task.Recurrence.ToWire(),
            task.SortOrder,
            task.CreatedAt,
            task.UpdatedAt,
            task.SettledAt,
            task.ReminderTime?.ToString("HH:mm"));

        internal TodoTask ToModel() => new(
            Guid.Parse(Id),
            Guid.Parse(SeriesId),
            Title,
            TaskWireValues.ParseTimeType(TimeType),
            PeriodStart is null ? null : ParseDate(PeriodStart),
            TaskWireValues.ParseQuestLine(QuestLine),
            TaskWireValues.ParseState(State),
            TaskWireValues.ParseRecurrence(Recurrence),
            SortOrder,
            CreatedAt,
            UpdatedAt,
            SettledAt,
            ReminderTime is null ? null : TimeOnly.ParseExact(ReminderTime, "HH:mm"));
    }

    internal sealed record SettlementDto(
        TaskDto[] Tasks,
        string[] ChangedTaskIds,
        string[] GeneratedTaskIds)
    {
        internal SettlementResult ToModel() => new(
            Tasks.Select(value => value.ToModel()).ToArray(),
            ChangedTaskIds.Select(Guid.Parse).ToHashSet(),
            GeneratedTaskIds.Select(Guid.Parse).ToHashSet());
    }

    private sealed record StatusCountsDto(int Pending, int Completed, int Pass)
    {
        internal StatusCounts ToModel() => new(Pending, Completed, Pass);
    }

    private sealed record AdherenceDto(int Completed, int Pass)
    {
        internal AdherenceMetric ToModel() => new(Completed, Pass);
    }

    private sealed record TrendDto(
        string Start,
        string EndExclusive,
        int Completed,
        int Pass,
        bool IsEnded)
    {
        internal TrendBucket ToModel() => new(
            ParseDate(Start),
            ParseDate(EndExclusive),
            Completed,
            Pass,
            IsEnded);
    }

    private sealed record StatisticsDto(
        AdherenceDto EndedPeriods,
        AdherenceDto MainEndedPeriods,
        Dictionary<string, StatusCountsDto> ByTimeType,
        Dictionary<string, StatusCountsDto> ByQuestLine,
        TrendDto[] DailyTrend,
        TrendDto[] WeeklyTrend,
        TrendDto[] MonthlyTrend,
        TaskDto[] RecentHistory)
    {
        internal StatisticsSnapshot ToModel() => new(
            EndedPeriods.ToModel(),
            MainEndedPeriods.ToModel(),
            ByTimeType.ToDictionary(
                value => TaskWireValues.ParseTimeType(value.Key),
                value => value.Value.ToModel()),
            ByQuestLine.ToDictionary(
                value => TaskWireValues.ParseQuestLine(value.Key),
                value => value.Value.ToModel()),
            DailyTrend.Select(value => value.ToModel()).ToArray(),
            WeeklyTrend.Select(value => value.ToModel()).ToArray(),
            MonthlyTrend.Select(value => value.ToModel()).ToArray(),
            RecentHistory.Select(value => value.ToModel()).ToArray());
    }

    private sealed record NotificationPlanDto(
        string Id,
        string TaskId,
        string FireDate,
        string FireTime,
        string Title,
        string Body,
        string DeepLink)
    {
        internal TaskNotificationPlan ToModel() => new(
            Id,
            Guid.Parse(TaskId),
            ParseDate(FireDate),
            TimeOnly.ParseExact(FireTime, "HH:mm"),
            Title,
            Body,
            DeepLink);
    }
}
