[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ArchivePath,

    [Parameter()]
    [switch] $TestIntegration,

    [Parameter()]
    [string] $ArtifactDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$windowsDirectory = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $windowsDirectory "Cargo.toml"
$resolvedArchive = (Resolve-Path -LiteralPath $ArchivePath).Path
if ([string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
    $ArtifactDirectory = Join-Path $windowsDirectory "dist/smoke"
} elseif (-not [System.IO.Path]::IsPathRooted($ArtifactDirectory)) {
    $ArtifactDirectory = Join-Path (Get-Location) $ArtifactDirectory
}
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$diagnosticPath = Join-Path $ArtifactDirectory "diagnostics.txt"
Set-Content -LiteralPath $diagnosticPath -Value "Woo Todo Windows ZIP 烟测" -Encoding utf8

function Add-Diagnostic {
    param([Parameter(Mandatory = $true)][string] $Message)

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $Message"
    Write-Host $line
    Add-Content -LiteralPath $diagnosticPath -Value $line -Encoding utf8
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][scriptblock] $Condition,
        [int] $TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "等待超时：$Description"
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class WooTodoSmokeNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SystemTime
    {
        public ushort Year;
        public ushort Month;
        public ushort DayOfWeek;
        public ushort Day;
        public ushort Hour;
        public ushort Minute;
        public ushort Second;
        public ushort Milliseconds;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    private delegate bool EnumChildWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(
        IntPtr parent,
        EnumChildWindowsProc callback,
        IntPtr parameter
    );

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetClassNameW(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetDlgItem(IntPtr parent, int id);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowTextW(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowTextW(IntPtr window, string text);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    private static extern IntPtr SendMessageBuffer(
        IntPtr window,
        uint message,
        IntPtr wparam,
        StringBuilder lparam
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    private static extern IntPtr SendMessageSystemTime(
        IntPtr window,
        uint message,
        IntPtr wparam,
        ref SystemTime lparam
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessageW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowEnabled(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetDlgCtrlID(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetParent(IntPtr window);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetLayeredWindowAttributes(
        IntPtr window,
        out uint colorKey,
        out byte alpha,
        out uint flags
    );

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenClipboard(IntPtr owner);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint format);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredReadW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(
        string target,
        uint type,
        uint flags,
        out IntPtr credential
    );

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredWriteW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredDeleteW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    public static IntPtr FindTopLevelWindow(uint processId, int childId)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId == processId && GetDlgItem(window, childId) != IntPtr.Zero)
            {
                result = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static IntPtr FindTopLevelWindowByTitle(uint processId, string expectedTitle)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId != processId)
            {
                return true;
            }
            if (GetText(window) == expectedTitle)
            {
                result = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static string DescribeTopLevelWindows(uint processId)
    {
        var descriptions = new List<string>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId != processId)
            {
                return true;
            }
            var className = new StringBuilder(256);
            var title = new StringBuilder(512);
            GetClassNameW(window, className, className.Capacity);
            GetWindowTextW(window, title, title.Capacity);
            descriptions.Add(string.Format(
                "handle={0}, class={1}, title={2}, visible={3}",
                window,
                className,
                title,
                IsWindowVisible(window)
            ));
            return true;
        }, IntPtr.Zero);
        return descriptions.Count == 0 ? "<none>" : string.Join(" | ", descriptions);
    }

    public static void TypeText(IntPtr window, string text)
    {
        foreach (char character in text)
        {
            SendMessageW(window, 0x0102, new IntPtr((int)character), new IntPtr(1));
        }
    }

    public static string GetText(IntPtr window)
    {
        var text = new StringBuilder(32768);
        GetWindowTextW(window, text, text.Capacity);
        return text.ToString();
    }

    public static string GetListBoxItemText(IntPtr list, int index)
    {
        int length = SendMessageW(list, 0x018A, new IntPtr(index), IntPtr.Zero).ToInt32();
        if (length < 0)
        {
            throw new InvalidOperationException("无法读取导航项长度");
        }
        var text = new StringBuilder(length + 1);
        if (SendMessageBuffer(list, 0x0189, new IntPtr(index), text).ToInt32() < 0)
        {
            throw new InvalidOperationException("无法读取导航项文本");
        }
        return text.ToString();
    }

    public static string GetComboBoxItemText(IntPtr combo, int index)
    {
        int length = SendMessageW(combo, 0x0149, new IntPtr(index), IntPtr.Zero).ToInt32();
        if (length < 0)
        {
            throw new InvalidOperationException("无法读取同步方式长度");
        }
        var text = new StringBuilder(length + 1);
        if (SendMessageBuffer(combo, 0x0148, new IntPtr(index), text).ToInt32() < 0)
        {
            throw new InvalidOperationException("无法读取同步方式文本");
        }
        return text.ToString();
    }

    public static string[] VisibleChildTexts(IntPtr parent)
    {
        var texts = new List<string>();
        EnumChildWindows(parent, delegate(IntPtr window, IntPtr parameter)
        {
            if (IsWindowVisible(window))
            {
                string value = GetText(window);
                if (!string.IsNullOrWhiteSpace(value))
                {
                    texts.Add(value);
                }
            }
            return true;
        }, IntPtr.Zero);
        return texts.ToArray();
    }

    public static bool SetDatePicker(IntPtr picker, int year, int month, int day)
    {
        var value = new SystemTime
        {
            Year = checked((ushort)year),
            Month = checked((ushort)month),
            Day = checked((ushort)day)
        };
        return SendMessageSystemTime(picker, 0x1002, IntPtr.Zero, ref value) != IntPtr.Zero;
    }

    public static bool SetFileDialogPath(IntPtr dialog, string path)
    {
        IntPtr edit = GetDlgItem(dialog, 0x0480);
        if (edit == IntPtr.Zero)
        {
            IntPtr preferred = IntPtr.Zero;
            IntPtr fallback = IntPtr.Zero;
            EnumChildWindows(dialog, delegate(IntPtr window, IntPtr parameter)
            {
                var className = new StringBuilder(64);
                GetClassNameW(window, className, className.Capacity);
                if (className.ToString() != "Edit" || !IsWindowVisible(window) || !IsWindowEnabled(window))
                {
                    return true;
                }
                if (fallback == IntPtr.Zero)
                {
                    fallback = window;
                }
                int id = GetDlgCtrlID(window);
                IntPtr parent = GetParent(window);
                int parentId = parent == IntPtr.Zero ? 0 : GetDlgCtrlID(parent);
                if (id == 0x0480 || id == 1001 || parentId == 0x047C)
                {
                    preferred = window;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            edit = preferred != IntPtr.Zero ? preferred : fallback;
        }
        return edit != IntPtr.Zero && SetWindowTextW(edit, path);
    }

    public static string ReadClipboardUnicodeText()
    {
        if (!OpenClipboard(IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "无法打开剪贴板");
        }
        try
        {
            IntPtr handle = GetClipboardData(13);
            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "剪贴板没有 Unicode 文本");
            }
            IntPtr text = GlobalLock(handle);
            if (text == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取剪贴板文本");
            }
            try
            {
                return Marshal.PtrToStringUni(text) ?? string.Empty;
            }
            finally
            {
                GlobalUnlock(handle);
            }
        }
        finally
        {
            CloseClipboard();
        }
    }

    public static string ReadGenericCredential(string target)
    {
        IntPtr raw;
        if (!CredRead(target, 1, 0, out raw))
        {
            int error = Marshal.GetLastWin32Error();
            if (error == 1168)
            {
                return null;
            }
            throw new Win32Exception(error, "无法读取 Windows Credential Manager");
        }
        try
        {
            var credential = (Credential)Marshal.PtrToStructure(raw, typeof(Credential));
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                throw new InvalidOperationException("Windows Credential Manager 返回空凭据");
            }
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CredFree(raw);
        }
    }

    public static void WriteGenericCredential(string target, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length == 0 || bytes.Length > 2560)
        {
            throw new ArgumentException("Windows Credential Manager 烟测凭据长度无效", "value");
        }
        IntPtr targetPointer = Marshal.StringToHGlobalUni(target);
        IntPtr usernamePointer = Marshal.StringToHGlobalUni("Woo Todo 烟测同步身份");
        IntPtr blobPointer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blobPointer, bytes.Length);
            var credential = new Credential
            {
                Type = 1,
                TargetName = targetPointer,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blobPointer,
                Persist = 2,
                UserName = usernamePointer
            };
            if (!CredWrite(ref credential, 0))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "无法写入 Windows Credential Manager 烟测凭据"
                );
            }
        }
        finally
        {
            for (int index = 0; index < bytes.Length; index++)
            {
                Marshal.WriteByte(blobPointer, index, 0);
            }
            Array.Clear(bytes, 0, bytes.Length);
            Marshal.FreeHGlobal(blobPointer);
            Marshal.FreeHGlobal(usernamePointer);
            Marshal.FreeHGlobal(targetPointer);
        }
    }

    public static void DeleteGenericCredential(string target)
    {
        if (!CredDelete(target, 1, 0))
        {
            int error = Marshal.GetLastWin32Error();
            if (error != 1168)
            {
                throw new Win32Exception(error, "无法删除 Windows Credential Manager 凭据");
            }
        }
    }

}
"@

