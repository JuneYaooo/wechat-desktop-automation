param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'search', 'open', 'capture', 'screen', 'click', 'watch', 'draft', 'send', 'release')]
    [string]$Command,

    [string]$Query,
    [string]$Message,
    [string]$ConfirmSend,
    [string]$AuthorizationId,
    [string]$ClickX,
    [string]$ClickY,
    [string]$Label,
    [ValidateRange(10, 3600)]
    [int]$WatchSeconds = 300,
    [ValidateRange(5, 300)]
    [int]$IntervalSeconds = 10,
    [string]$OutputDir = (Join-Path $env:TEMP 'codex-wechat-automation')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WeChatNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint source, uint target, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
'@

$script:MouseLeftDown = 0x0002
$script:MouseLeftUp = 0x0004
$script:KeyUp = 0x0002
$script:WmChar = 0x0102
$script:VkControl = 0x11
$script:StatePath = Join-Path $env:TEMP 'codex-wechat-automation-state.json'
$script:AuditPath = Join-Path $env:TEMP 'codex-wechat-automation-audit.jsonl'

function Get-WeChatWindow {
    $matches = [System.Collections.Generic.List[object]]::new()
    $callback = [WeChatNative+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if (-not [WeChatNative]::IsWindowVisible($hWnd)) { return $true }
        [uint32]$processId = 0
        [void][WeChatNative]::GetWindowThreadProcessId($hWnd, [ref]$processId)
        if ($processId -eq 0) { return $true }
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            $name = $process.ProcessName
        } catch { return $true }
        if ($name -in @('Weixin', 'WeChat', 'WeChatAppEx')) {
            $title = [Text.StringBuilder]::new(512)
            $className = [Text.StringBuilder]::new(256)
            [void][WeChatNative]::GetWindowText($hWnd, $title, $title.Capacity)
            [void][WeChatNative]::GetClassName($hWnd, $className, $className.Capacity)
            $matches.Add([pscustomobject]@{
                Handle = $hWnd
                ProcessId = $processId
                ProcessName = $name
                Title = $title.ToString()
                ClassName = $className.ToString()
            })
        }
        return $true
    }
    [void][WeChatNative]::EnumWindows($callback, [IntPtr]::Zero)
    $preferred = $matches | Where-Object { $_.ClassName -match 'Qt|WeChat|Weixin' } | Select-Object -First 1
    if (-not $preferred) { $preferred = $matches | Select-Object -First 1 }
    return $preferred
}

function Test-SameProcessWindow([IntPtr]$ReferenceHandle, [IntPtr]$ForegroundHandle) {
    if ($ReferenceHandle -eq $ForegroundHandle) { return $true }
    [uint32]$referencePid = 0
    [void][WeChatNative]::GetWindowThreadProcessId($ReferenceHandle, [ref]$referencePid)
    [uint32]$foregroundPid = 0
    [void][WeChatNative]::GetWindowThreadProcessId($ForegroundHandle, [ref]$foregroundPid)
    return ($referencePid -ne 0 -and $referencePid -eq $foregroundPid)
}

