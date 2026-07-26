using System.ComponentModel;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using WooTodo.Core;
using WooTodo.Storage;
using Brush = System.Windows.Media.Brush;
using CheckBox = System.Windows.Controls.CheckBox;
using ContextMenu = System.Windows.Controls.ContextMenu;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using MenuItem = System.Windows.Controls.MenuItem;

namespace WooTodo.WindowsApp;

public partial class FloatingWindow : Window
{
    private readonly TaskRepository repository;
    private readonly AppSettings settings;
    private HotKeyService? hotKeys;
    private HwndSource? windowSource;
    private IReadOnlyList<string> unavailableHotKeys = Array.Empty<string>();
    private bool exiting;

    public FloatingWindow(TaskRepository repository, AppSettings settings)
    {
        InitializeComponent();
        this.repository = repository;
        this.settings = settings;
        Left = settings.BoardLeft;
        Top = settings.BoardTop;
        Width = settings.BoardWidth;
        Height = settings.BoardHeight;
        Opacity = settings.ClickThrough ? 0.2 : settings.Opacity;
        Topmost = settings.Topmost;
        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) => Reload();
    }

    public event Action? OpenMainWindowRequested;
    public event Action? TasksChanged;
    public event Action<IReadOnlyList<string>>? HotKeyRegistrationFailed;

    public IReadOnlyList<string> UnavailableHotKeys => unavailableHotKeys;

    public void ShowBoard()
    {
        Show();
        KeepInsideWorkingArea();
        if (!settings.ClickThrough) Activate();
        Reload();
    }

    public void ShowQuickAdd()
    {
        RestoreInteraction();
        ShowBoard();
        QuickAddTextBox.Focus();
    }

    public void ToggleTopmost()
    {
        settings.Topmost = !settings.Topmost;
        Topmost = settings.Topmost;
        settings.Save();
    }

    public void ToggleClickThrough()
    {
        settings.ClickThrough = !settings.ClickThrough;
        ApplyClickThrough();
    }

    public void RestoreInteraction()
    {
        settings.ClickThrough = false;
        ApplyClickThrough();
        ShowBoard();
    }

    public void CloseForExit()
    {
        exiting = true;
        Close();
    }

    public void Reload()
    {
        var today = PeriodRules.Today();
        repository.SettleExpired(today);
        DateText.Text = today.ToString("yyyy年M月d日 dddd");
        TaskPanel.Children.Clear();
        var tasks = repository.FetchScope(TaskTimeType.Day, today, includePlanned: false);
        if (tasks.Count == 0)
        {
            TaskPanel.Children.Add(new TextBlock
            {
                Text = "今日暂无任务",
                Foreground = (Brush)FindResource("SecondaryTextBrush"),
                Margin = new Thickness(4, 22, 4, 22),
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            return;
        }

        foreach (var group in tasks.GroupBy(task => task.QuestLine))
        {
            TaskPanel.Children.Add(new TextBlock
            {
                Text = group.Key.Label(),
                FontWeight = FontWeights.SemiBold,
                Foreground = (Brush)FindResource("SecondaryTextBrush"),
                Margin = new Thickness(2, 10, 2, 5),
            });
            foreach (var task in group) TaskPanel.Children.Add(BuildTaskRow(task));
        }
    }

    private UIElement BuildTaskRow(TodoTask task)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 2), MinHeight = 40 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var check = new CheckBox
        {
            IsChecked = task.State == TaskState.Completed,
            IsEnabled = task.State == TaskState.Pending,
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = "标记完成",
            Tag = task.Id,
        };
        check.Click += CompleteClicked;
        var title = new TextBlock
        {
            Text = task.Title,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 8, 0),
            TextDecorations = task.State == TaskState.Completed ? TextDecorations.Strikethrough : null,
            Foreground = task.State == TaskState.Pending
                ? (Brush)FindResource("TextBrush")
                : (Brush)FindResource("SecondaryTextBrush"),
        };
        title.MouseLeftButtonDown += (_, args) => { if (args.ClickCount == 2 && task.State == TaskState.Pending) EditTask(task); };
        var menu = new ContextMenu();
        var edit = new MenuItem { Header = "编辑", IsEnabled = task.State == TaskState.Pending };
        edit.Click += (_, _) => EditTask(task);
        var pass = new MenuItem { Header = "Pass", IsEnabled = task.State == TaskState.Pending };
        pass.Click += (_, _) => { repository.Pass(task.Id); Changed(); };
        var delete = new MenuItem { Header = "删除", IsEnabled = task.State == TaskState.Pending };
        delete.Click += (_, _) => { repository.Delete(task.Id); Changed(); };
        menu.Items.Add(edit);
        menu.Items.Add(pass);
        menu.Items.Add(delete);
        row.ContextMenu = menu;
        Grid.SetColumn(title, 1);
        row.Children.Add(check);
        row.Children.Add(title);
        return row;
    }

    private void CompleteClicked(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox { Tag: Guid id })
        {
            repository.Complete(id);
            Changed();
        }
    }

    private void AddClicked(object sender, RoutedEventArgs e) => AddWithEditor();
    private void OpenMainClicked(object sender, RoutedEventArgs e) => OpenMainWindowRequested?.Invoke();
    private void QuickAddClicked(object sender, RoutedEventArgs e) => AddQuickTask();

    private void QuickAddKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { AddQuickTask(); e.Handled = true; }
        if (e.Key == Key.Escape) { QuickAddTextBox.Clear(); e.Handled = true; }
    }

    private void AddQuickTask()
    {
        try
        {
            repository.Create(QuickAddTextBox.Text, TaskTimeType.Day, PeriodRules.Today(), QuestLine.Main, repeats: false);
            QuickAddTextBox.Clear();
            Changed();
        }
        catch (ArgumentException)
        {
            QuickAddTextBox.Focus();
        }
    }

    private void AddWithEditor()
    {
        var editor = new TaskEditorWindow(TaskTimeType.Day, PeriodRules.Today()) { Owner = this };
        if (editor.ShowDialog() == true && editor.Result is { } input)
        {
            repository.Create(input.Title, input.TimeType, input.TargetDate, input.QuestLine, input.Repeats, input.ReminderTime);
            Changed();
        }
    }

    private void EditTask(TodoTask task)
    {
        var editor = new TaskEditorWindow(task.TimeType, task.PeriodStart ?? PeriodRules.Today(), task) { Owner = this };
        if (editor.ShowDialog() == true && editor.Result is { } input)
        {
            repository.Update(task.Id, input.Title, input.TimeType, input.TargetDate, input.QuestLine, input.Repeats, input.ReminderTime);
            Changed();
        }
    }

    private void Changed()
    {
        Reload();
        TasksChanged?.Invoke();
    }

    private void HeaderMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed) DragMove();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        windowSource = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
        windowSource?.AddHook(WindowMessageHook);
        hotKeys = new HotKeyService(this);
        var failures = new List<string>();
        RegisterHotKey(1, 0x31, "Ctrl+Alt+1", ShowQuickAdd, failures);
        RegisterHotKey(2, 0x32, "Ctrl+Alt+2", () => { if (IsVisible) Hide(); else ShowBoard(); }, failures);
        RegisterHotKey(3, 0x33, "Ctrl+Alt+3", ToggleTopmost, failures);
        RegisterHotKey(4, 0x34, "Ctrl+Alt+4", ToggleClickThrough, failures);
        unavailableHotKeys = failures;
        KeepInsideWorkingArea();
        SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
        ApplyClickThrough();
        if (failures.Count > 0) HotKeyRegistrationFailed?.Invoke(failures);
    }

    private void RegisterHotKey(int id, int key, string label, Action action, ICollection<string> failures)
    {
        if (hotKeys?.Register(id, key, action) != true) failures.Add(label);
    }

    private void DisplaySettingsChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(KeepInsideWorkingArea);

    private void KeepInsideWorkingArea()
    {
        if (!IsInitialized) return;
        var handle = new WindowInteropHelper(this).Handle;
        var screen = System.Windows.Forms.Screen.FromHandle(handle);
        var transform = HwndSource.FromHwnd(handle)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topLeft = transform.Transform(new System.Windows.Point(screen.WorkingArea.Left, screen.WorkingArea.Top));
        var bottomRight = transform.Transform(new System.Windows.Point(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
        var maximumWidth = Math.Max(MinWidth, bottomRight.X - topLeft.X);
        var maximumHeight = Math.Max(MinHeight, bottomRight.Y - topLeft.Y);
        Width = Math.Min(Math.Max(Width, MinWidth), maximumWidth);
        Height = Math.Min(Math.Max(Height, MinHeight), maximumHeight);
        Left = Math.Clamp(Left, topLeft.X, Math.Max(topLeft.X, bottomRight.X - Width));
        Top = Math.Clamp(Top, topLeft.Y, Math.Max(topLeft.Y, bottomRight.Y - Height));
    }

    private IntPtr WindowMessageHook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        const int nonClientHitTest = 0x0084;
        const int transparentHit = -1;
        if (message == nonClientHitTest && settings.ClickThrough)
        {
            handled = true;
            return new IntPtr(transparentHit);
        }
        return IntPtr.Zero;
    }

    private void ApplyClickThrough()
    {
        if (!IsInitialized) return;
        WindowStyleService.SetClickThrough(this, settings.ClickThrough);
        Opacity = settings.ClickThrough ? 0.2 : settings.Opacity;
        settings.Save();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        settings.BoardLeft = Left;
        settings.BoardTop = Top;
        settings.BoardWidth = Width;
        settings.BoardHeight = Height;
        settings.Save();
        if (!exiting)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        hotKeys?.Dispose();
        SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged;
        if (windowSource is not null) windowSource.RemoveHook(WindowMessageHook);
        base.OnClosing(e);
    }
}