function Find-AppWindow {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][int] $ChildId
    )

    return [WooTodoSmokeNative]::FindTopLevelWindow([uint32] $Process.Id, $ChildId)
}

function Require-ChildWindow {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Parent,
        [Parameter(Mandatory = $true)][int] $Id
    )

    $window = [WooTodoSmokeNative]::GetDlgItem($Parent, $Id)
    if ($window -eq [IntPtr]::Zero) {
        throw "缺少 Win32 子控件：$Id"
    }
    return $window
}

function Get-ControlText {
    param([Parameter(Mandatory = $true)][IntPtr] $Control)

    return [WooTodoSmokeNative]::GetText($Control)
}

function Set-ControlText {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Control,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text
    )

    if (-not [WooTodoSmokeNative]::SetWindowTextW($Control, $Text)) {
        throw "无法写入 Win32 控件文本"
    }
}

function Click-Control {
    param([Parameter(Mandatory = $true)][IntPtr] $Control)

    [WooTodoSmokeNative]::SendMessageW(
        $Control,
        0x00F5,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ) | Out-Null
}

function Find-AppDialog {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][string] $Title
    )

    return [WooTodoSmokeNative]::FindTopLevelWindowByTitle([uint32] $Process.Id, $Title)
}

function Submit-FileDialog {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][string] $Path
    )

    Wait-ForCondition -Description "打开 $Title 文件对话框" -TimeoutSeconds 15 -Condition {
        (Find-AppDialog -Process $Process -Title $Title) -ne [IntPtr]::Zero
    }
    $dialog = Find-AppDialog -Process $Process -Title $Title
    if (-not [WooTodoSmokeNative]::SetFileDialogPath($dialog, $Path)) {
        throw "无法向 $Title 文件对话框写入路径"
    }
    $accept = Require-ChildWindow -Parent $dialog -Id 1
    if (-not [WooTodoSmokeNative]::PostMessageW(
            $accept,
            0x00F5,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        )) {
        throw "无法提交 $Title 文件对话框"
    }
    Wait-ForCondition -Description "关闭 $Title 文件对话框" -TimeoutSeconds 15 -Condition {
        (Find-AppDialog -Process $Process -Title $Title) -eq [IntPtr]::Zero
    }
}

function Dismiss-AppDialog {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][string] $Title,
        [int] $TimeoutSeconds = 30
    )

    Wait-ForCondition -Description "显示 $Title 对话框" -TimeoutSeconds $TimeoutSeconds -Condition {
        (Find-AppDialog -Process $Process -Title $Title) -ne [IntPtr]::Zero
    }
    $dialog = Find-AppDialog -Process $Process -Title $Title
    $accept = Require-ChildWindow -Parent $dialog -Id 1
    if (-not [WooTodoSmokeNative]::PostMessageW(
            $accept,
            0x00F5,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        )) {
        throw "无法关闭 $Title 对话框"
    }
    Wait-ForCondition -Description "关闭 $Title 对话框" -Condition {
        (Find-AppDialog -Process $Process -Title $Title) -eq [IntPtr]::Zero
    }
}

function Assert-TaskState {
    param(
        [Parameter(Mandatory = $true)][string] $Inspector,
        [Parameter(Mandatory = $true)][string] $Database,
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][ValidateSet("pending", "completed")][string] $State
    )

    $output = & $Inspector $Database $Title $State 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "任务数据库断言失败：$($output -join [Environment]::NewLine)"
    }
    Add-Diagnostic ($output -join " ")
}

function Read-Settings {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "设置文件不存在：$Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-Settings {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][double] $Opacity,
        [Parameter(Mandatory = $true)][bool] $ClickThrough
    )

    $settings = Read-Settings -Path $Path
    if ([Math]::Abs(([double] $settings.Opacity) - $Opacity) -gt 0.001) {
        throw "透明度持久化不匹配：预期 $Opacity，实际 $($settings.Opacity)"
    }
    if ([bool] $settings.ClickThrough -ne $ClickThrough) {
        throw "鼠标穿透持久化不匹配：预期 $ClickThrough，实际 $($settings.ClickThrough)"
    }
    Add-Diagnostic "设置符合预期：Opacity=$Opacity, ClickThrough=$ClickThrough"
}

function Assert-FloatingStyle {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Floating,
        [Parameter(Mandatory = $true)][double] $Opacity,
        [Parameter(Mandatory = $true)][bool] $ClickThrough
    )

    $style = [WooTodoSmokeNative]::GetWindowLongPtrW($Floating, -20).ToInt64()
    $transparent = ($style -band 0x20) -ne 0
    if ($transparent -ne $ClickThrough) {
        throw "悬浮窗 WS_EX_TRANSPARENT 状态不匹配：预期 $ClickThrough，实际 $transparent"
    }
    $colorKey = [uint32] 0
    $alpha = [byte] 0
    $flags = [uint32] 0
    if (-not [WooTodoSmokeNative]::GetLayeredWindowAttributes(
            $Floating,
            [ref] $colorKey,
            [ref] $alpha,
            [ref] $flags
        )) {
        throw "无法读取悬浮窗透明度"
    }
    $expectedAlpha = [byte] [Math]::Round($Opacity * 255.0)
    if ($alpha -ne $expectedAlpha -or ($flags -band 0x2) -eq 0) {
        throw "悬浮窗透明度不匹配：预期 $expectedAlpha，实际 $alpha，flags=$flags"
    }
    Add-Diagnostic "窗口样式符合预期：alpha=$alpha, clickThrough=$ClickThrough"
}

function Select-MainSection {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][int] $Index,
        [Parameter(Mandatory = $true)][string] $ExpectedLabel
    )

    $navigation = Require-ChildWindow -Parent $Main -Id 100
    $label = [WooTodoSmokeNative]::GetListBoxItemText($navigation, $Index)
    if ($label -ne $ExpectedLabel) {
        throw "导航项不匹配：索引 $Index，预期 $ExpectedLabel，实际 $label"
    }
    [WooTodoSmokeNative]::SendMessageW(
        $navigation,
        0x0186,
        [IntPtr] $Index,
        [IntPtr]::Zero
    ) | Out-Null
    $command = 100 -bor (1 -shl 16)
    [WooTodoSmokeNative]::SendMessageW($Main, 0x0111, [IntPtr] $command, $navigation) | Out-Null
    $selected = [WooTodoSmokeNative]::SendMessageW(
        $navigation,
        0x0188,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt32()
    if ($selected -ne $Index) {
        throw "无法切换到导航项 $ExpectedLabel，当前索引：$selected"
    }
}

function Select-SettingsSection {
    param([Parameter(Mandatory = $true)][IntPtr] $Main)

    Select-MainSection -Main $Main -Index 7 -ExpectedLabel "显示与快捷键"
    $opacity = Require-ChildWindow -Parent $Main -Id 120
    Wait-ForCondition -Description "显示设置控件可见" -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($opacity)
    }
}

function Select-SyncSection {
    param([Parameter(Mandatory = $true)][IntPtr] $Main)

    Select-MainSection -Main $Main -Index 8 -ExpectedLabel "同步与备份"
    $mode = Require-ChildWindow -Parent $Main -Id 150
    Wait-ForCondition -Description "同步与备份控件可见" -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($mode)
    }
}

