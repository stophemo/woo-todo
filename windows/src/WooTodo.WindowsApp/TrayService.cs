using System.Drawing;
using System.Windows.Forms;

namespace WooTodo.WindowsApp;

public sealed class TrayService : IDisposable
{
    private readonly NotifyIcon icon;
    private readonly Icon? applicationIcon;

    public TrayService(
        Action showTasks,
        Action toggleBoard,
        Action quickAdd,
        Action toggleTopmost,
        Action restoreInteraction,
        Action exit)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("任务详情与统计...", null, (_, _) => showTasks());
        menu.Items.Add("显示/隐藏任务板", null, (_, _) => toggleBoard());
        menu.Items.Add("快速新增...", null, (_, _) => quickAdd());
        menu.Items.Add("切换置顶", null, (_, _) => toggleTopmost());
        menu.Items.Add("恢复可交互", null, (_, _) => restoreInteraction());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出 Woo Todo", null, (_, _) => exit());

        applicationIcon = Environment.ProcessPath is { } path ? Icon.ExtractAssociatedIcon(path) : null;
        icon = new NotifyIcon
        {
            Text = "无我待办",
            Icon = applicationIcon ?? SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.DoubleClick += (_, _) => showTasks();
    }

    public void ShowWarning(string title, string message)
    {
        icon.BalloonTipTitle = title;
        icon.BalloonTipText = message;
        icon.BalloonTipIcon = ToolTipIcon.Warning;
        icon.ShowBalloonTip(5000);
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.ContextMenuStrip?.Dispose();
        icon.Dispose();
        applicationIcon?.Dispose();
    }
}
