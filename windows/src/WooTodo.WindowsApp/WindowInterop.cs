using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace WooTodo.WindowsApp;

internal sealed class HotKeyService : IDisposable
{
    private const int HotKeyMessage = 0x0312;
    private const uint Control = 0x0002;
    private const uint Alt = 0x0001;
    private readonly HwndSource source;
    private readonly Dictionary<int, Action> handlers = new();

    public HotKeyService(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        source = HwndSource.FromHwnd(handle) ?? throw new InvalidOperationException("无法创建快捷键消息源");
        source.AddHook(WndProc);
    }

    public bool Register(int id, int key, Action action)
    {
        if (!NativeMethods.RegisterHotKey(source.Handle, id, Control | Alt, (uint)key))
        {
            return false;
        }
        handlers[id] = action;
        return true;
    }

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == HotKeyMessage && handlers.TryGetValue(wParam.ToInt32(), out var action))
        {
            action();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        foreach (var id in handlers.Keys) NativeMethods.UnregisterHotKey(source.Handle, id);
        source.RemoveHook(WndProc);
    }
}

internal static class WindowStyleService
{
    private const int ExtendedStyle = -20;
    private const long Transparent = 0x20;
    private const long ToolWindow = 0x80;
    private const long NoActivate = 0x08000000;

    public static void SetClickThrough(Window window, bool enabled)
    {
        var handle = new WindowInteropHelper(window).Handle;
        var style = NativeMethods.GetWindowLongPtr(handle, ExtendedStyle).ToInt64() | ToolWindow;
        style = enabled
            ? style | Transparent | NoActivate
            : style & ~(Transparent | NoActivate);
        NativeMethods.SetWindowLongPtr(handle, ExtendedStyle, new IntPtr(style));
    }
}

internal static partial class NativeMethods
{
    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterHotKey(IntPtr window, int id);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    internal static partial IntPtr GetWindowLongPtr(IntPtr window, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    internal static partial IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr newValue);
}