function Assert-ExtendedSettingsControls {
    param([Parameter(Mandatory = $true)][IntPtr] $Main)

    foreach ($id in @(130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145)) {
        $control = Require-ChildWindow -Parent $Main -Id $id
        if (-not [WooTodoSmokeNative]::IsWindowVisible($control)) {
            throw "显示与快捷键设置控件不可见：$id"
        }
    }
    $elapsedDate = Require-ChildWindow -Parent $Main -Id 132
    $deadlineDate = Require-ChildWindow -Parent $Main -Id 139
    if ($elapsedDate -eq $deadlineDate) {
        throw "耗时起始日与截止日期错误地复用了同一个控件"
    }
    $visibleTexts = [WooTodoSmokeNative]::VisibleChildTexts($Main)
    if (($visibleTexts | Where-Object { $_ -match "变量日期" }).Count -ne 0) {
        throw "显示设置仍包含已取消的变量日期入口"
    }
    Add-Diagnostic "标题、副标题、独立日期变量和四项快捷键入口均可见"
}

function Assert-IndependentDisplayDates {
    param([Parameter(Mandatory = $true)][IntPtr] $Main)

    $subtitle = Require-ChildWindow -Parent $Main -Id 131
    $elapsedDate = Require-ChildWindow -Parent $Main -Id 132
    $deadlineDate = Require-ChildWindow -Parent $Main -Id 139
    Set-ControlText -Control $subtitle -Text ""
    if (-not [WooTodoSmokeNative]::SetDatePicker($elapsedDate, 2026, 7, 1)) {
        throw "无法设置耗时起始日"
    }
    if (-not [WooTodoSmokeNative]::SetDatePicker($deadlineDate, 2027, 1, 31)) {
        throw "无法设置截止日期"
    }
    Click-Control -Control (Require-ChildWindow -Parent $Main -Id 133)
    Click-Control -Control (Require-ChildWindow -Parent $Main -Id 134)
    $value = Get-ControlText -Control $subtitle
    if (-not $value.Contains("{elapsedDays:2026-07-01}") -or
        -not $value.Contains("{deadlineDays:2027-01-31}")) {
        throw "两个日期没有各自生成参数化变量：$value"
    }
    Add-Diagnostic "耗时与截止变量分别使用自己的日期控件"
}

function Save-DisplayTemplate {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][string] $Header,
        [Parameter(Mandatory = $true)][string] $Subtitle
    )

    $headerEdit = Require-ChildWindow -Parent $Main -Id 130
    $subtitleEdit = Require-ChildWindow -Parent $Main -Id 131
    $headerWritten = [WooTodoSmokeNative]::SetWindowTextW($headerEdit, $Header)
    $subtitleWritten = [WooTodoSmokeNative]::SetWindowTextW($subtitleEdit, $Subtitle)
    if (-not $headerWritten -or -not $subtitleWritten) {
        throw "无法写入显示模板"
    }
    $save = Require-ChildWindow -Parent $Main -Id 137
    [WooTodoSmokeNative]::SendMessageW($save, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
}

function Assert-DisplayTemplate {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Header,
        [Parameter(Mandatory = $true)][string] $Subtitle
    )

    $settings = Read-Settings -Path $Path
    if ([string] $settings.Display.HeaderTemplate -ne $Header -or
        [string] $settings.Display.SubtitleTemplate -ne $Subtitle) {
        throw "显示模板持久化不匹配"
    }
    Add-Diagnostic "标题与副标题模板持久化验证通过"
}

function Select-SyncMode {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][ValidateRange(0, 2)][int] $Index
    )

    $mode = Require-ChildWindow -Parent $Main -Id 150
    [WooTodoSmokeNative]::SendMessageW(
        $mode,
        0x014E,
        [IntPtr] $Index,
        [IntPtr]::Zero
    ) | Out-Null
    $command = 150 -bor (1 -shl 16)
    [WooTodoSmokeNative]::SendMessageW($Main, 0x0111, [IntPtr] $command, $mode) | Out-Null
    $selected = [WooTodoSmokeNative]::SendMessageW(
        $mode,
        0x0147,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt32()
    if ($selected -ne $Index) {
        throw "同步方式没有切换到索引 $Index，实际为 $selected"
    }
}

function Assert-SyncModeSurface {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][ValidateSet("worker", "local", "webdav")][string] $Mode
    )

    $expectation = switch ($Mode) {
        "worker" {
            @{
                Index = 0
                Label = "Worker 在线同步"
                Setup = "创建空间"
                Visible = @(151, 152, 155, 156, 157, 158, 162, 163, 164)
                Hidden = @(153, 154)
            }
        }
        "local" {
            @{
                Index = 1
                Label = "同一网络同步"
                Setup = "开启本机主机"
                Visible = @(151, 155, 156, 157, 158, 162, 163, 164)
                Hidden = @(152, 153, 154)
            }
        }
        "webdav" {
            @{
                Index = 2
                Label = "坚果云 WebDAV"
                Setup = "生成新空间"
                Visible = @(153, 154, 155, 156, 158)
                Hidden = @(151, 152, 157, 162, 163, 164)
            }
        }
    }
    Select-SyncMode -Main $Main -Index $expectation.Index
    $modeControl = Require-ChildWindow -Parent $Main -Id 150
    $modeCount = [WooTodoSmokeNative]::SendMessageW(
        $modeControl,
        0x0146,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt32()
    $modeLabel = [WooTodoSmokeNative]::GetComboBoxItemText($modeControl, $expectation.Index)
    if ($modeCount -ne 3 -or $modeLabel -ne $expectation.Label) {
        throw "同步方式列表不匹配：count=$modeCount, label=$modeLabel"
    }
    foreach ($id in $expectation.Visible) {
        if (-not [WooTodoSmokeNative]::IsWindowVisible(
                (Require-ChildWindow -Parent $Main -Id $id)
            )) {
            throw "$Mode 同步缺少可见控件：$id"
        }
    }
    foreach ($id in $expectation.Hidden) {
        if ([WooTodoSmokeNative]::IsWindowVisible(
                (Require-ChildWindow -Parent $Main -Id $id)
            )) {
            throw "$Mode 同步错误显示控件：$id"
        }
    }
    foreach ($id in @(150, 159, 160, 161, 165)) {
        Require-ChildWindow -Parent $Main -Id $id | Out-Null
    }
    foreach ($id in @(170, 171, 172, 173, 174)) {
        if (-not [WooTodoSmokeNative]::IsWindowVisible(
                (Require-ChildWindow -Parent $Main -Id $id)
            )) {
            throw "$Mode 同步缺少可见备份控件：$id"
        }
    }
    $setupText = Get-ControlText -Control (Require-ChildWindow -Parent $Main -Id 159)
    if ($setupText -ne $expectation.Setup) {
        throw "$Mode 同步主操作文案不匹配：$setupText"
    }
    Add-Diagnostic "$Mode 同步表单显隐与主操作文案正确"
}

function Read-SyncCredential {
    param([Parameter(Mandatory = $true)][string] $Target)

    $raw = [WooTodoSmokeNative]::ReadGenericCredential($Target)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return $raw | ConvertFrom-Json
}

function Write-SyncCredential {
    param(
        [Parameter(Mandatory = $true)][string] $Target,
        [Parameter(Mandatory = $true)] $Credential
    )

    $raw = $Credential | ConvertTo-Json -Compress
    [WooTodoSmokeNative]::WriteGenericCredential($Target, $raw)
}

function Assert-SettingsContainsNoSecrets {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)] $Credential
    )

    $raw = Get-Content -LiteralPath $Path -Raw
    foreach ($pattern in @("device_?token", "vault_?key", "app_?password", "pairing_?secret")) {
        if ($raw -match "(?i)$pattern") {
            throw "settings.json 包含敏感字段名：$pattern"
        }
    }
    $secretValues = foreach ($name in @("device_token", "vault_key", "app_password")) {
        $property = $Credential.PSObject.Properties[$name]
        if ($null -ne $property) {
            $property.Value
        }
    }
    foreach ($value in $secretValues) {
        if (-not [string]::IsNullOrEmpty([string] $value) -and $raw.Contains([string] $value)) {
            throw "settings.json 包含 Credential Manager 中的秘密值"
        }
    }
    Add-Diagnostic "同步身份仅存在 Credential Manager，settings.json 未包含秘密"
}