function Set-WeChatForeground([IntPtr]$Handle) {
    [void][WeChatNative]::ShowWindow($Handle, 9)
    $foreground = [WeChatNative]::GetForegroundWindow()
    [uint32]$ignoredPid = 0
    $foregroundThread = [WeChatNative]::GetWindowThreadProcessId($foreground, [ref]$ignoredPid)
    $targetThread = [WeChatNative]::GetWindowThreadProcessId($Handle, [ref]$ignoredPid)
    $currentThread = [WeChatNative]::GetCurrentThreadId()
    $attachedForeground = $false
    $attachedTarget = $false
    try {
        if ($foregroundThread -and $foregroundThread -ne $currentThread) {
            $attachedForeground = [WeChatNative]::AttachThreadInput($currentThread, $foregroundThread, $true)
        }
        if ($targetThread -and $targetThread -ne $currentThread) {
            $attachedTarget = [WeChatNative]::AttachThreadInput($currentThread, $targetThread, $true)
        }
        [void][WeChatNative]::BringWindowToTop($Handle)
        [void][WeChatNative]::SetForegroundWindow($Handle)
        [WeChatNative]::SwitchToThisWindow($Handle, $true)
    } finally {
        if ($attachedTarget) { [void][WeChatNative]::AttachThreadInput($currentThread, $targetThread, $false) }
        if ($attachedForeground) { [void][WeChatNative]::AttachThreadInput($currentThread, $foregroundThread, $false) }
    }
    Start-Sleep -Milliseconds 700
    $activated = $false
    foreach ($attempt in 1..3) {
        if (Test-SameProcessWindow $Handle ([WeChatNative]::GetForegroundWindow())) { $activated = $true; break }
        [void][WeChatNative]::BringWindowToTop($Handle)
        [void][WeChatNative]::SetForegroundWindow($Handle)
        [WeChatNative]::SwitchToThisWindow($Handle, $true)
        Start-Sleep -Milliseconds 600
    }
    if (-not $activated) {
        throw 'Could not activate the WeChat window. The user is likely interacting with another application; retry shortly or ask them to focus WeChat.'
    }
}

function Get-WindowRect([IntPtr]$Handle) {
    $rect = New-Object WeChatNative+RECT
    if (-not [WeChatNative]::GetWindowRect($Handle, [ref]$rect)) { throw 'Could not read WeChat window bounds.' }
    return $rect
}

