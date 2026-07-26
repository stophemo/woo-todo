using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using WooTodo.Core;
using WooTodo.Storage;
using Brush = System.Windows.Media.Brush;
using CheckBox = System.Windows.Controls.CheckBox;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Orientation = System.Windows.Controls.Orientation;

namespace WooTodo.WindowsApp;

public partial class MainWindow : Window
{
    private readonly TaskRepository repository;
    private readonly AppSettings settings;
    private readonly FloatingWindow floatingWindow;
    private string section = "Today";
    private bool exiting;
    private bool loadingSettings;

    public MainWindow(TaskRepository repository, AppSettings settings, FloatingWindow floatingWindow)
    {
        InitializeComponent();
        this.repository = repository;
        this.settings = settings;
        this.floatingWindow = floatingWindow;
        NavigationList.SelectedIndex = 0;
        Loaded += (_, _) => Reload();
    }

    public void Reload()
    {
        repository.SettleExpired(PeriodRules.Today());
        if (section == "Statistics") ShowStatistics();
        else if (section == "Settings") ShowSettings();
        else ShowTasks();
    }

    public void CloseForExit()
    {
        exiting = true;
        Close();
    }

    public void OpenTask(Guid taskId)
    {
        if (repository.Find(taskId) is { State: TaskState.Pending } task)
        {
            EditTask(task);
        }
    }