function Assert-LocalNetworkHealth {
    param([Parameter(Mandatory = $true)] $Credential)

    if ([string] $Credential.mode -ne "localNetwork") {
        throw "Credential Manager 中不是局域网身份"
    }
    $endpoint = [Uri] ([string] $Credential.endpoint)
    if ($endpoint.Scheme -ne "http" -or $endpoint.Port -ne 48473) {
        throw "局域网主机地址不是 HTTP 48473：$endpoint"
    }
    $health = Invoke-RestMethod `
        -Uri ($endpoint.AbsoluteUri.TrimEnd("/") + "/health") `
        -Method Get `
        -NoProxy `
        -TimeoutSec 10
    if (-not [bool] $health.ok -or
        [int] $health.data.version -ne 1 -or
        [string] $health.data.service -ne "woo-todo-local-sync") {
        throw "局域网 /health 响应不符合协议"
    }
    Add-Diagnostic "局域网主机 48473 /health 验证通过"
}

function New-Base64UrlToken {
    $bytes = [byte[]]::new(32)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function ConvertFrom-UriQuery {
    param([Parameter(Mandatory = $true)][Uri] $Uri)

    $result = @{}
    foreach ($component in $Uri.Query.TrimStart("?").Split("&", [StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $component.Split("=", 2)
        if ($parts.Count -ne 2) {
            throw "配对链接查询参数格式无效"
        }
        $name = [Uri]::UnescapeDataString($parts[0])
        if ($result.ContainsKey($name)) {
            throw "配对链接包含重复参数：$name"
        }
        $result[$name] = [Uri]::UnescapeDataString($parts[1].Replace("+", " "))
    }
    return $result
}

function Assert-PairingFlow {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][IntPtr] $Main
    )

    $pair = Require-ChildWindow -Parent $Main -Id 166
    $copy = Require-ChildWindow -Parent $Main -Id 167
    $confirm = Require-ChildWindow -Parent $Main -Id 168
    $qr = Require-ChildWindow -Parent $Main -Id 169
    $output = Require-ChildWindow -Parent $Main -Id 165

    Click-Control -Control $pair
    Wait-ForCondition -Description "生成局域网配对二维码" -TimeoutSeconds 20 -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($qr) -and
        [WooTodoSmokeNative]::SendMessageW(
            $qr,
            0x0173,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ) -ne [IntPtr]::Zero -and
        (Get-ControlText -Control $pair) -eq "取消配对"
    }
    if (-not [WooTodoSmokeNative]::IsWindowVisible($copy) -or
        [WooTodoSmokeNative]::IsWindowVisible($confirm)) {
        throw "扫码阶段的复制或核对控件状态不正确"
    }
    Click-Control -Control $pair
    Wait-ForCondition -Description "取消配对并清除二维码" -Condition {
        -not [WooTodoSmokeNative]::IsWindowVisible($qr) -and
        (Get-ControlText -Control $pair) -eq "生成配对"
    }

    Click-Control -Control $pair
    Wait-ForCondition -Description "重新生成局域网配对二维码" -TimeoutSeconds 20 -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($qr) -and
        [WooTodoSmokeNative]::IsWindowVisible($copy)
    }
    Click-Control -Control $copy
    $pairingLink = ""
    $clipboardDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        try {
            $candidate = [WooTodoSmokeNative]::ReadClipboardUnicodeText()
            if ($candidate.StartsWith("wootodo://pair?")) {
                $pairingLink = $candidate
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    } while ([DateTime]::UtcNow -lt $clipboardDeadline)
    if ([string]::IsNullOrEmpty($pairingLink)) {
        throw "复制链接按钮没有写入配对深链"
    }
    $pairingUri = [Uri] $pairingLink
    $query = ConvertFrom-UriQuery -Uri $pairingUri
    $expectedFields = @("endpoint", "pairingId", "pairingSecret", "initiatorPublicKey")
    if ($query.Count -ne $expectedFields.Count -or
        ($expectedFields | Where-Object { -not $query.ContainsKey($_) }).Count -ne 0) {
        throw "配对深链字段不完整"
    }
    $claimBody = @{
        pairingSecret = [string] $query.pairingSecret
        deviceToken = New-Base64UrlToken
        device = @{
            name = "Android Runner 烟测"
            platform = "android"
            publicKey = "vksCGOLYjFQF6u5EojyzwJdKfCtJRrd3DeJburl3c38"
        }
    } | ConvertTo-Json -Depth 4 -Compress
    $claimEndpoint = ([string] $query.endpoint).TrimEnd("/") +
        "/v1/pairings/" + [Uri]::EscapeDataString([string] $query.pairingId) + "/claim"
    $claim = Invoke-RestMethod `
        -Uri $claimEndpoint `
        -Method Post `
        -ContentType "application/json" `
        -Body $claimBody `
        -NoProxy `
        -TimeoutSec 10
    if (-not [bool] $claim.ok -or [string] $claim.data.status -ne "claimed") {
        throw "局域网配对认领响应无效"
    }
    Wait-ForCondition -Description "显示六位核对码" -TimeoutSeconds 20 -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($confirm) -and
        [WooTodoSmokeNative]::IsWindowEnabled($confirm) -and
        (Get-ControlText -Control $output) -match "[0-9]{6}"
    }
    if ([WooTodoSmokeNative]::IsWindowVisible($qr)) {
        throw "进入核对阶段后仍显示配对二维码"
    }
    Click-Control -Control $confirm
    Wait-ForCondition -Description "确认配对设备" -TimeoutSeconds 20 -Condition {
        (Get-ControlText -Control $output).Contains("设备绑定成功")
    }
    Add-Diagnostic "配对二维码、取消、认领、六位核对与确认流程通过"
}

function Assert-WebDavConfigurationQr {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)] $Credential
    )

    $mode = Require-ChildWindow -Parent $Main -Id 150
    $selected = [WooTodoSmokeNative]::SendMessageW(
        $mode,
        0x0147,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt32()
    if ($selected -ne 2) {
        throw "载入坚果云身份后没有选中坚果云方式：$selected"
    }
    Assert-SensitiveFieldsEmpty -Main $Main

    $pair = Require-ChildWindow -Parent $Main -Id 166
    $copy = Require-ChildWindow -Parent $Main -Id 167
    $qr = Require-ChildWindow -Parent $Main -Id 169
    if (-not [WooTodoSmokeNative]::IsWindowVisible($pair) -or
        (Get-ControlText -Control $pair) -ne "生成配置码") {
        throw "坚果云配置二维码入口不可用"
    }
    Click-Control -Control $pair
    Wait-ForCondition -Description "生成坚果云配置二维码" -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($qr) -and
        [WooTodoSmokeNative]::SendMessageW(
            $qr,
            0x0173,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ) -ne [IntPtr]::Zero -and
        [WooTodoSmokeNative]::IsWindowVisible($copy) -and
        (Get-ControlText -Control $pair) -eq "隐藏配置码"
    }

    Click-Control -Control $copy
    $configurationLink = ""
    $clipboardDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        try {
            $candidate = [WooTodoSmokeNative]::ReadClipboardUnicodeText()
            if ($candidate.StartsWith("wootodo://webdav?")) {
                $configurationLink = $candidate
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    } while ([DateTime]::UtcNow -lt $clipboardDeadline)
    if ([string]::IsNullOrEmpty($configurationLink)) {
        throw "复制配置按钮没有写入坚果云配置深链"
    }
    $query = ConvertFrom-UriQuery -Uri ([Uri] $configurationLink)
    $expectedFields = @("v", "username", "appPassword", "vaultId", "vaultKey")
    if ($query.Count -ne $expectedFields.Count -or
        ($expectedFields | Where-Object { -not $query.ContainsKey($_) }).Count -ne 0 -or
        [string] $query.v -ne "1" -or
        [string] $query.username -ne [string] $Credential.username -or
        [string] $query.appPassword -ne [string] $Credential.app_password -or
        [string] $query.vaultId -ne [string] $Credential.vault_id -or
        [string] $query.vaultKey -ne [string] $Credential.vault_key) {
        throw "坚果云配置深链字段与 Credential Manager 身份不一致"
    }

    Click-Control -Control $pair
    Wait-ForCondition -Description "隐藏坚果云配置二维码" -Condition {
        -not [WooTodoSmokeNative]::IsWindowVisible($qr) -and
        -not [WooTodoSmokeNative]::IsWindowVisible($copy) -and
        [WooTodoSmokeNative]::SendMessageW(
            $qr,
            0x0173,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ) -eq [IntPtr]::Zero -and
        (Get-ControlText -Control $pair) -eq "生成配置码"
    }

    Click-Control -Control $pair
    Wait-ForCondition -Description "重新生成坚果云配置二维码" -Condition {
        [WooTodoSmokeNative]::SendMessageW(
            $qr,
            0x0173,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ) -ne [IntPtr]::Zero
    }
    Select-SettingsSection -Main $Main
    Assert-SensitiveFieldsEmpty -Main $Main
    if ([WooTodoSmokeNative]::SendMessageW(
            $qr,
            0x0173,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ) -ne [IntPtr]::Zero) {
        throw "离开同步页后没有清除坚果云配置二维码位图"
    }
    Select-SyncSection -Main $Main
    if ([WooTodoSmokeNative]::IsWindowVisible($qr) -or
        [WooTodoSmokeNative]::IsWindowVisible($copy) -or
        (Get-ControlText -Control $pair) -ne "生成配置码") {
        throw "重新进入同步页后仍保留坚果云配置二维码状态"
    }
    Assert-SensitiveFieldsEmpty -Main $Main
    Add-Diagnostic "坚果云配置二维码生成、复制、字段校验及离页清除通过"
}