function Invoke-Click([int]$X, [int]$Y) {
    [void][WeChatNative]::SetCursorPos($X, $Y)
    [WeChatNative]::mouse_event($script:MouseLeftDown, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 75
    [WeChatNative]::mouse_event($script:MouseLeftUp, 0, 0, 0, [UIntPtr]::Zero)
}

function Release-InputState {
    [WeChatNative]::mouse_event($script:MouseLeftUp, 0, 0, 0, [UIntPtr]::Zero)
    [WeChatNative]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
    foreach ($key in @(0x11, 0xA2, 0xA3, 0x10, 0xA0, 0xA1, 0x12, 0xA4, 0xA5, 0x41, 0x28, 0x22, 0x23)) {
        [WeChatNative]::keybd_event([byte]$key, 0, $script:KeyUp, [UIntPtr]::Zero)
    }
}

function Invoke-CtrlA {
    [WeChatNative]::keybd_event([byte]$script:VkControl, 0, 0, [UIntPtr]::Zero)
    [WeChatNative]::keybd_event([byte]0x41, 0, 0, [UIntPtr]::Zero)
    [WeChatNative]::keybd_event([byte]0x41, 0, $script:KeyUp, [UIntPtr]::Zero)
    [WeChatNative]::keybd_event([byte]$script:VkControl, 0, $script:KeyUp, [UIntPtr]::Zero)
}

function Send-UnicodeText([IntPtr]$Handle, [string]$Text) {
    foreach ($character in $Text.ToCharArray()) {
        [void][WeChatNative]::SendMessage($Handle, $script:WmChar, [IntPtr][int]$character, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 65
    }
}

function Save-WindowScreenshot([IntPtr]$Handle, [string]$Label) {
    if (-not (Test-Path -LiteralPath $OutputDir)) { [void](New-Item -ItemType Directory -Path $OutputDir -Force) }
    $rect = Get-WindowRect $Handle
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { throw 'WeChat window has invalid bounds.' }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $path = Join-Path $OutputDir ("wechat-$Label-$timestamp.png")
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $hdc = $graphics.GetHdc()
        try {
            $rendered = [WeChatNative]::PrintWindow($Handle, $hdc, 2)
        } finally {
            $graphics.ReleaseHdc($hdc)
        }
        if (-not $rendered) {
            $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        }
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return $path
}

function Get-VirtualScreenBounds {
    $originX = [WeChatNative]::GetSystemMetrics(76)
    $originY = [WeChatNative]::GetSystemMetrics(77)
    $width = [WeChatNative]::GetSystemMetrics(78)
    $height = [WeChatNative]::GetSystemMetrics(79)
    if ($width -le 0 -or $height -le 0) { throw 'Could not read the virtual screen bounds.' }
    [pscustomobject]@{ X = $originX; Y = $originY; Width = $width; Height = $height }
}

function Save-ScreenScreenshot([string]$Label) {
    if (-not (Test-Path -LiteralPath $OutputDir)) { [void](New-Item -ItemType Directory -Path $OutputDir -Force) }
    $bounds = Get-VirtualScreenBounds
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $path = Join-Path $OutputDir ("wechat-screen-$Label-$timestamp.png")
    $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bitmap.Size)
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return $path
}

function Get-WeChatSurfaceWindows {
    $surfaces = [System.Collections.Generic.List[object]]::new()
    $callback = [WeChatNative+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if (-not [WeChatNative]::IsWindowVisible($hWnd)) { return $true }
        [uint32]$processId = 0
        [void][WeChatNative]::GetWindowThreadProcessId($hWnd, [ref]$processId)
        if ($processId -eq 0) { return $true }
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            $name = $process.ProcessName
        } catch { return $true }
        if ($name -notin @('Weixin', 'WeChat', 'WeChatAppEx')) { return $true }
        $rect = New-Object WeChatNative+RECT
        if (-not [WeChatNative]::GetWindowRect($hWnd, [ref]$rect)) { return $true }
        if (($rect.Right - $rect.Left) -le 0 -or ($rect.Bottom - $rect.Top) -le 0) { return $true }
        $surfaces.Add([pscustomobject]@{ Handle = $hWnd; Rect = $rect })
        return $true
    }
    [void][WeChatNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $surfaces
}

function Assert-ClickInsideWeChat([int]$PixelX, [int]$PixelY) {
    $bounds = Get-VirtualScreenBounds
    $screenX = $bounds.X + $PixelX
    $screenY = $bounds.Y + $PixelY
    foreach ($surface in (Get-WeChatSurfaceWindows)) {
        $r = $surface.Rect
        if ($screenX -ge $r.Left -and $screenX -lt $r.Right -and $screenY -ge $r.Top -and $screenY -lt $r.Bottom) {
            return $surface
        }
    }
    throw 'Target coordinates are outside every visible WeChat window; refusing to click another application.'
}

function Invoke-ScreenPixelClick([int]$PixelX, [int]$PixelY) {
    [void](Assert-ClickInsideWeChat $PixelX $PixelY)
    $bounds = Get-VirtualScreenBounds
    Invoke-Click ($bounds.X + $PixelX) ($bounds.Y + $PixelY)
}

function Resolve-ClickPoint {
    if ([string]::IsNullOrWhiteSpace($ClickX) -or [string]::IsNullOrWhiteSpace($ClickY)) { return $null }
    try {
        $x = [int]$ClickX
        $y = [int]$ClickY
    } catch { throw '-ClickX/-ClickY must be integer pixel positions.' }
    if ($x -lt 0 -or $y -lt 0) { throw '-ClickX/-ClickY must be non-negative pixel positions.' }
    [pscustomobject]@{ X = $x; Y = $y }
}

function Write-Audit([string]$Action, [string]$Mode, [string]$RuleId, [string]$Screenshot) {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        action = $Action
        authorization_mode = $Mode
        rule_id = $RuleId
        screenshot = $Screenshot
    }
    ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $script:AuditPath -Encoding UTF8
}

function Write-State([hashtable]$Updates) {
    $state = @{}
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $existing = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            foreach ($property in $existing.PSObject.Properties) { $state[$property.Name] = $property.Value }
        } catch { $state = @{} }
    }
    foreach ($key in $Updates.Keys) { $state[$key] = $Updates[$key] }
    $state | ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
    try { return Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json } catch { return $null }
}

