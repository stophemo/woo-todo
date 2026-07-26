using WooTodo.Core;

namespace WooTodo.Storage;

public sealed class TaskRepository : IDisposable
{
    private readonly Func<long> clock;
    private ulong handle;

    public event Action? TasksChanged;

    public TaskRepository(string databasePath, Func<long>? clock = null)
    {
        this.clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        handle = SharedCoreBridge.OpenRepository(databasePath);
    }

    public IReadOnlyList<TodoTask> FetchAll() =>
        Call<SharedCoreBridge.TaskDto[]>(new { action = "fetchAll" })
            .Select(SharedCoreBridge.ToModel)
            .ToArray();

    public TodoTask? Find(Guid id)
    {
        var value = Call<SharedCoreBridge.TaskDto?>(new
        {
            action = "find",
            id = id.ToString("D"),
        });
        return value is null ? null : SharedCoreBridge.ToModel(value);
    }

    public IReadOnlySet<Guid> DeletedTaskIds() =>
        Call<string[]>(new { action = "deletedTaskIds" })
            .Select(Guid.Parse)
            .ToHashSet();

    public IReadOnlyList<TodoTask> FetchScope(
        TaskTimeType type,
        DateOnly referenceDate,
        bool includePlanned = true) =>
        Call<SharedCoreBridge.TaskDto[]>(new
        {
            action = "fetchScope",
            timeType = type.ToWire(),
            referenceDate = SharedCoreBridge.FormatDate(referenceDate),
            includePlanned,
        }).Select(SharedCoreBridge.ToModel).ToArray();

    public Guid Create(
        string title,
        TaskTimeType type,
        DateOnly targetDate,
        QuestLine line,
        bool repeats,
        TimeOnly? reminderTime = null)
    {
        var id = Guid.Parse(Call<string>(new
        {
            action = "create",
            title,
            timeType = type.ToWire(),
            targetDate = SharedCoreBridge.FormatDate(targetDate),
            questLine = line.ToWire(),
            repeats,
            reminderTime = reminderTime?.ToString("HH:mm"),
            now = clock(),
        }));
        TasksChanged?.Invoke();
        return id;
    }

    public bool Update(
        Guid id,
        string title,
        TaskTimeType type,
        DateOnly targetDate,
        QuestLine line,
        bool repeats,
        TimeOnly? reminderTime = null) =>
        NotifyIfChanged(Call<bool>(new
        {
            action = "update",
            id = id.ToString("D"),
            title,
            timeType = type.ToWire(),
            targetDate = SharedCoreBridge.FormatDate(targetDate),
            questLine = line.ToWire(),
            repeats,
            reminderTime = reminderTime?.ToString("HH:mm"),
            now = clock(),
        }));

    public bool Complete(Guid id) => Settle(id, "complete");
    public bool Pass(Guid id) => Settle(id, "pass");

    public bool Move(Guid id, int offset) =>
        NotifyIfChanged(Call<bool>(new
        {
            action = "move",
            id = id.ToString("D"),
            offset,
            now = clock(),
        }));

    public bool Delete(Guid id) =>
        NotifyIfChanged(Call<bool>(new
        {
            action = "delete",
            id = id.ToString("D"),
            now = clock(),
        }));

    public SettlementResult SettleExpired(DateOnly referenceDate)
    {
        var result = SharedCoreBridge.ToModel(Call<SharedCoreBridge.SettlementDto>(new
        {
            action = "settleExpired",
            referenceDate = SharedCoreBridge.FormatDate(referenceDate),
            now = clock(),
        }));
        if (result.ChangedTaskIds.Count > 0 || result.GeneratedTaskIds.Count > 0)
        {
            TasksChanged?.Invoke();
        }
        return result;
    }

    public void Save(TodoTask task)
    {
        _ = Call<bool>(new { action = "save", task = SharedCoreBridge.ToDto(task) });
        TasksChanged?.Invoke();
    }

    public void SaveMany(IEnumerable<TodoTask> source)
    {
        _ = Call<bool>(new
        {
            action = "saveMany",
            tasks = source.Select(SharedCoreBridge.ToDto).ToArray(),
        });
        TasksChanged?.Invoke();
    }

    public void Dispose()
    {
        if (handle == 0) return;
        var current = handle;
        handle = 0;
        SharedCoreBridge.CloseRepository(current);
    }

    private bool Settle(Guid id, string action) =>
        NotifyIfChanged(Call<bool>(new
        {
            action,
            id = id.ToString("D"),
            now = clock(),
        }));

    private bool NotifyIfChanged(bool changed)
    {
        if (changed) TasksChanged?.Invoke();
        return changed;
    }

    private T Call<T>(object request)
    {
        ObjectDisposedException.ThrowIf(handle == 0, this);
        return SharedCoreBridge.RepositoryCall<T>(handle, request);
    }
}
