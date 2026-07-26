using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;
using WooTodo.Core;

namespace WooTodo.WindowsApp;

internal static partial class WindowsAppIdentity
{
    internal const string AppUserModelId = "stophemo.WooTodo";

    internal static void RegisterCurrentProcess()
    {
        if (!OperatingSystem.IsWindows()) return;
        Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelId(AppUserModelId));
    }

    [LibraryImport(
        "shell32.dll",
        EntryPoint = "SetCurrentProcessExplicitAppUserModelID",
        StringMarshalling = StringMarshalling.Utf16)]
    private static partial int SetCurrentProcessExplicitAppUserModelId(string appId);
}

/// <summary>
/// Rust 负责生成稳定提醒计划；此类型只把未来计划与 Windows 系统调度队列对齐。
/// 计划写入系统后，即使 Woo Todo 退出也能按时提醒。
/// </summary>
internal sealed class WindowsNotificationScheduler
{
    private const string ScheduleIdPrefix = "woo-";
    private const int MaximumScheduledNotifications = 4_096;
    private readonly TimeZoneInfo taskTimeZone;

    internal WindowsNotificationScheduler()
    {
        taskTimeZone = ResolveTaskTimeZone();
    }

    internal void Reconcile(IEnumerable<TodoTask> tasks, DateTimeOffset? referenceTime = null)
    {
        var now = referenceTime ?? DateTimeOffset.Now;
        var desired = TaskNotificationPolicy.BuildPlans(tasks)
            .Select(plan => BuildScheduledPlan(plan, now))
            .OfType<ScheduledPlan>()
            .OrderBy(plan => plan.DeliveryTime)
            .Take(MaximumScheduledNotifications)
            .ToDictionary(plan => plan.Id, StringComparer.Ordinal);

        var notifier = ToastNotificationManager.CreateToastNotifier(WindowsAppIdentity.AppUserModelId);
        var existing = notifier.GetScheduledToastNotifications()
            .Where(notification => notification.Id.StartsWith(ScheduleIdPrefix, StringComparison.Ordinal))
            .ToArray();

        foreach (var notification in existing)
        {
            if (desired.TryGetValue(notification.Id, out var plan) &&
                Math.Abs((notification.DeliveryTime - plan.DeliveryTime).TotalSeconds) < 1)
            {
                desired.Remove(notification.Id);
                continue;
            }
            notifier.RemoveFromSchedule(notification);
        }

        foreach (var plan in desired.Values)
        {
            var notification = new ScheduledToastNotification(BuildContent(plan.Plan), plan.DeliveryTime)
            {
                Id = plan.Id,
            };
            notifier.AddToSchedule(notification);
        }
    }

    private ScheduledPlan? BuildScheduledPlan(TaskNotificationPlan plan, DateTimeOffset now)
    {
        var localDateTime = plan.FireDate.ToDateTime(plan.FireTime, DateTimeKind.Unspecified);
        if (taskTimeZone.IsInvalidTime(localDateTime)) return null;

        var deliveryTime = new DateTimeOffset(localDateTime, taskTimeZone.GetUtcOffset(localDateTime));
        if (deliveryTime <= now.AddSeconds(2)) return null;

        return new ScheduledPlan(
            ScheduleId(plan),
            deliveryTime,
            plan);
    }

    private static XmlDocument BuildContent(TaskNotificationPlan plan)
    {
        if (!Uri.TryCreate(plan.DeepLink, UriKind.Absolute, out var deepLink) ||
            !deepLink.Scheme.Equals("wootodo", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("共享核心生成了无效的提醒跳转地址");
        }

        var source = new XDocument(
            new XElement(
                "toast",
                new XAttribute("activationType", "protocol"),
                new XAttribute("launch", deepLink.AbsoluteUri),
                new XElement(
                    "visual",
                    new XElement(
                        "binding",
                        new XAttribute("template", "ToastGeneric"),
                        new XElement("text", plan.Title),
                        new XElement("text", plan.Body)))));
        var document = new XmlDocument();
        document.LoadXml(source.ToString(SaveOptions.DisableFormatting));
        return document;
    }

    private static string ScheduleId(TaskNotificationPlan plan)
    {
        var fingerprint = string.Join(
            '\n',
            plan.Id,
            plan.Title,
            plan.Body,
            plan.DeepLink);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(fingerprint));
        return ScheduleIdPrefix + Convert.ToHexString(hash.AsSpan(0, 6)).ToLowerInvariant();
    }

    private static TimeZoneInfo ResolveTaskTimeZone()
    {
        foreach (var identifier in new[] { "China Standard Time", TodoTask.Timezone })
        {
            try
            {
                return TimeZoneInfo.FindSystemTimeZoneById(identifier);
            }
            catch (TimeZoneNotFoundException)
            {
                // Windows 与 Unix 使用不同的 IANA/系统时区标识，继续尝试另一个。
            }
            catch (InvalidTimeZoneException)
            {
                // 系统时区数据损坏时继续尝试兼容标识，最终回退到固定 UTC+8。
            }
        }
        return TimeZoneInfo.CreateCustomTimeZone("WooTodo-UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");
    }

    private sealed record ScheduledPlan(
        string Id,
        DateTimeOffset DeliveryTime,
        TaskNotificationPlan Plan);
}