try { [void][WeChatNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}

if ($Command -eq 'release') {
    Release-InputState
    [pscustomobject]@{ ok = $true; command = 'release'; input_state_released = $true } | ConvertTo-Json
    exit 0
}

$window = Get-WeChatWindow
if (-not $window) { throw 'No visible WeChat window was found. Open and sign in to WeChat first.' }
$handle = [IntPtr]$window.Handle

if ($Command -eq 'status') {
    $rect = Get-WindowRect $handle
    $screen = Get-VirtualScreenBounds
    [pscustomobject]@{
        ok = $true
        command = 'status'
        hwnd = $handle.ToInt64()
        process = $window.ProcessName
        title = $window.Title
        class_name = $window.ClassName
        rect = @($rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
        virtual_screen = @($screen.X, $screen.Y, $screen.Width, $screen.Height)
    } | ConvertTo-Json -Depth 3
    exit 0
}

if ($Command -eq 'watch') {
    if (-not (Test-Path -LiteralPath $OutputDir)) { [void](New-Item -ItemType Directory -Path $OutputDir -Force) }
    $startedAt = [DateTimeOffset]::Now
    $deadline = $startedAt.AddSeconds($WatchSeconds)
    $events = [System.Collections.Generic.List[object]]::new()
    $baselinePath = Save-WindowScreenshot $handle 'watch-baseline'
    $previousHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash
    while ([DateTimeOffset]::Now -lt $deadline) {
        Start-Sleep -Seconds $IntervalSeconds
        $candidatePath = Save-WindowScreenshot $handle 'watch-sample'
        $candidateHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
        if ($candidateHash -ne $previousHash) {
            $events.Add([pscustomobject]@{
                observed_at = (Get-Date).ToString('o')
                screenshot = $candidatePath
                sha256 = $candidateHash
            })
            $previousHash = $candidateHash
        } else {
            Remove-Item -LiteralPath $candidatePath -Force
        }
    }
    Write-Audit 'watch' 'bounded-monitor' $AuthorizationId $baselinePath
    [pscustomobject]@{
        ok = $true
        command = 'watch'
        started_at = $startedAt.ToString('o')
        ended_at = ([DateTimeOffset]::Now).ToString('o')
        requested_seconds = $WatchSeconds
        interval_seconds = $IntervalSeconds
        baseline_screenshot = $baselinePath
        change_count = $events.Count
        events = $events
        audit_log = $script:AuditPath
    } | ConvertTo-Json -Depth 5
    exit 0
}

try {
    Set-WeChatForeground $handle
    $rect = Get-WindowRect $handle
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top

    switch ($Command) {
        'capture' {
            $path = Save-WindowScreenshot $handle 'capture'
            [pscustomobject]@{ ok = $true; command = 'capture'; screenshot = $path } | ConvertTo-Json
        }
        { $_ -in @('search', 'open') } {
            if ([string]::IsNullOrWhiteSpace($Query)) { throw '-Query is required for search/open.' }
            Invoke-Click ($rect.Left + 200) ($rect.Top + 70)
            Start-Sleep -Milliseconds 350
            Invoke-CtrlA
            Start-Sleep -Milliseconds 150
            Send-UnicodeText $handle $Query
            Start-Sleep -Milliseconds 1500
            $searchPath = Save-ScreenScreenshot 'search'
            if ($Command -eq 'search') {
                [pscustomobject]@{
                    ok = $true
                    command = 'search'
                    query = $Query
                    screenshot = $searchPath
                    note = 'WeChat 4.x shows search results in a separate popup window, visible only in this full-screen capture. Identify the exact result row, then run open again with -ClickX/-ClickY set to that row pixel position in this screenshot.'
                } | ConvertTo-Json
            } else {
                $clickPoint = Resolve-ClickPoint
                if (-not $clickPoint) {
                    throw 'WeChat 4.x renders search results in a separate popup, so blind-clicking a fixed offset mis-hits (it lands on the Sou-Yi-Sou web panel). Inspect the search screenshot first, then call open again with -ClickX and -ClickY pointing at the exact result row in that full-screen capture.'
                }
                Invoke-ScreenPixelClick $clickPoint.X $clickPoint.Y
                Start-Sleep -Milliseconds 1000
                $chatPath = Save-WindowScreenshot $handle 'opened-chat'
                [pscustomobject]@{
                    ok = $true
                    command = 'open'
                    query = $Query
                    click = @($clickPoint.X, $clickPoint.Y)
                    search_screenshot = $searchPath
                    chat_screenshot = $chatPath
                } | ConvertTo-Json
            }
        }
        'screen' {
            $path = Save-ScreenScreenshot 'view'
            [pscustomobject]@{ ok = $true; command = 'screen'; screenshot = $path } | ConvertTo-Json
        }
        'click' {
            $clickPoint = Resolve-ClickPoint
            if (-not $clickPoint) { throw 'click requires -ClickX and -ClickY (pixel positions in a full-screen capture).' }
            if ([string]::IsNullOrWhiteSpace($Label)) { $Label = 'manual-click' }
            Set-WeChatForeground $handle
            [void](Assert-ClickInsideWeChat $clickPoint.X $clickPoint.Y)
            Invoke-ScreenPixelClick $clickPoint.X $clickPoint.Y
            Start-Sleep -Milliseconds 1200
            $path = Save-ScreenScreenshot 'click'
            Write-Audit 'click' 'manual' $Label $path
            [pscustomobject]@{
                ok = $true
                command = 'click'
                label = $Label
                click = @($clickPoint.X, $clickPoint.Y)
                screenshot = $path
            } | ConvertTo-Json
        }
        'draft' {
            if ([string]::IsNullOrWhiteSpace($Message)) { throw '-Message is required for draft.' }
            Invoke-Click ($rect.Left + [int]($width * 0.68)) ($rect.Top + [int]($height * 0.72))
            Start-Sleep -Milliseconds 300
            Invoke-CtrlA
            Start-Sleep -Milliseconds 150
            Send-UnicodeText $handle $Message
            Start-Sleep -Milliseconds 500
            $path = Save-WindowScreenshot $handle 'draft-preview'
            Write-State @{ draft_at = (Get-Date).ToString('o'); draft_hwnd = $handle.ToInt64(); draft_length = $Message.Length }
            [pscustomobject]@{ ok = $true; command = 'draft'; message_length = $Message.Length; screenshot = $path; sent = $false } | ConvertTo-Json
        }
        'send' {
            $manualAuthorized = $ConfirmSend -ceq 'SEND'
            $ruleAuthorized = -not [string]::IsNullOrWhiteSpace($AuthorizationId)
            if (-not $manualAuthorized -and -not $ruleAuthorized) {
                throw 'Sending requires either -ConfirmSend SEND or a user-approved -AuthorizationId.'
            }
            $state = Read-State
            if (-not $state -or -not $state.draft_at) { throw 'No recent draft was recorded. Run draft and inspect its preview first.' }
            $draftAt = [DateTimeOffset]::Parse([string]$state.draft_at)
            if (([DateTimeOffset]::Now - $draftAt).TotalMinutes -gt 10) { throw 'The draft is older than 10 minutes. Draft and preview it again.' }
            if ([Int64]$state.draft_hwnd -ne $handle.ToInt64()) { throw 'The active WeChat window differs from the drafted window.' }
            if ($state.PSObject.Properties.Name -contains 'last_send_at') {
                $lastSendAt = [DateTimeOffset]::Parse([string]$state.last_send_at)
                $remaining = 15 - ([DateTimeOffset]::Now - $lastSendAt).TotalSeconds
                if ($remaining -gt 0) { throw ("Cooldown active. Wait at least {0:N0} more seconds." -f $remaining) }
            }
            Invoke-Click ($rect.Right - 65) ($rect.Bottom - 50)
            Start-Sleep -Milliseconds 1200
            $path = Save-WindowScreenshot $handle 'send-result'
            Write-State @{ last_send_at = (Get-Date).ToString('o'); draft_at = $null; draft_hwnd = $null; draft_length = $null }
            $mode = if ($ruleAuthorized) { 'rule' } else { 'manual' }
            Write-Audit 'send' $mode $AuthorizationId $path
            [pscustomobject]@{
                ok = $true
                command = 'send'
                authorization_mode = $mode
                authorization_id = $AuthorizationId
                screenshot = $path
                clicked_send = $true
                audit_log = $script:AuditPath
            } | ConvertTo-Json
        }
    }
} finally {
    Release-InputState
}
