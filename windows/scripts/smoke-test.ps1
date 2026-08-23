# Woo Todo Windows smoke test script (development only).
# Bisect-style: checkpoints after every step.
param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class SmokeWin32 {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumChildWindows(IntPtr p, EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);

  public static IntPtr FindWindowByClass(uint target, string name) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid = 0;
      GetWindowThreadProcessId(h, out pid);
      if (pid == target) {
        var cls = new StringBuilder(256);
        GetClassName(h, cls, 256);
        if (cls.ToString() == name) { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static IntPtr FindChildByClass(IntPtr parent, string clsName) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(parent, delegate(IntPtr c, IntPtr l2) {
      var ccls = new StringBuilder(256);
      GetClassName(c, ccls, 256);
      if (ccls.ToString() == clsName) { found = c; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static int CountVisibleByClassAndText(IntPtr parent, string clsName, string exactText) {
    int count = 0;
    EnumChildWindows(parent, delegate(IntPtr c, IntPtr l2) {
      if (!IsWindowVisible(c)) return true;
      var ccls = new StringBuilder(256);
      GetClassName(c, ccls, 256);
      if (ccls.ToString() != clsName) return true;
      if (String.IsNullOrEmpty(exactText) || ReadText(c) == exactText) count++;
      return true;
    }, IntPtr.Zero);
    return count;
  }

  public static int CountVisibleReadonlyEdits(IntPtr parent) {
    int count = 0;
    EnumChildWindows(parent, delegate(IntPtr c, IntPtr l2) {
      if (!IsWindowVisible(c)) return true;
      var ccls = new StringBuilder(256);
      GetClassName(c, ccls, 256);
      if (ccls.ToString() == "Edit" && (GetWindowLong(c, -16) & 0x0800) != 0) count++;
      return true;
    }, IntPtr.Zero);
    return count;
  }

  public static string ReadText(IntPtr h) {
    var buf = new StringBuilder(8192);
    SendMessage(h, 0x000D, (IntPtr)8192, buf);
    return buf.ToString();
  }

  public static string DumpVisible(IntPtr parent) {
    var sb = new StringBuilder();
    EnumChildWindows(parent, delegate(IntPtr c, IntPtr l2) {
      if (!IsWindowVisible(c)) return true;
      var ccls = new StringBuilder(64);
      GetClassName(c, ccls, 64);
      string text = ReadText(c);
      if (text.Length > 90) text = text.Substring(0, 90) + "...(" + text.Length + ")";
      sb.AppendLine(ccls + " | " + text.Replace("\r", "\\r").Replace("\n", "\\n"));
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }

  public static void SwitchNav(IntPtr main, int index) {
    var nav = FindChildByClass(main, "ListBox");
    SendMessage(nav, 0x0186, (IntPtr)index, IntPtr.Zero);
    int wp = 100 | (1 << 16);
    PostMessage(main, 0x0111, (IntPtr)wp, nav);
  }
}
"@

function Assert-Smoke([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw "Smoke test failed: $Message"
  }
  Write-Output ("[ok] " + $Message)
}

function CheckAlive($label) {
  $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  Assert-Smoke ($null -ne $p) ("process alive: " + $label)
}

CheckAlive "start"

Start-Sleep -Seconds 75
CheckAlive "after 75s idle (past 60s timer)"

$main = [SmokeWin32]::FindWindowByClass($ProcessId, "WooTodo.Native.Main.v1")
Assert-Smoke ($main -ne [IntPtr]::Zero) "main window found"
[SmokeWin32]::ShowWindow($main, 9) | Out-Null
Start-Sleep -Milliseconds 400

[SmokeWin32]::SwitchNav($main, 5)
Start-Sleep -Milliseconds 900
CheckAlive "after nav history(5)"
Write-Output ([SmokeWin32]::DumpVisible($main))

[SmokeWin32]::SwitchNav($main, 7)
Start-Sleep -Milliseconds 900
CheckAlive "after nav display(7)"
Write-Output ([SmokeWin32]::DumpVisible($main))
$titleTokenMenu = [SmokeWin32]::GetDlgItem($main, 175)
$subtitleTokenMenu = [SmokeWin32]::GetDlgItem($main, 187)
$hasSeparateTokenMenus = $titleTokenMenu -ne [IntPtr]::Zero -and
  $subtitleTokenMenu -ne [IntPtr]::Zero -and
  [SmokeWin32]::IsWindowVisible($titleTokenMenu) -and
  [SmokeWin32]::IsWindowVisible($subtitleTokenMenu)
Assert-Smoke $hasSeparateTokenMenus "display page has separate title and subtitle token menus"
$desktopWidget = [SmokeWin32]::GetDlgItem($main, 124)
$hasDesktopWidget = $desktopWidget -ne [IntPtr]::Zero -and
  [SmokeWin32]::IsWindowVisible($desktopWidget)
Assert-Smoke $hasDesktopWidget "display page exposes desktop widget mode"

[SmokeWin32]::SwitchNav($main, 8)
Start-Sleep -Milliseconds 900
CheckAlive "after nav shortcuts(8)"
Write-Output ([SmokeWin32]::DumpVisible($main))
$hasSevenRecorders = [SmokeWin32]::CountVisibleByClassAndText($main, "Edit", $null) -eq 7
Assert-Smoke $hasSevenRecorders "shortcut page has seven recorder fields"
$allRecordersAreReadonly = [SmokeWin32]::CountVisibleReadonlyEdits($main) -eq 7
Assert-Smoke $allRecordersAreReadonly "all shortcut fields use recorder-only input"

Write-Output "--- post ID_TRAY_QUICK_ADD ---"
[SmokeWin32]::PostMessage($main, 0x0111, [IntPtr]402, [IntPtr]::Zero)
Start-Sleep -Milliseconds 1200
CheckAlive "after quick add"
$quickAdd = [SmokeWin32]::FindWindowByClass($ProcessId, "WooTodo.Native.QuickAdd.v1")
Assert-Smoke ($quickAdd -ne [IntPtr]::Zero) "quick add window opens"
$quickStatus = [SmokeWin32]::GetDlgItem($quickAdd, 355)
$hasQuickSummary = $quickStatus -ne [IntPtr]::Zero -and
  [SmokeWin32]::IsWindowVisible($quickStatus) -and
  -not [string]::IsNullOrWhiteSpace([SmokeWin32]::ReadText($quickStatus))
Assert-Smoke $hasQuickSummary "quick add summary is visible"
$floating = [SmokeWin32]::FindWindowByClass($ProcessId, "WooTodo.Native.Float.v1")
Assert-Smoke (-not [SmokeWin32]::IsWindowEnabled($main)) "quick add disables main window"
$floatingIsDisabled = $floating -ne [IntPtr]::Zero -and
  -not [SmokeWin32]::IsWindowEnabled($floating)
Assert-Smoke $floatingIsDisabled "quick add disables floating board"
[SmokeWin32]::PostMessage($quickAdd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 800
Assert-Smoke ([SmokeWin32]::IsWindowEnabled($main)) "closing quick add restores main window"
Assert-Smoke ([SmokeWin32]::IsWindowEnabled($floating)) "closing quick add restores floating board"

Write-Output "--- post ID_ADD ---"
[SmokeWin32]::PostMessage($main, 0x0111, [IntPtr]110, [IntPtr]::Zero)
Start-Sleep -Milliseconds 1200
CheckAlive "after ID_ADD"
$editor = [SmokeWin32]::FindWindowByClass($ProcessId, "WooTodo.Native.Editor.v1")
Assert-Smoke ($editor -ne [IntPtr]::Zero) "full task editor opens"
Write-Output ([SmokeWin32]::DumpVisible($editor))
[SmokeWin32]::PostMessage($editor, 0x0111, [IntPtr]2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 800
CheckAlive "after editor IDCANCEL"