function Set-SmokeSensitiveFields {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][string] $Sentinel
    )

    foreach ($id in @(152, 154, 157, 158, 170, 171)) {
        Set-ControlText -Control (Require-ChildWindow -Parent $Main -Id $id) -Text "$Sentinel-$id"
    }
}

function Assert-SensitiveFieldsEmpty {
    param([Parameter(Mandatory = $true)][IntPtr] $Main)

    foreach ($id in @(152, 154, 157, 158, 170, 171)) {
        $value = Get-ControlText -Control (Require-ChildWindow -Parent $Main -Id $id)
        if (-not [string]::IsNullOrEmpty($value)) {
            throw "敏感控件离开同步页后没有清空：$id"
        }
    }
}

function Export-SmokeBackup {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Passphrase
    )

    Set-ControlText -Control (Require-ChildWindow -Parent $Main -Id 170) -Text $Passphrase
    Set-ControlText -Control (Require-ChildWindow -Parent $Main -Id 171) -Text $Passphrase
    [WooTodoSmokeNative]::SendMessageW(
        (Require-ChildWindow -Parent $Main -Id 172),
        0x00F1,
        [IntPtr] 1,
        [IntPtr]::Zero
    ) | Out-Null
    $export = Require-ChildWindow -Parent $Main -Id 173
    if (-not [WooTodoSmokeNative]::PostMessageW(
            $export,
            0x00F5,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        )) {
        throw "无法启动备份导出"
    }
    Submit-FileDialog -Process $Process -Title "导出加密备份" -Path $Path
    Dismiss-AppDialog -Process $Process -Title "备份已导出" -TimeoutSeconds 90
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -le 64) {
        throw "导出的 .wootodo 文件不存在或为空"
    }
    foreach ($id in @(170, 171)) {
        if (-not [string]::IsNullOrEmpty(
                (Get-ControlText -Control (Require-ChildWindow -Parent $Main -Id $id))
            )) {
            throw "备份导出开始后仍保留口令：$id"
        }
    }
    Add-Diagnostic "带局域网身份的加密备份已导出"
}

function Import-SmokeBackup {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Passphrase
    )

    Set-ControlText -Control (Require-ChildWindow -Parent $Main -Id 170) -Text $Passphrase
    Set-ControlText -Control (Require-ChildWindow -Parent $Main -Id 171) -Text $Passphrase
    $import = Require-ChildWindow -Parent $Main -Id 174
    if (-not [WooTodoSmokeNative]::PostMessageW(
            $import,
            0x00F5,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        )) {
        throw "无法启动备份恢复"
    }
    Submit-FileDialog -Process $Process -Title "恢复加密备份" -Path $Path
    Dismiss-AppDialog -Process $Process -Title "恢复完成" -TimeoutSeconds 90
    foreach ($id in @(170, 171)) {
        if (-not [string]::IsNullOrEmpty(
                (Get-ControlText -Control (Require-ChildWindow -Parent $Main -Id $id))
            )) {
            throw "备份恢复开始后仍保留口令：$id"
        }
    }
    Add-Diagnostic "加密备份已恢复到空白数据目录"
}

function Set-Opacity {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $Main,
        [Parameter(Mandatory = $true)][int] $Value
    )

    $trackbar = Require-ChildWindow -Parent $Main -Id 120
    [WooTodoSmokeNative]::SendMessageW($trackbar, 0x0405, [IntPtr] 1, [IntPtr] $Value) | Out-Null
    [WooTodoSmokeNative]::SendMessageW($Main, 0x0114, [IntPtr]::Zero, $trackbar) | Out-Null
}

function Toggle-FirstTaskCheckbox {
    param([Parameter(Mandatory = $true)][IntPtr] $List)

    # Home 会让分组 ListView 自己选择并聚焦首项，不需要跨进程传递几何结构体。
    [WooTodoSmokeNative]::SendMessageW($List, 0x0100, [IntPtr] 0x24, [IntPtr]::Zero) | Out-Null
    [WooTodoSmokeNative]::SendMessageW($List, 0x0101, [IntPtr] 0x24, [IntPtr]::Zero) | Out-Null
    $selected = [WooTodoSmokeNative]::SendMessageW($List, 0x100C, [IntPtr](-1), [IntPtr] 3).ToInt64()
    if ($selected -ne 0) {
        throw "无法选中悬浮任务板首行，实际索引：$selected"
    }
    [WooTodoSmokeNative]::SendMessageW($List, 0x0100, [IntPtr] 0x20, [IntPtr]::Zero) | Out-Null
    [WooTodoSmokeNative]::SendMessageW($List, 0x0101, [IntPtr] 0x20, [IntPtr]::Zero) | Out-Null
}

