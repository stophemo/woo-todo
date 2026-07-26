using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using WooTodo.Core;
using WooTodo.Storage;

namespace WooTodo.WindowsApp;

public partial class App : System.Windows.Application
{
    private Mutex? instanceMutex;
    private TrayService? tray;
    private TaskRepository? repository;
    private MainWindow? mainWindow;
    private FloatingWindow? floatingWindow;
    private WindowsNotificationScheduler? notificationScheduler;
    private Exception? notificationInitializationError;
    private SingleInstanceActivation? activation;
    private string[]? pendingActivation;
    private bool notificationRefreshPending;
    private bool notificationWarningShown;

    protected override void OnStartup(StartupEventArgs e)
    {
        instanceMutex = new Mutex(initiallyOwned: true, "Local\\WooTodo.WindowsApp", out var createdNew);
        if (!createdNew)
        {
            _ = SingleInstanceActivation.TryForward(e.Args);
            Shutdown();
            return;
        }

        base.OnStartup(e);
        activation = new SingleInstanceActivation();
        activation.Received += ActivationReceived;
        activation.Start();

        var dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Woo Todo");
        repository = new TaskRepository(Path.Combine(dataDirectory, "woo-todo.sqlite3"));
        repository.SettleExpired(PeriodRules.Today());
        repository.TasksChanged += QueueNotificationRefresh;
        var settings = AppSettings.Load(dataDirectory);

        try
        {
            WindowsAppIdentity.RegisterCurrentProcess();
            notificationScheduler = new WindowsNotificationScheduler();
        }
        catch (Exception error)
        {
            notificationScheduler = null;
            notificationInitializationError = error;
        }

        floatingWindow = new FloatingWindow(repository, settings);
        mainWindow = new MainWindow(repository, settings, floatingWindow);
        floatingWindow.OpenMainWindowRequested += ShowMainWindow;
        floatingWindow.TasksChanged += mainWindow.Reload;

        tray = new TrayService(
            showTasks: ShowMainWindow,
            toggleBoard: ToggleBoard,
            quickAdd: () => floatingWindow.ShowQuickAdd(),
            toggleTopmost: floatingWindow.ToggleTopmost,
            restoreInteraction: floatingWindow.RestoreInteraction,
            exit: ExitApplication);
        floatingWindow.HotKeyRegistrationFailed += shortcuts => tray.ShowWarning(
            "全局快捷键不可用",
            $"{string.Join("、", shortcuts)} 无法注册，可在“显示与快捷键”中查看。");
        floatingWindow.Show();
        RefreshNotifications();

        if (e.Args.Length > 0) HandleActivation(e.Args);
        if (pendingActivation is { } arguments)
        {
            pendingActivation = null;
            HandleActivation(arguments);
        }
    }

    private void ShowMainWindow()
    {
        mainWindow!.Reload();
        mainWindow.Show();
        mainWindow.WindowState = WindowState.Normal;
        mainWindow.Activate();
    }

    private void ToggleBoard()
    {
        if (floatingWindow!.IsVisible) floatingWindow.Hide();
        else floatingWindow.ShowBoard();
    }

    private void QueueNotificationRefresh()
    {
        if (notificationRefreshPending) return;
        notificationRefreshPending = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            notificationRefreshPending = false;
            RefreshNotifications();
        });
    }

    private void RefreshNotifications()
    {
        if (repository is null) return;
        if (notificationScheduler is null)
        {
            if (notificationInitializationError is { } error) ShowNotificationWarning(error);
            return;
        }
        try
        {
            notificationScheduler.Reconcile(repository.FetchAll());
        }
        catch (Exception error)
        {
            ShowNotificationWarning(error);
        }
    }

    private void ShowNotificationWarning(Exception error)
    {
        if (notificationWarningShown || tray is null) return;
        notificationWarningShown = true;
        tray.ShowWarning("任务提醒未能更新", $"请确认 Windows 通知权限与开始菜单快捷方式可用。{error.Message}");
    }

    private void ActivationReceived(string[] arguments)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (mainWindow is null)
            {
                pendingActivation = arguments;
                return;
            }
            HandleActivation(arguments);
        });
    }

    private void HandleActivation(IReadOnlyList<string> arguments)
    {
        ShowMainWindow();
        var uri = ActivationUri(arguments);
        if (uri is null ||
            !uri.Host.Equals("task-reminder", StringComparison.OrdinalIgnoreCase) ||
            uri.UserInfo.Length > 0 ||
            uri.Query.Length > 0 ||
            uri.Fragment.Length > 0 ||
            !Guid.TryParse(uri.AbsolutePath.Trim('/'), out var taskId))
        {
            return;
        }
        mainWindow!.OpenTask(taskId);
    }

    private static Uri? ActivationUri(IReadOnlyList<string> arguments)
    {
        for (var index = 0; index < arguments.Count; index += 1)
        {
            var value = arguments[index];
            if (value.Equals("--uri", StringComparison.OrdinalIgnoreCase) && index + 1 < arguments.Count)
            {
                value = arguments[index + 1];
            }
            if (Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
                uri.Scheme.Equals("wootodo", StringComparison.OrdinalIgnoreCase))
            {
                return uri;
            }
        }
        return null;
    }

    private void ExitApplication()
    {
        floatingWindow?.CloseForExit();
        mainWindow?.CloseForExit();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (repository is not null) repository.TasksChanged -= QueueNotificationRefresh;
        if (activation is not null) activation.Received -= ActivationReceived;
        activation?.Dispose();
        tray?.Dispose();
        repository?.Dispose();
        instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
