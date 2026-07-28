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
using System.Runtime.InteropServices;
using System.Text;

public static class WooTodoSmokeNative
{
    public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetClassNameW(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetDlgItem(IntPtr parent, int id);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowTextW(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowEnabled(IntPtr window);

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

function Select-SettingsSection {
    param([Parameter(Mandatory = $true)][IntPtr] $Main)

    $navigation = Require-ChildWindow -Parent $Main -Id 100
    [WooTodoSmokeNative]::SendMessageW($navigation, 0x0186, [IntPtr] 7, [IntPtr]::Zero) | Out-Null
    $command = 100 -bor (1 -shl 16)
    [WooTodoSmokeNative]::SendMessageW($Main, 0x0111, [IntPtr] $command, $navigation) | Out-Null
    $opacity = Require-ChildWindow -Parent $Main -Id 120
    Wait-ForCondition -Description "显示设置控件可见" -Condition {
        [WooTodoSmokeNative]::IsWindowVisible($opacity)
    }
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

    # 点击文本区选中首行，再发送空格，让原生 ListView 自己切换复选框并产生 LVN_ITEMCHANGED。
    $coordinates = 80 -bor (10 -shl 16)
    [WooTodoSmokeNative]::SendMessageW($List, 0x0201, [IntPtr] 1, [IntPtr] $coordinates) | Out-Null
    [WooTodoSmokeNative]::SendMessageW($List, 0x0202, [IntPtr]::Zero, [IntPtr] $coordinates) | Out-Null
    $selected = [WooTodoSmokeNative]::SendMessageW($List, 0x100C, [IntPtr](-1), [IntPtr] 2).ToInt64()
    if ($selected -ne 0) {
        throw "无法选中悬浮任务板首行，实际索引：$selected"
    }
    [WooTodoSmokeNative]::SendMessageW($List, 0x0100, [IntPtr] 0x20, [IntPtr]::Zero) | Out-Null
    [WooTodoSmokeNative]::SendMessageW($List, 0x0101, [IntPtr] 0x20, [IntPtr]::Zero) | Out-Null
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
$previousSkipIntegration = $env:WOO_TODO_SKIP_PORTABLE_INTEGRATION
$previousSkipUpdateCheck = $env:WOO_TODO_SKIP_UPDATE_CHECK
$previousSmokeTrace = $env:WOO_TODO_SMOKE_TRACE
$previousLocalAppData = $env:LOCALAPPDATA

try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    $env:LOCALAPPDATA = Join-Path $temporaryDirectory "local-app-data"
    $dataDirectory = Join-Path $env:LOCALAPPDATA "Woo Todo"
    $database = Join-Path $dataDirectory "woo-todo.sqlite3"
    $settingsPath = Join-Path $dataDirectory "settings.json"
    $env:WOO_TODO_SMOKE_TRACE = Join-Path $ArtifactDirectory "app-trace.txt"
    $env:WOO_TODO_SKIP_UPDATE_CHECK = "1"
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
            "0.1.14",
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
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State pending

    Toggle-FirstTaskCheckbox -List $taskList
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State completed
    Toggle-FirstTaskCheckbox -List $taskList
    Assert-TaskState -Inspector $inspector -Database $database -Title $taskTitle -State pending
    Add-Diagnostic "快速新增、勾选完成和取消完成验证通过"

    Select-SettingsSection -Main $main
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
    Assert-FloatingStyle -Floating $floating -Opacity 0.61 -ClickThrough $false
    Add-Diagnostic "透明度与鼠标穿透独立变化验证通过"

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
    Assert-Settings -Path $settingsPath -Opacity 0.61 -ClickThrough $false
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
    Add-Diagnostic "任务与设置重启持久化验证通过"

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
    $env:LOCALAPPDATA = $previousLocalAppData
    foreach ($process in @($secondary, $primary)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(5000) | Out-Null
        }
    }
    if ($null -ne $dataDirectory -and (Test-Path -LiteralPath $dataDirectory)) {
        Copy-Item -LiteralPath $dataDirectory -Destination $ArtifactDirectory -Recurse -Force
    }
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