    private void NavigationChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NavigationList.SelectedItem is ListBoxItem { Tag: string value })
        {
            section = value;
            Reload();
        }
    }

    private void ShowTasks()
    {
        TaskScroll.Visibility = Visibility.Visible;
        StatisticsScroll.Visibility = Visibility.Collapsed;
        SettingsPanel.Visibility = Visibility.Collapsed;
        AddButton.Visibility = section == "History" ? Visibility.Collapsed : Visibility.Visible;
        TaskPanel.Children.Clear();
        var today = PeriodRules.Today();
        IReadOnlyList<TodoTask> tasks;
        switch (section)
        {
            case "Today":
                PageTitle.Text = "今日";
                PageSubtitle.Text = today.ToString("yyyy年M月d日 dddd");
                tasks = repository.FetchScope(TaskTimeType.Day, today, includePlanned: false);
                break;
            case "Tomorrow":
                PageTitle.Text = "明日";
                PageSubtitle.Text = today.AddDays(1).ToString("yyyy年M月d日 dddd");
                tasks = repository.FetchScope(TaskTimeType.Day, today.AddDays(1), includePlanned: false);
                break;
            case "Week":
                PageTitle.Text = "本周";
                PageSubtitle.Text = "本周与已规划的每周任务";
                tasks = repository.FetchScope(TaskTimeType.Week, today);
                break;
            case "Month":
                PageTitle.Text = "本月";
                PageSubtitle.Text = "本月与已规划的每月任务";
                tasks = repository.FetchScope(TaskTimeType.Month, today);
                break;
            case "Someday":
                PageTitle.Text = "闲时";
                PageSubtitle.Text = "没有截止时间的闲时任务";
                tasks = repository.FetchScope(TaskTimeType.Someday, today);
                break;
            default:
                PageTitle.Text = "历史";
                PageSubtitle.Text = "已完成与 Pass 的只读记录";
                tasks = repository.FetchAll().Where(task => task.State != TaskState.Pending)
                    .OrderByDescending(task => task.SettledAt).ToArray();
                break;
        }

        if (tasks.Count == 0)
        {
            TaskPanel.Children.Add(EmptyState(section == "History" ? "暂无历史记录" : "暂无任务"));
            return;
        }

        foreach (var group in tasks.GroupBy(task => section == "History" ? task.State.Label() : task.QuestLine.Label()))
        {
            TaskPanel.Children.Add(new TextBlock
            {
                Text = group.Key,
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                Foreground = (Brush)FindResource("SecondaryTextBrush"),
                Margin = new Thickness(4, 12, 4, 7),
            });
            foreach (var task in group) TaskPanel.Children.Add(BuildTaskRow(task));
        }
    }

    private UIElement BuildTaskRow(TodoTask task)
    {
        var border = new Border
        {
            Background = (Brush)FindResource("SurfaceBrush"),
            BorderBrush = (Brush)FindResource("DividerBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Margin = new Thickness(0, 0, 0, 8),
            Padding = new Thickness(12, 9, 10, 9),
        };
        var row = new Grid { MinHeight = 42 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var check = new CheckBox
        {
            IsChecked = task.State == TaskState.Completed,
            IsEnabled = task.State == TaskState.Pending,
            VerticalAlignment = VerticalAlignment.Center,
            Tag = task.Id,
            ToolTip = "标记完成",
        };
        check.Click += (_, _) => { repository.Complete(task.Id); Changed(); };
        var text = new StackPanel { Margin = new Thickness(10, 0, 12, 0) };
        text.Children.Add(new TextBlock
        {
            Text = task.Title,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 15,
            TextDecorations = task.State == TaskState.Completed ? TextDecorations.Strikethrough : null,
            Foreground = task.State == TaskState.Pending ? (Brush)FindResource("TextBrush") : (Brush)FindResource("SecondaryTextBrush"),
        });
        text.Children.Add(new TextBlock
        {
            Text = $"{task.PeriodLabel()} · {task.QuestLine.Label()} · {task.State.Label()}",
            Margin = new Thickness(0, 3, 0, 0),
            FontSize = 12,
            Foreground = (Brush)FindResource("SecondaryTextBrush"),
        });
        Grid.SetColumn(text, 1);
        row.Children.Add(check);
        row.Children.Add(text);
        if (task.State == TaskState.Pending)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            actions.Children.Add(ActionButton("↑", () => { repository.Move(task.Id, -1); Changed(); }));
            actions.Children.Add(ActionButton("↓", () => { repository.Move(task.Id, 1); Changed(); }));
            actions.Children.Add(ActionButton("编辑", () => EditTask(task)));
            actions.Children.Add(ActionButton("Pass", () => { repository.Pass(task.Id); Changed(); }));
            actions.Children.Add(ActionButton("删除", () => { repository.Delete(task.Id); Changed(); }));
            Grid.SetColumn(actions, 2);
            row.Children.Add(actions);
        }
        border.Child = row;
        return border;
    }

    private static System.Windows.Controls.Button ActionButton(string text, Action action)
    {
        var button = new System.Windows.Controls.Button { Content = text, Padding = new Thickness(9, 5, 9, 5), MinHeight = 30, Margin = new Thickness(4, 0, 0, 0) };
        button.Click += (_, _) => action();
        return button;
    }

    private void ShowStatistics()
    {
        TaskScroll.Visibility = Visibility.Collapsed;
        StatisticsScroll.Visibility = Visibility.Visible;
        SettingsPanel.Visibility = Visibility.Collapsed;
        AddButton.Visibility = Visibility.Collapsed;
        PageTitle.Text = "统计";
        PageSubtitle.Text = "履约率只统计已经结束的周期";
        StatisticsPanel.Children.Clear();
        var snapshot = StatisticsEngine.Calculate(repository.FetchAll(), PeriodRules.Today());
        var rates = new Grid();
        rates.ColumnDefinitions.Add(new ColumnDefinition());
        rates.ColumnDefinitions.Add(new ColumnDefinition());
        rates.Children.Add(RateCard("周期履约率", snapshot.EndedPeriods));
        var main = RateCard("主线履约率", snapshot.MainEndedPeriods);
        Grid.SetColumn(main, 1);
        rates.Children.Add(main);
        StatisticsPanel.Children.Add(rates);
        StatisticsPanel.Children.Add(CountTable("按时间范围", snapshot.ByTimeType.Select(pair => (pair.Key.Label(), pair.Value))));
        StatisticsPanel.Children.Add(CountTable("按任务级别", snapshot.ByQuestLine.Select(pair => (pair.Key.Label(), pair.Value))));
        StatisticsPanel.Children.Add(TrendTable("最近 7 天", snapshot.DailyTrend));
        StatisticsPanel.Children.Add(TrendTable("最近 8 周", snapshot.WeeklyTrend));
        StatisticsPanel.Children.Add(TrendTable("最近 6 个月", snapshot.MonthlyTrend));
    }

    private Border RateCard(string title, AdherenceMetric metric)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = title, Foreground = (Brush)FindResource("SecondaryTextBrush") });
        stack.Children.Add(new TextBlock { Text = metric.Rate is { } rate ? $"{rate:P0}" : "暂无数据", FontSize = 30, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 4) });
        stack.Children.Add(new TextBlock { Text = $"完成 {metric.Completed} · Pass {metric.Pass}", Foreground = (Brush)FindResource("SecondaryTextBrush") });
        return new Border { Child = stack, Background = (Brush)FindResource("SurfaceBrush"), CornerRadius = new CornerRadius(6), BorderBrush = (Brush)FindResource("DividerBrush"), BorderThickness = new Thickness(1), Padding = new Thickness(18), Margin = new Thickness(0, 0, 10, 12) };
    }

    private Border CountTable(string title, IEnumerable<(string Label, StatusCounts Counts)> source)
    {
        var stack = SectionTitle(title);
        foreach (var (label, counts) in source)
        {
            stack.Children.Add(new TextBlock { Text = $"{label,-8}  待完成 {counts.Pending}    完成 {counts.Completed}    Pass {counts.Pass}", Margin = new Thickness(0, 5, 0, 0) });
        }
        return SectionCard(stack);
    }

    private Border TrendTable(string title, IEnumerable<TrendBucket> source)
    {
        var stack = SectionTitle(title);
        foreach (var bucket in source)
        {
            var rate = bucket.Rate is { } value ? $"{value:P0}" : "--";
            stack.Children.Add(new TextBlock { Text = $"{bucket.Start:yyyy-MM-dd}    完成 {bucket.Completed}    Pass {bucket.Pass}    {rate}", Margin = new Thickness(0, 5, 0, 0) });
        }
        return SectionCard(stack);
    }

    private static StackPanel SectionTitle(string title)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 5) });
        return stack;
    }

    private Border SectionCard(UIElement child) => new()
    {
        Child = child,
        Background = (Brush)FindResource("SurfaceBrush"),
        BorderBrush = (Brush)FindResource("DividerBrush"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(6),
        Padding = new Thickness(18),
        Margin = new Thickness(0, 0, 0, 12),
    };

    private void ShowSettings()
    {
        TaskScroll.Visibility = Visibility.Collapsed;
        StatisticsScroll.Visibility = Visibility.Collapsed;
        SettingsPanel.Visibility = Visibility.Visible;
        AddButton.Visibility = Visibility.Collapsed;
        PageTitle.Text = "显示与快捷键";
        PageSubtitle.Text = "任务板外观与全局操作";
        loadingSettings = true;
        OpacitySlider.Value = settings.Opacity;
        OpacityValue.Text = $"{settings.Opacity:P0}";
        TopmostCheckBox.IsChecked = settings.Topmost;
        ClickThroughCheckBox.IsChecked = settings.ClickThrough;
        var unavailableHotKeys = floatingWindow.UnavailableHotKeys;
        HotKeyStatusText.Visibility = unavailableHotKeys.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        HotKeyStatusText.Text = unavailableHotKeys.Count == 0
            ? string.Empty
            : $"未能注册 {string.Join("、", unavailableHotKeys)}，快捷键可能已被其他应用占用。";
        loadingSettings = false;
    }

    private TextBlock EmptyState(string text) => new()
    {
        Text = text,
        FontSize = 16,
        Foreground = (Brush)FindResource("SecondaryTextBrush"),
        HorizontalAlignment = HorizontalAlignment.Center,
        Margin = new Thickness(0, 100, 0, 0),
    };

    private void AddClicked(object sender, RoutedEventArgs e)
    {
        var (type, date) = DefaultTarget();
        var editor = new TaskEditorWindow(type, date) { Owner = this };
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

    private (TaskTimeType, DateOnly) DefaultTarget() => section switch
    {
        "Tomorrow" => (TaskTimeType.Day, PeriodRules.Today().AddDays(1)),
        "Week" => (TaskTimeType.Week, PeriodRules.Today()),
        "Month" => (TaskTimeType.Month, PeriodRules.Today()),
        "Someday" => (TaskTimeType.Someday, PeriodRules.Today()),
        _ => (TaskTimeType.Day, PeriodRules.Today()),
    };

    private void Changed()
    {
        Reload();
        floatingWindow.Reload();
    }

    private void RefreshClicked(object sender, RoutedEventArgs e) => Reload();

    private void OpacityChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (OpacityValue is null) return;
        OpacityValue.Text = $"{e.NewValue:P0}";
        if (loadingSettings) return;
        settings.Opacity = e.NewValue;
        if (!settings.ClickThrough) floatingWindow.Opacity = e.NewValue;
        settings.Save();
    }

    private void TopmostChanged(object sender, RoutedEventArgs e)
    {
        if (loadingSettings || TopmostCheckBox.IsChecked == settings.Topmost) return;
        floatingWindow.ToggleTopmost();
    }

    private void ClickThroughChanged(object sender, RoutedEventArgs e)
    {
        if (loadingSettings || ClickThroughCheckBox.IsChecked == settings.ClickThrough) return;
        floatingWindow.ToggleClickThrough();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!exiting)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnClosing(e);
    }
}
