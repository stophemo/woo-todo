using System.Windows;
using System.Windows.Controls;
using WooTodo.Core;

namespace WooTodo.WindowsApp;

public partial class TaskEditorWindow : Window
{
    private readonly TimeOnly? taskReminderTime;

    public TaskEditorWindow(TaskTimeType defaultType, DateOnly defaultDate, TodoTask? task = null)
    {
        InitializeComponent();
        taskReminderTime = task?.ReminderTime;
        TimeTypeCombo.ItemsSource = Enum.GetValues<TaskTimeType>().Select(value => new Choice<TaskTimeType>(value, value.Label()));
        QuestLineCombo.ItemsSource = Enum.GetValues<QuestLine>().Select(value => new Choice<QuestLine>(value, value.Label()));
        TimeTypeCombo.SelectedValuePath = nameof(Choice<TaskTimeType>.Value);
        TimeTypeCombo.DisplayMemberPath = nameof(Choice<TaskTimeType>.Label);
        QuestLineCombo.SelectedValuePath = nameof(Choice<QuestLine>.Value);
        QuestLineCombo.DisplayMemberPath = nameof(Choice<QuestLine>.Label);

        var type = task?.TimeType ?? defaultType;
        TimeTypeCombo.SelectedValue = type;
        QuestLineCombo.SelectedValue = task?.QuestLine ?? QuestLine.Main;
        TitleTextBox.Text = task?.Title ?? string.Empty;
        TargetDatePicker.SelectedDate = (task?.PeriodStart ?? defaultDate).ToDateTime(TimeOnly.MinValue);
        RepeatsCheckBox.IsChecked = task?.Recurrence == Recurrence.Repeat;
        Title = task is null ? "新增任务" : "编辑任务";
        Loaded += (_, _) => TitleTextBox.Focus();
    }

    public TaskInput? Result { get; private set; }

    private void TimeTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TimeTypeCombo.SelectedValue is not TaskTimeType type) return;
        var someday = type == TaskTimeType.Someday;
        TargetDatePicker.IsEnabled = !someday;
        RepeatsCheckBox.IsEnabled = !someday;
        if (someday) RepeatsCheckBox.IsChecked = false;
    }

    private void SaveClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            var title = TodoTask.ValidateTitle(TitleTextBox.Text);
            if (TimeTypeCombo.SelectedValue is not TaskTimeType type ||
                QuestLineCombo.SelectedValue is not QuestLine line)
            {
                throw new ArgumentException("请选择时间范围和任务级别");
            }
            var target = TargetDatePicker.SelectedDate is { } selected
                ? DateOnly.FromDateTime(selected)
                : PeriodRules.Today();
            Result = new TaskInput(
                title,
                type,
                target,
                line,
                RepeatsCheckBox.IsChecked == true,
                type == TaskTimeType.Someday ? null : taskReminderTime);
            DialogResult = true;
        }
        catch (ArgumentException error)
        {
            ErrorText.Text = error.Message;
        }
    }

    private sealed record Choice<T>(T Value, string Label);

}

public sealed record TaskInput(
    string Title,
    TaskTimeType TimeType,
    DateOnly TargetDate,
    QuestLine QuestLine,
    bool Repeats,
    TimeOnly? ReminderTime);