function Assert-TaskEditorControls {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][IntPtr] $Main
    )

    if (-not [WooTodoSmokeNative]::PostMessageW(
            $Main,
            0x0111,
            [IntPtr] 110,
            [IntPtr]::Zero
        )) {
        throw "无法打开任务编辑器"
    }
    Wait-ForCondition -Description "打开带提醒和截止日期的任务编辑器" -Condition {
        (Find-AppWindow -Process $Process -ChildId 305) -ne [IntPtr]::Zero
    }
    $editor = Find-AppWindow -Process $Process -ChildId 305
    foreach ($id in @(305, 306, 307, 308)) {
        Require-ChildWindow -Parent $editor -Id $id | Out-Null
    }

    $reminderToggle = Require-ChildWindow -Parent $editor -Id 305
    $reminderTime = Require-ChildWindow -Parent $editor -Id 306
    $deadlineToggle = Require-ChildWindow -Parent $editor -Id 307
    $deadlineDate = Require-ChildWindow -Parent $editor -Id 308
    [WooTodoSmokeNative]::SendMessageW($reminderToggle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    [WooTodoSmokeNative]::SendMessageW($deadlineToggle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if (-not [WooTodoSmokeNative]::IsWindowEnabled($reminderTime) -or
        -not [WooTodoSmokeNative]::IsWindowEnabled($deadlineDate)) {
        throw "提醒或截止日期选择器没有随开关启用"
    }

    $timeType = Require-ChildWindow -Parent $editor -Id 301
    [WooTodoSmokeNative]::SendMessageW($timeType, 0x014E, [IntPtr] 3, [IntPtr]::Zero) | Out-Null
    $timeTypeChanged = 301 -bor (1 -shl 16)
    [WooTodoSmokeNative]::SendMessageW($editor, 0x0111, [IntPtr] $timeTypeChanged, $timeType) | Out-Null
    if ([WooTodoSmokeNative]::IsWindowEnabled($reminderToggle) -or
        [WooTodoSmokeNative]::IsWindowEnabled($reminderTime)) {
        throw "闲时任务仍允许设置提醒"
    }

    [WooTodoSmokeNative]::SendMessageW($timeType, 0x014E, [IntPtr] 0, [IntPtr]::Zero) | Out-Null
    [WooTodoSmokeNative]::SendMessageW($editor, 0x0111, [IntPtr] $timeTypeChanged, $timeType) | Out-Null
    $repeat = Require-ChildWindow -Parent $editor -Id 304
    [WooTodoSmokeNative]::SendMessageW($repeat, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if ([WooTodoSmokeNative]::IsWindowEnabled($deadlineToggle) -or
        [WooTodoSmokeNative]::IsWindowEnabled($deadlineDate)) {
        throw "重复任务仍允许设置截止日期"
    }

    [WooTodoSmokeNative]::PostMessageW($editor, 0x0111, [IntPtr] 2, [IntPtr]::Zero) | Out-Null
    Wait-ForCondition -Description "关闭任务编辑器" -Condition {
        [WooTodoSmokeNative]::IsWindowEnabled($Main)
    }
    Add-Diagnostic "任务编辑器提醒、截止日期和互斥规则验证通过"
}

function Save-Screenshot {
    param([Parameter(Mandatory = $true)][string] $Name)

    try {
        Add-Type -AssemblyName System.Drawing
        $width = [WooTodoSmokeNative]::GetSystemMetrics(0)
        $height = [WooTodoSmokeNative]::GetSystemMetrics(1)
        if ($width -le 0 -or $height -le 0) {
            throw "Runner 没有可截图的桌面尺寸"
        }
        $bitmap = [Drawing.Bitmap]::new($width, $height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen(0, 0, 0, 0, $bitmap.Size)
            $bitmap.Save((Join-Path $ArtifactDirectory $Name), [Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
    catch {
        Add-Diagnostic "截图失败（不影响烟测结论）：$($_.Exception.Message)"
    }
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    "woo-todo-smoke-" + [Guid]::NewGuid().ToString("N")
)
$primary = $null
$secondary = $null
$dataDirectory = $null
$sourceDataDirectory = $null
$restoredDataDirectory = $null
$credentialTarget = "WooTodo/Sync/v1"
$credentialMayHaveBeenCreated = $false
$previousSkipIntegration = $env:WOO_TODO_SKIP_PORTABLE_INTEGRATION
$previousSkipUpdateCheck = $env:WOO_TODO_SKIP_UPDATE_CHECK
$previousSmokeTrace = $env:WOO_TODO_SMOKE_TRACE
$previousLocalAppData = $env:LOCALAPPDATA

try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    $env:LOCALAPPDATA = Join-Path $temporaryDirectory "local-app-data"
    $dataDirectory = Join-Path $env:LOCALAPPDATA "Woo Todo"
    $sourceDataDirectory = $dataDirectory
    $database = Join-Path $dataDirectory "woo-todo.sqlite3"
    $settingsPath = Join-Path $dataDirectory "settings.json"
    $backupPath = Join-Path $temporaryDirectory "runner-smoke-backup.wootodo"
    $backupPassphrase = "Runner-Smoke-Backup-2026!"
    $env:WOO_TODO_SMOKE_TRACE = Join-Path $ArtifactDirectory "app-trace.txt"
    $env:WOO_TODO_SKIP_UPDATE_CHECK = "1"
    if (-not [string]::IsNullOrWhiteSpace(
            [WooTodoSmokeNative]::ReadGenericCredential($credentialTarget)
        )) {
        throw "烟测要求 Credential Manager 中不存在 $credentialTarget，以免覆盖真实同步身份"
    }
    Expand-Archive -LiteralPath $resolvedArchive -DestinationPath $temporaryDirectory

    $files = @(Get-ChildItem -LiteralPath $temporaryDirectory -File -Recurse)
    $executable = Join-Path $temporaryDirectory "WooTodo.exe"
    if ($files.Count -ne 1 -or $files[0].FullName -ne $executable) {
        throw "Windows ZIP 必须只包含根目录下的 WooTodo.exe"
    }
    $bytes = [IO.File]::ReadAllBytes($executable)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "WooTodo.exe 不是有效的 PE 文件"
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length) {
        throw "WooTodo.exe 的 PE 头偏移无效"
    }
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x8664) {
        throw "WooTodo.exe 不是 AMD64 PE，Machine=0x$($machine.ToString('X4'))"
    }
    Add-Diagnostic "ZIP 内容和 AMD64 PE 校验通过"

    & cargo build --quiet --manifest-path $manifestPath --example smoke_inspect --locked
    if ($LASTEXITCODE -ne 0) {
        throw "无法构建 Windows 烟测数据检查器"
    }
    $metadata = cargo metadata --manifest-path $manifestPath --format-version 1 --no-deps |
        ConvertFrom-Json
    $inspector = Join-Path ([string] $metadata.target_directory) "debug/examples/smoke_inspect.exe"
    if (-not (Test-Path -LiteralPath $inspector -PathType Leaf)) {
        throw "缺少 Windows 烟测数据检查器：$inspector"
    }

    if ($TestIntegration) {
        Remove-Item Env:WOO_TODO_SKIP_PORTABLE_INTEGRATION -ErrorAction SilentlyContinue
    } else {
        $env:WOO_TODO_SKIP_PORTABLE_INTEGRATION = "1"
    }

    $primary = Start-Process -FilePath $executable -PassThru
    if ($primary.WaitForExit(5000)) {
        throw "解压后的 WooTodo.exe 启动后意外退出，退出码：$($primary.ExitCode)"
    }
    Wait-ForCondition -Description "创建主窗口与悬浮任务板" -TimeoutSeconds 30 -Condition {
        (Find-AppWindow -Process $primary -ChildId 100) -ne [IntPtr]::Zero -and
        (Find-AppWindow -Process $primary -ChildId 200) -ne [IntPtr]::Zero
    }
    $main = Find-AppWindow -Process $primary -ChildId 100
    $floating = Find-AppWindow -Process $primary -ChildId 200
    if (-not [WooTodoSmokeNative]::IsWindowVisible($floating)) {
        throw "悬浮任务板启动后不可见"
    }
    Add-Diagnostic "原生窗口创建成功：main=$main, floating=$floating"

    $helperTestDirectory = Join-Path $temporaryDirectory "update-helper"
    $helperInputDirectory = Join-Path $helperTestDirectory "input"
    New-Item -ItemType Directory -Path $helperInputDirectory -Force | Out-Null
    $helperExecutable = Join-Path $helperTestDirectory "WooTodoUpdater.exe"
    $helperTarget = Join-Path $helperTestDirectory "WooTodoTarget.exe"
    $helperArchive = Join-Path $helperTestDirectory "update.zip"
    Copy-Item -LiteralPath $executable -Destination $helperExecutable
    Copy-Item -LiteralPath $executable -Destination $helperTarget
    Copy-Item -LiteralPath $executable -Destination (Join-Path $helperInputDirectory "WooTodo.exe")
    Compress-Archive `
        -LiteralPath (Join-Path $helperInputDirectory "WooTodo.exe") `
        -DestinationPath $helperArchive `
        -CompressionLevel Optimal
    $helperDigest = (Get-FileHash -LiteralPath $helperArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    $helperProcess = Start-Process `
        -FilePath $helperExecutable `
        -ArgumentList @(
            "--woo-todo-apply-update",
            $helperArchive,
            $helperTarget,
            "4294967295",
            "0.1.16",
            $helperDigest
        ) `
        -PassThru
    if (-not $helperProcess.WaitForExit(60000)) {
        throw "更新 helper 在 60 秒内没有结束"
    }
    if ($helperProcess.ExitCode -ne 0) {
        throw "更新 helper 失败，退出码：$($helperProcess.ExitCode)"
    }
    if ((Get-FileHash -LiteralPath $helperTarget -Algorithm SHA256).Hash -ne `
        (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash) {
        throw "更新 helper 替换后的 WooTodo.exe 与 ZIP 内容不一致"
    }
    if (Test-Path -LiteralPath $helperArchive) {
        throw "更新 helper 成功后没有清理已使用的 ZIP"
    }
    Add-Diagnostic "免安装更新 helper 的复核、替换与重启验证通过"

    $secondary = Start-Process -FilePath $executable -PassThru
    if (-not $secondary.WaitForExit(10000)) {
        throw "第二个实例没有在 10 秒内退出，单实例保护失效"
    }
    if ($primary.HasExited) {
        throw "启动第二个实例后主实例意外退出"
    }
    Wait-ForCondition -Description "第二个实例唤醒主窗口" -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($main)
    }
    Add-Diagnostic "单实例与窗口唤醒验证通过"

    if ($TestIntegration) {
        $shortcut = Join-Path $env:APPDATA "Microsoft/Windows/Start Menu/Programs/Woo Todo.lnk"
        $protocolKey = Get-Item `
            -LiteralPath "Registry::HKEY_CURRENT_USER\Software\Classes\wootodo\shell\open\command"
        $protocol = [string] $protocolKey.GetValue("")
        if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf)) {
            throw "首次运行没有创建系统通知所需的开始菜单身份"
        }
        if ($protocol -notlike "*$executable*") {
            throw "首次运行没有把 wootodo:// 协议指向当前便携版程序"
        }

        [WooTodoSmokeNative]::SendMessageW($main, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Wait-ForCondition -Description "隐藏主窗口" -Condition {
            -not [WooTodoSmokeNative]::IsWindowVisible($main)
        }
        Start-Process -FilePath "wootodo://task-reminder/runner-smoke-missing" | Out-Null
        Wait-ForCondition -Description "协议激活唤醒主窗口" -Condition {
            [WooTodoSmokeNative]::IsWindowVisible($main)
        }
        Add-Diagnostic "开始菜单身份、协议注册与协议激活验证通过"
    }

    $taskTitle = "Runner烟测-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $quickEdit = Require-ChildWindow -Parent $floating -Id 201
    $addButton = Require-ChildWindow -Parent $floating -Id 202
    $taskList = Require-ChildWindow -Parent $floating -Id 200
    [WooTodoSmokeNative]::TypeText($quickEdit, $taskTitle)
    Add-Diagnostic "已向快速新增输入框逐字符发送：$taskTitle"
    [WooTodoSmokeNative]::SendMessageW($addButton, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Wait-ForCondition -Description "快速新增任务后列表出现一条任务" -Condition {
        [WooTodoSmokeNative]::SendMessageW(
            $taskList,
            0x1004,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ).ToInt64() -eq 1 -and [WooTodoSmokeNative]::IsWindowEnabled($taskList)
    }
    $itemCount = [WooTodoSmokeNative]::SendMessageW(
        $taskList,
        0x1004,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt64()
    if ($itemCount -ne 1) {
        throw "快速新增后的控件状态异常：itemCount=$itemCount"
    }
    $groupView = [WooTodoSmokeNative]::SendMessageW(
        $taskList,
        0x10AF,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt64()
    if ($groupView -eq 0) {
        throw "悬浮任务板没有启用主线、支线、外传分组"
    }
    $groupCount = [WooTodoSmokeNative]::SendMessageW(
        $taskList,
        0x1098,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt64()
    if ($groupCount -ne 3) {
        throw "悬浮任务板分组数量异常：groupCount=$groupCount"
    }
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State pending

    Toggle-FirstTaskCheckbox -List $taskList
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State completed
    Toggle-FirstTaskCheckbox -List $taskList
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State pending
    Add-Diagnostic "快速新增、勾选完成和取消完成验证通过"

    Assert-TaskEditorControls -Process $primary -Main $main

    Select-SettingsSection -Main $main
    Assert-ExtendedSettingsControls -Main $main
    Assert-IndependentDisplayDates -Main $main
    $displayHeader = "{dateLong} · Windows烟测"
    $displaySubtitle = "{elapsedDays:2026-07-01} / {deadlineDays:2027-01-31}"
    Save-DisplayTemplate -Main $main -Header $displayHeader -Subtitle $displaySubtitle
    Assert-DisplayTemplate `
        -Path $settingsPath `
        -Header $displayHeader `
        -Subtitle $displaySubtitle
    Set-Opacity -Main $main -Value 20
    Assert-Settings -Path $settingsPath -Opacity 0.20 -ClickThrough $false
    Assert-FloatingStyle -Floating $floating -Opacity 0.20 -ClickThrough $false
    Set-Opacity -Main $main -Value 73
    $clickThrough = Require-ChildWindow -Parent $main -Id 122
    [WooTodoSmokeNative]::SendMessageW($clickThrough, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Assert-Settings -Path $settingsPath -Opacity 0.73 -ClickThrough $true
    Assert-FloatingStyle -Floating $floating -Opacity 0.73 -ClickThrough $true

    Set-Opacity -Main $main -Value 61
    Assert-Settings -Path $settingsPath -Opacity 0.61 -ClickThrough $true
    Assert-FloatingStyle -Floating $floating -Opacity 0.61 -ClickThrough $true
    [WooTodoSmokeNative]::SendMessageW($clickThrough, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Assert-Settings -Path $settingsPath -Opacity 0.61 -ClickThrough $false
    Assert-DisplayTemplate `
        -Path $settingsPath `
        -Header $displayHeader `
        -Subtitle $displaySubtitle
    Assert-FloatingStyle -Floating $floating -Opacity 0.61 -ClickThrough $false
    Add-Diagnostic "透明度与鼠标穿透独立变化验证通过"

    Select-SyncSection -Main $main
    Assert-SyncModeSurface -Main $main -Mode worker
    Assert-SyncModeSurface -Main $main -Mode local
    Assert-SyncModeSurface -Main $main -Mode webdav

    $credentialMayHaveBeenCreated = $true
    $webDavCredential = [ordered] @{
        mode = "webDav"
        username = "windows-runner@example.com"
        app_password = "Runner-WebDAV-Application-Password"
        vault_id = "vault-windows-runner"
        device_id = "device-windows-runner"
        vault_key = New-Base64UrlToken
    }
    Write-SyncCredential -Target $credentialTarget -Credential $webDavCredential
    $storedWebDavCredential = Read-SyncCredential -Target $credentialTarget
    Assert-SettingsContainsNoSecrets -Path $settingsPath -Credential $storedWebDavCredential
    Select-SettingsSection -Main $main
    Select-SyncSection -Main $main
    Assert-WebDavConfigurationQr -Main $main -Credential $storedWebDavCredential
    [WooTodoSmokeNative]::DeleteGenericCredential($credentialTarget)
    Select-SettingsSection -Main $main
    Select-SyncSection -Main $main
    Assert-SensitiveFieldsEmpty -Main $main

    Assert-SyncModeSurface -Main $main -Mode local
    Click-Control -Control (Require-ChildWindow -Parent $main -Id 159)
    Wait-ForCondition -Description "保存局域网同步身份" -TimeoutSeconds 30 -Condition {
        -not [string]::IsNullOrWhiteSpace(
            [WooTodoSmokeNative]::ReadGenericCredential($credentialTarget)
        )
    }
    $localCredential = Read-SyncCredential -Target $credentialTarget
    if ([string] $localCredential.mode -ne "localNetwork" -or
        [string]::IsNullOrWhiteSpace([string] $localCredential.device_token) -or
        [string]::IsNullOrWhiteSpace([string] $localCredential.vault_key)) {
        throw "Credential Manager 中的局域网同步身份不完整"
    }
    $storedSettings = Read-Settings -Path $settingsPath
    if (-not [bool] $storedSettings.LocalNetworkHost) {
        throw "settings.json 没有持久化非敏感的局域网主机角色"
    }
    Assert-SettingsContainsNoSecrets -Path $settingsPath -Credential $localCredential
    Assert-LocalNetworkHealth -Credential $localCredential
    Assert-SensitiveFieldsEmpty -Main $main
    Add-Diagnostic "保存和重新载入同步身份后未把秘密回填到控件"
    Assert-PairingFlow -Process $primary -Main $main

    $sensitiveSentinel = "RunnerSensitive-$([Guid]::NewGuid().ToString('N'))"
    Set-SmokeSensitiveFields -Main $main -Sentinel $sensitiveSentinel
    Select-SettingsSection -Main $main
    Assert-SensitiveFieldsEmpty -Main $main
    Add-Diagnostic "离开同步与备份页会清空全部敏感输入"

    Select-SyncSection -Main $main
    Export-SmokeBackup `
        -Process $primary `
        -Main $main `
        -Path $backupPath `
        -Passphrase $backupPassphrase

    [WooTodoSmokeNative]::SendMessageW($main, 0x0111, [IntPtr] 405, [IntPtr]::Zero) | Out-Null
    if (-not $primary.WaitForExit(10000)) {
        throw "主实例没有通过托盘退出命令正常结束"
    }
    $primary = Start-Process -FilePath $executable -PassThru
    if ($primary.WaitForExit(5000)) {
        throw "重启后的 WooTodo.exe 意外退出，退出码：$($primary.ExitCode)"
    }
    Wait-ForCondition -Description "重启后恢复原生窗口" -TimeoutSeconds 30 -Condition {
        (Find-AppWindow -Process $primary -ChildId 100) -ne [IntPtr]::Zero -and
        (Find-AppWindow -Process $primary -ChildId 200) -ne [IntPtr]::Zero
    }
    $main = Find-AppWindow -Process $primary -ChildId 100
    $floating = Find-AppWindow -Process $primary -ChildId 200
    $taskList = Require-ChildWindow -Parent $floating -Id 200
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State pending
    $restartedCredential = Read-SyncCredential -Target $credentialTarget
    Assert-SettingsContainsNoSecrets -Path $settingsPath -Credential $restartedCredential
    Assert-LocalNetworkHealth -Credential $restartedCredential
    Assert-Settings -Path $settingsPath -Opacity 0.61 -ClickThrough $false
    Assert-DisplayTemplate `
        -Path $settingsPath `
        -Header $displayHeader `
        -Subtitle $displaySubtitle
    Assert-FloatingStyle -Floating $floating -Opacity 0.61 -ClickThrough $false
    if (-not [WooTodoSmokeNative]::IsWindowEnabled($taskList)) {
        throw "重启后任务列表没有恢复"
    }

    $secondary = Start-Process -FilePath $executable -PassThru
    if (-not $secondary.WaitForExit(10000)) {
        throw "重启后的第二个实例没有正常退出"
    }
    Wait-ForCondition -Description "重启后的第二个实例唤醒主窗口" -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($main)
    }
    Select-SettingsSection -Main $main
    $trackbar = Require-ChildWindow -Parent $main -Id 120
    $restoredOpacity = [WooTodoSmokeNative]::SendMessageW(
        $trackbar,
        0x0400,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt64()
    if ($restoredOpacity -ne 61) {
        throw "重启后透明度控件没有恢复：$restoredOpacity"
    }
    Add-Diagnostic "任务、设置和局域网主机重启持久化验证通过"

    [WooTodoSmokeNative]::SendMessageW($main, 0x0111, [IntPtr] 405, [IntPtr]::Zero) | Out-Null
    if (-not $primary.WaitForExit(15000)) {
        throw "备份恢复前主实例没有正常退出"
    }
    [WooTodoSmokeNative]::DeleteGenericCredential($credentialTarget)
    if (-not [string]::IsNullOrWhiteSpace(
            [WooTodoSmokeNative]::ReadGenericCredential($credentialTarget)
        )) {
        throw "无法清理用于空白恢复的同步凭据"
    }

    $env:LOCALAPPDATA = Join-Path $temporaryDirectory "restored-local-app-data"
    $dataDirectory = Join-Path $env:LOCALAPPDATA "Woo Todo"
    $restoredDataDirectory = $dataDirectory
    $database = Join-Path $dataDirectory "woo-todo.sqlite3"
    $settingsPath = Join-Path $dataDirectory "settings.json"
    $primary = Start-Process -FilePath $executable -PassThru
    if ($primary.WaitForExit(5000)) {
        throw "空白恢复实例意外退出，退出码：$($primary.ExitCode)"
    }
    Wait-ForCondition -Description "创建空白恢复窗口" -TimeoutSeconds 30 -Condition {
        (Find-AppWindow -Process $primary -ChildId 100) -ne [IntPtr]::Zero -and
        (Find-AppWindow -Process $primary -ChildId 200) -ne [IntPtr]::Zero
    }
    $main = Find-AppWindow -Process $primary -ChildId 100
    $floating = Find-AppWindow -Process $primary -ChildId 200
    Select-SyncSection -Main $main
    Import-SmokeBackup `
        -Process $primary `
        -Main $main `
        -Path $backupPath `
        -Passphrase $backupPassphrase
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State pending
    $restoredCredential = Read-SyncCredential -Target $credentialTarget
    if ($null -eq $restoredCredential) {
        throw "空白恢复后没有写回 Credential Manager 身份"
    }
    Assert-SettingsContainsNoSecrets -Path $settingsPath -Credential $restoredCredential
    Assert-LocalNetworkHealth -Credential $restoredCredential

    $closePair = Require-ChildWindow -Parent $main -Id 166
    $closeQr = Require-ChildWindow -Parent $main -Id 169
    Click-Control -Control $closePair
    Wait-ForCondition -Description "生成用于关闭清理验证的配对二维码" -TimeoutSeconds 20 -Condition {
        [WooTodoSmokeNative]::SendMessageW(
            $closeQr,
            0x0173,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ) -ne [IntPtr]::Zero
    }
    $closeSentinel = "RunnerClose-$([Guid]::NewGuid().ToString('N'))"
    Set-SmokeSensitiveFields -Main $main -Sentinel $closeSentinel
    [WooTodoSmokeNative]::SendMessageW(
        $main,
        0x0010,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ) | Out-Null
    Wait-ForCondition -Description "关闭主窗口到托盘" -Condition {
        -not [WooTodoSmokeNative]::IsWindowVisible($main)
    }
    Assert-SensitiveFieldsEmpty -Main $main
    if ([WooTodoSmokeNative]::SendMessageW(
            $closeQr,
            0x0173,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        ) -ne [IntPtr]::Zero) {
        throw "关闭主窗口到托盘后没有清除配对二维码位图"
    }
    $secondary = Start-Process -FilePath $executable -PassThru
    if (-not $secondary.WaitForExit(10000)) {
        throw "关闭到托盘后的第二实例没有正常退出"
    }
    Wait-ForCondition -Description "关闭到托盘后重新唤醒主窗口" -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($main)
    }
    Select-SettingsSection -Main $main
    Assert-SensitiveFieldsEmpty -Main $main
    Add-Diagnostic "关闭主窗口到托盘会即时清空敏感输入与配对二维码"

    Save-Screenshot -Name "success.png"
    Set-Content `
        -LiteralPath (Join-Path $ArtifactDirectory "result.txt") `
        -Value "PASS`narchive=$resolvedArchive`ntask=$taskTitle" `
        -Encoding utf8
    Write-Host "Windows 免安装 ZIP 完整烟测通过"
}
catch {
    Add-Diagnostic "烟测失败：$($_.Exception.Message)"
    if ($null -ne $primary -and -not $primary.HasExited) {
        $windows = [WooTodoSmokeNative]::DescribeTopLevelWindows([uint32] $primary.Id)
        Add-Diagnostic "主实例顶层窗口：$windows"
    }
    Add-Content -LiteralPath $diagnosticPath -Value ($_ | Out-String) -Encoding utf8
    Save-Screenshot -Name "failure.png"
    Set-Content `
        -LiteralPath (Join-Path $ArtifactDirectory "result.txt") `
        -Value "FAIL`narchive=$resolvedArchive`nerror=$($_.Exception.Message)" `
        -Encoding utf8
    throw
}
finally {
    if ($null -eq $previousSkipIntegration) {
        Remove-Item Env:WOO_TODO_SKIP_PORTABLE_INTEGRATION -ErrorAction SilentlyContinue
    } else {
        $env:WOO_TODO_SKIP_PORTABLE_INTEGRATION = $previousSkipIntegration
    }
    if ($null -eq $previousSkipUpdateCheck) {
        Remove-Item Env:WOO_TODO_SKIP_UPDATE_CHECK -ErrorAction SilentlyContinue
    }
    else {
        $env:WOO_TODO_SKIP_UPDATE_CHECK = $previousSkipUpdateCheck
    }
    if ($null -eq $previousSmokeTrace) {
        Remove-Item Env:WOO_TODO_SMOKE_TRACE -ErrorAction SilentlyContinue
    } else {
        $env:WOO_TODO_SMOKE_TRACE = $previousSmokeTrace
    }
    foreach ($process in @($secondary, $primary)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(5000) | Out-Null
        }
    }
    if ($credentialMayHaveBeenCreated) {
        try {
            [WooTodoSmokeNative]::DeleteGenericCredential($credentialTarget)
        }
        catch {
            Add-Diagnostic "清理烟测 Credential Manager 身份失败：$($_.Exception.Message)"
        }
    }
    foreach ($snapshot in @(
            @{ Path = $sourceDataDirectory; Name = "source-data" },
            @{ Path = $restoredDataDirectory; Name = "restored-data" }
        )) {
        if ($null -ne $snapshot.Path -and (Test-Path -LiteralPath $snapshot.Path)) {
            Copy-Item `
                -LiteralPath $snapshot.Path `
                -Destination (Join-Path $ArtifactDirectory $snapshot.Name) `
                -Recurse `
                -Force
        }
    }
    $env:LOCALAPPDATA = $previousLocalAppData
    try {
        Get-WinEvent -FilterHashtable @{
            LogName = "Application"
            StartTime = (Get-Date).AddMinutes(-15)
        } -ErrorAction Stop |
            Where-Object { $_.Message -like "*WooTodo*" -or $_.Message -like "*Woo Todo*" } |
            Format-List * |
            Out-File -LiteralPath (Join-Path $ArtifactDirectory "windows-events.txt") -Encoding utf8
    }
    catch {
        Add-Diagnostic "读取 Windows Application 事件失败：$($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
