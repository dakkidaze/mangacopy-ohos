#Requires -Version 5.1
<#
.SYNOPSIS
  Android 阅读器手势诊断半自动真机测试（阶段 1 日志采集）。

.PARAMETER DryRun
  无真机验证：检查场景定义、输出文件名、CSV 表头与 summary 统计逻辑一致性，不连接设备、不构建。

.PARAMETER ResumeOutputDir
  续跑已有 test_output/android_* 目录：跳过构建/安装，自动跳过已完成场景，从 CSV 进度继续未完成的试次/组。

.PARAMETER FinalizeOutputDir
  仅根据已有 CSV/日志生成 summary.md 与 log_quality_check.txt，不连接设备、不执行场景。

.PARAMETER ExperimentIvBypass
  IV bypass 单变量实验：输出到 android_iv_experiment_*，构建注入 READER_GESTURE_EXPERIMENT_BYPASS_IV_WHEN_UNZOOMED=true，仅跑 E-A/E-B/E-Z。
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ResumeOutputDir,
    [string]$FinalizeOutputDir,
    [switch]$ExperimentIvBypass
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 全局状态
# ---------------------------------------------------------------------------

$Script:OwnedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$Script:OutputDir = $null
$Script:SelectedDeviceId = $null
$Script:ExecutedScenarios = [System.Collections.Generic.List[object]]::new()
$Script:StopRequested = $false
$Script:SummaryState = @{
    Status          = 'running'
    FailReason      = ''
    AnalyzeWarnings = @()
    AnalyzeInfos    = @()
    TestPassed      = $false
    BuildPassed     = $false
    InstallPassed   = $false
    LaunchPassed    = $false
    ScenarioResults = @{}
    CsvStats        = @{}
    Environment     = @{}
}

$Script:ExperimentIvBypass = $false
$Script:TestRunId = $null
$Script:MarkerAction = 'top.fumiama.copymanga_flutter.READER_GESTURE_MARKER'

function Send-TestActionMarker {
    param(
        [string]$DeviceId,
        [string]$PackageId,
        [string]$Phase,
        [string]$ScenarioId,
        [string]$ActionId,
        [string]$ActionPhase = 'singleSwipe'
    )
    if (-not $Script:TestRunId) {
        $Script:TestRunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    }
    $utc = (Get-Date).ToUniversalTime().ToString('o')
    $args = @(
        '-s', $DeviceId, 'shell', 'am', 'broadcast',
        '-a', $Script:MarkerAction,
        '--es', 'phase', $Phase,
        '--es', 'testRunId', $Script:TestRunId,
        '--es', 'scenarioId', $ScenarioId,
        '--es', 'actionId', $ActionId,
        '--es', 'actionPhase', $ActionPhase,
        '--es', 'timestamp', $utc
    )
    Invoke-ExternalCommand -FilePath 'adb' -ArgumentList $args -AllowFailure | Out-Null
}

function Export-ReaderGestureJsonl {
    param([string]$DeviceId, [string]$OutputDir, [string]$PackageId)
    $rel = 'app_flutter/reader_gesture_diag/events.jsonl'
    $local = Join-Path $OutputDir 'reader_gesture_events.jsonl'
    $pull = Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @(
        '-s', $DeviceId, 'exec-out', 'run-as', $PackageId, 'cat', $rel
    ) -AllowFailure
    if ($pull.ExitCode -eq 0 -and $pull.StdOut) {
        Write-TextFile -Path $local -Content $pull.StdOut
        Write-Status "已导出 JSONL: $local"
    } else {
        Write-Warning "JSONL 导出失败（run-as cat）。可手动: adb exec-out run-as $PackageId cat $rel"
    }
}

$Script:ExperimentScenarios = @(
    (New-ScenarioDefinition `
        -Key 'e_a_slow_drag' -Letter 'E-A' -Title '实验-慢速长拖' `
        -FilePrefix 'scenario_e_a_slow_drag' -Type 'slow_drag' -RepeatCount 5 `
        -Setup @('r2l=true（匹配基线）', '实验模式：IV bypass when unzoomed') `
        -Instructions @('慢速长拖 5 次，每次 marker 同步') `
        -CsvHeader 'trial,page_turn_success,noticeable_lag,menu_accidental,action_start,action_end,notes,status')
    (New-ScenarioDefinition `
        -Key 'e_b_fast_swipe' -Letter 'E-B' -Title '实验-快速短划' `
        -FilePrefix 'scenario_e_b_fast_swipe' -Type 'fast_swipe_single' -RepeatCount 20 `
        -Setup @('r2l=true', '每次独立 swipe，精确 marker') `
        -Instructions @('20 次独立快滑，每次动作前后 marker') `
        -CsvHeader 'trial,page_turn_success,snap_back,not_recognized,menu_accidental,action_start,action_end,notes,status')
    (New-ScenarioDefinition `
        -Key 'e_z_zoom' -Letter 'E-Z' -Title '实验-缩放能力检查' `
        -FilePrefix 'scenario_e_z_zoom' -Type 'zoom_check' -RepeatCount 4 `
        -Setup @('验证实验模式对缩放/平移的影响') `
        -Instructions @('4 组：捏合3次、双击3次、放大平移3次、缩回后横滑3次') `
        -CsvHeader 'trial,check_type,success,notes,action_start,action_end,status')
)

$Script:CommonSetup = @(
)
    '阅读模式：横向（readMode=h）'
    '阅读方向：r2l=false（左滑下一页 / 右滑上一页，非日漫翻页方向）'
    '图片未放大（1.0x，未双击或捏合缩放）'
    '仅使用真实手指，不使用音量键、点击区域或 ADB 模拟 swipe'
)

function New-ScenarioDefinition {
    param(
        [string]$Key,
        [string]$Letter,
        [string]$Title,
        [string]$FilePrefix,
        [string]$Type,
        [int]$RepeatCount = 1,
        [string[]]$Setup,
        [string[]]$Instructions,
        [string]$CsvHeader,
        [bool]$Optional = $false
    )
    return [ordered]@{
        Key           = $Key
        Letter        = $Letter
        Title         = $Title
        FilePrefix    = $FilePrefix
        Type          = $Type
        RepeatCount   = $RepeatCount
        Setup         = $Setup
        Instructions  = $Instructions
        CsvHeader     = $CsvHeader
        Optional      = $Optional
    }
}

$Script:MandatoryScenarios = @(
    (New-ScenarioDefinition `
        -Key 'a_slow_drag' -Letter 'A' -Title '慢速长拖' `
        -FilePrefix 'scenario_a_slow_drag' -Type 'slow_drag' -RepeatCount 5 `
        -Setup @(
            '位置：章节内部（非首尾页）'
            '手势：单指慢速长距离横向拖动后松手'
        ) `
        -Instructions @(
            '每次动作：单指按住屏幕，缓慢拖动约半屏至全屏宽度，松手。'
            '共执行 5 次，每次动作前倒计时 3 秒，完成后按 Enter。'
        ) `
        -CsvHeader 'trial,page_turn_success,noticeable_lag,menu_accidental,action_start,action_end,notes,status')
    (New-ScenarioDefinition `
        -Key 'b_fast_swipe' -Letter 'B' -Title '快速短划' `
        -FilePrefix 'scenario_b_fast_swipe' -Type 'fast_swipe' -RepeatCount 10 `
        -Setup @(
            '位置：章节内部（非首尾页）'
            '手势：单指快速短距离横向甩滑'
        ) `
        -Instructions @(
            '每次动作：单指快速短划（类似轻甩），距离不必很长，重点是速度快。'
            '共执行 10 次；每次动作之间至少等待 1 秒，避免前一次 ballistic 动画干扰。'
            '每次动作前倒计时 3 秒，完成后按 Enter。'
        ) `
        -CsvHeader 'trial,page_turn_success,snap_back,not_recognized,menu_accidental,action_start,action_end,notes,status')
    (New-ScenarioDefinition `
        -Key 'c_edge_next' -Letter 'C' -Title '章节尾页双滑进入下一章' `
        -FilePrefix 'scenario_c_edge_next' -Type 'edge_next' -RepeatCount 5 `
        -Setup @(
            '位置：章节最后一页'
            '前提：存在下一章节'
            '手势：两次独立、同向、完整的 swipe'
        ) `
        -Instructions @(
            '每组含两次独立 swipe，手指完全抬起后再做第二次。'
            '共 5 组；每组开始前至少等待 4 秒。'
            '若换章成功，请手动返回合适的章节尾页，输入 ready 后继续下一组。'
        ) `
        -CsvHeader 'group,first_swipe_hint_seen,second_swipe_chapter_changed,duplicate_chapter_change,skipped_chapter,group_start,group_end,notes,status')
    (New-ScenarioDefinition `
        -Key 'd_multitouch' -Letter 'D' -Title '双指干扰' `
        -FilePrefix 'scenario_d_multitouch' -Type 'multitouch' -RepeatCount 5 `
        -Setup @(
            '位置：章节内部'
            '手势：双指轻触 → 松开 → 等待 → 单指翻页'
        ) `
        -Instructions @(
            '每次测试步骤：'
            '  1) 双指同时轻触阅读区域（不要明显缩放）'
            '  2) 双指全部松开'
            '  3) 等待 1 秒'
            '  4) 单指正常横向翻页'
            '共 5 次；每步完成后按 Enter；每次测试前倒计时 3 秒。'
        ) `
        -CsvHeader 'trial,two_finger_touch_done,post_multitouch_page_turn_success,felt_locked,needed_retouch,action_start,action_end,notes,status')
)

$Script:OptionalScenarioDefinitions = @(
    (New-ScenarioDefinition `
        -Key 'e_edge_previous' -Letter 'E' -Title '章节首页双滑进入上一章（可选）' `
        -FilePrefix 'scenario_e_edge_previous' -Type 'edge_previous' -RepeatCount 3 `
        -Setup @(
            '位置：章节第一页'
            '前提：存在上一章节'
            '手势：两次独立、同向、完整的 swipe'
        ) `
        -Instructions @(
            '每组两次独立 swipe，共 3 组。'
            '记录首次提示、第二次换章、重复换章或跳章。'
        ) `
        -CsvHeader 'group,first_swipe_hint_seen,second_swipe_chapter_changed,duplicate_chapter_change,skipped_chapter,group_start,group_end,notes,status' `
        -Optional $true)
    (New-ScenarioDefinition `
        -Key 'f_light_deep' -Letter 'F' -Title '轻滑与深滑对照（可选）' `
        -FilePrefix 'scenario_f_light_deep' -Type 'light_deep' -RepeatCount 6 `
        -Setup @(
            '位置：章节内部'
            '说明：轻滑=短距离、低力度、较快松手；深滑=长距离、拖动感明显、滑过较大区域'
            '主观轻/深仅作标签；精确分析以 ReaderGesture 中 dx、duration、averageVelocity 为准'
        ) `
        -Instructions @(
            '交替或分组执行轻滑与深滑，各至少 3 次。'
            '结果与场景 A/B 分开保存；不要将其当作精确速度或距离测量。'
        ) `
        -CsvHeader 'trial,swipe_style,page_turn_success,snap_back,not_recognized,menu_accidental,action_start,action_end,notes,status' `
        -Optional $true)
)

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

function Write-Status([string]$Message) {
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Message"
}

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Append-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
}

function Escape-CsvField([string]$Value) {
    if ($null -eq $Value) { return '' }
    $v = [string]$Value
    if ($v -match '[",\r\n]') { return '"' + ($v -replace '"', '""') + '"' }
    return $v
}

function Write-CsvRow {
    param([string]$Path, [string[]]$Fields)
    $line = (($Fields | ForEach-Object { Escape-CsvField $_ }) -join ',') + "`n"
    Append-TextFile -Path $Path -Content $line
}

function Initialize-Csv {
    param([string]$Path, [string]$Header)
    if (-not (Test-Path $Path)) {
        Write-TextFile -Path $Path -Content ($Header + "`n")
    }
}

function Read-YesNo {
    param([string]$Prompt)
    while ($true) {
        $ans = (Read-Host $Prompt).Trim().ToLowerInvariant()
        if ($ans -in @('y', 'yes', '是', '1')) { return 'yes' }
        if ($ans -in @('n', 'no', '否', '0')) { return 'no' }
        if ($ans -eq 'quit') { return 'quit' }
        if ($ans -eq 'skip') { return 'skip' }
        Write-Host '请输入 y/n（或 yes/no）；也可输入 skip / quit。'
    }
}

function Read-UserFlowCommand {
    param([string]$Prompt)
    while ($true) {
        $ans = (Read-Host $Prompt).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($ans)) { return 'continue' }
        if ($ans -in @('retry', 'r')) { return 'retry' }
        if ($ans -in @('skip', 's')) { return 'skip' }
        if ($ans -in @('quit', 'q')) { return 'quit' }
        if ($ans -eq 'ready') { return 'ready' }
        return 'continue'
    }
}

function Invoke-ActionCountdown {
    param([int]$Seconds = 3)
    for ($i = $Seconds; $i -ge 1; $i--) {
        Write-Host "  倒计时 $i ..."
        Start-Sleep -Seconds 1
    }
}

$Script:ToolPaths = @{}

function Initialize-RequiredTools {
    param([string]$ProjectRoot)

    $localProps = Join-Path $ProjectRoot 'android\local.properties'
    if (Test-Path $localProps) {
        foreach ($line in Get-Content $localProps -Encoding UTF8) {
            if ($line -match '^flutter\.sdk=(.+)$') {
                $flutterSdk = $matches[1].Trim() -replace '\\\\', '\'
                $flutterBat = Join-Path $flutterSdk 'bin\flutter.bat'
                if (Test-Path $flutterBat) { $Script:ToolPaths['flutter'] = $flutterBat }
            }
            if ($line -match '^sdk\.dir=(.+)$') {
                $sdkDir = $matches[1].Trim() -replace '\\\\', '\'
                $adbExe = Join-Path $sdkDir 'platform-tools\adb.exe'
                if (Test-Path $adbExe) { $Script:ToolPaths['adb'] = $adbExe }
            }
        }
    }

    foreach ($tool in @('flutter', 'adb', 'git')) {
        if ($Script:ToolPaths.ContainsKey($tool)) { continue }
        $resolved = Get-Command $tool -ErrorAction SilentlyContinue
        if ($resolved -and $resolved.Source) {
            $Script:ToolPaths[$tool] = $resolved.Source
        }
    }

    if (-not $Script:ToolPaths.ContainsKey('adb')) {
        $adbCandidates = @(
            'D:\Android\Sdk\platform-tools\adb.exe',
            'D:\android-sdk\platform-tools\adb.exe',
            'D:\Sdk\platform-tools\adb.exe',
            'D:\platform-tools\adb.exe'
        )
        foreach ($candidate in $adbCandidates) {
            if (Test-Path $candidate) {
                $Script:ToolPaths['adb'] = (Resolve-Path $candidate).Path
                break
            }
        }
    }
}

function Get-ToolExecutable {
    param([string]$Name)
    if ($Script:ToolPaths.ContainsKey($Name)) {
        return $Script:ToolPaths[$Name]
    }
    $resolved = Get-Command $Name -ErrorAction SilentlyContinue
    if ($resolved -and $resolved.Source) {
        $Script:ToolPaths[$Name] = $resolved.Source
        return $resolved.Source
    }
    return $null
}

function Test-CommandAvailable([string]$Name) {
    return [bool](Get-ToolExecutable $Name)
}

function New-ToolProcessStartInfo {
    param(
        [string]$ToolName,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    $exe = Get-ToolExecutable $ToolName
    if (-not $exe -or -not (Test-Path $exe)) {
        throw "找不到可执行文件: $ToolName（请确认 Flutter / Android SDK 已安装并在 PATH 中，或检查 android\local.properties）"
    }

    $argString = ''
    if ($ArgumentList) {
        $argString = ($ArgumentList | ForEach-Object {
            if ($_ -match '\s|"') { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
        }) -join ' '
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    if ($exe -match '\.(bat|cmd)$') {
        $psi.FileName = (Get-ToolExecutable 'cmd') 
        if (-not $psi.FileName) { $psi.FileName = "$env:ComSpec" }
        $psi.Arguments = if ($argString) { "/c `"$exe`" $argString" } else { "/c `"$exe`"" }
    } else {
        $psi.FileName = $exe
        $psi.Arguments = $argString
    }

    return $psi
}

function Invoke-ExternalCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = (Get-Location).Path,
        [string]$StdOutFile = $null,
        [string]$StdErrFile = $null,
        [int]$TimeoutSeconds = 0,
        [switch]$AllowFailure
    )

    $psi = New-ToolProcessStartInfo -ToolName $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stdoutBuilder = New-Object System.Text.StringBuilder
    $stderrBuilder = New-Object System.Text.StringBuilder
    $outEvent = $null
    $errEvent = $null

    try {
        [void]$proc.Start()

        $outEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
            if ($null -ne $EventArgs.Data) {
                [void]$Event.MessageData.AppendLine($EventArgs.Data)
            }
        } -MessageData $stdoutBuilder

        $errEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
            if ($null -ne $EventArgs.Data) {
                [void]$Event.MessageData.AppendLine($EventArgs.Data)
            }
        } -MessageData $stderrBuilder

        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
                throw "命令超时 (${TimeoutSeconds}s): $FilePath"
            }
        } else {
            $proc.WaitForExit()
        }
    } finally {
        foreach ($ev in @($outEvent, $errEvent)) {
            if ($null -eq $ev) { continue }
            Unregister-Event -SourceIdentifier $ev.Name -ErrorAction SilentlyContinue
            Remove-Job -Name $ev.Name -Force -ErrorAction SilentlyContinue
        }
    }

    $stdout = $stdoutBuilder.ToString()
    $stderr = $stderrBuilder.ToString()

    if ($StdOutFile) { Write-TextFile -Path $StdOutFile -Content $stdout }
    if ($StdErrFile) { Write-TextFile -Path $StdErrFile -Content $stderr }

    if (-not $AllowFailure -and $proc.ExitCode -ne 0) {
        throw "命令失败 (exit $($proc.ExitCode)): $FilePath $($psi.FileName) $($psi.Arguments)`n$stdout`n$stderr"
    }

    return [PSCustomObject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Complete-TestRun {
    param([string]$Status = 'completed')
    if (-not $Script:OutputDir) { return }
    try {
        Register-ScenariosFromOutput -OutputDir $Script:OutputDir
        $null = Compute-CsvStatistics -OutputDir $Script:OutputDir
        Invoke-LogQualityCheck -OutputDir $Script:OutputDir
    } catch {
        Write-Warning "生成统计/质检时出错: $_"
    }
    $Script:SummaryState.Status = $Status
    Write-SummaryMarkdown -Final
}

function Get-ScenarioProgress {
    param([hashtable]$Definition, [string]$OutputDir)
    $paths = Get-ScenarioPaths -Definition $Definition -OutputDir $OutputDir
    if (-not (Test-Path $paths.Csv)) {
        return @{ completed = 0; done = $false; hasData = $false }
    }
    $allRows = @(Import-Csv -Path $paths.Csv -Encoding UTF8)
    $completed = @($allRows | Where-Object { $_.status -eq 'completed' }).Count
    return @{
        completed = $completed
        done      = ($completed -ge $Definition.RepeatCount)
        hasData   = (@($allRows).Count -gt 0)
    }
}

function Register-ScenariosFromOutput {
    param([string]$OutputDir)
    $Script:ExecutedScenarios.Clear()
    foreach ($def in (@($Script:MandatoryScenarios) + @($Script:OptionalScenarioDefinitions))) {
        $progress = Get-ScenarioProgress -Definition $def -OutputDir $OutputDir
        if ($progress.hasData) {
            [void]$Script:ExecutedScenarios.Add($def)
        }
    }
}

function Show-ResumePlan {
    param([string]$OutputDir)
    Write-Host ''
    Write-Host '续跑计划（根据已有 CSV）：'
    foreach ($def in $Script:MandatoryScenarios) {
        $p = Get-ScenarioProgress -Definition $def -OutputDir $OutputDir
        $status = if ($p.done) { '已完成，将跳过' } elseif ($p.completed -gt 0) { "续跑 $($p.completed + 1)–$($def.RepeatCount) / 共 $($def.RepeatCount)" } else { '待执行' }
        Write-Host "  场景 $($def.Letter) $($def.Title): $status"
    }
    Write-Host ''
}

function Test-MapContainsKey {
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Contains($Key)
    }
    return $false
}

function Get-MapValue {
    param($Map, [string]$Key)
    if (-not (Test-MapContainsKey $Map $Key)) { return $null }
    return $Map[$Key]
}

function Find-ProjectRoot {
    param([string]$StartDir)
    $dir = (Resolve-Path $StartDir).Path
    while ($true) {
        if (Test-Path (Join-Path $dir 'pubspec.yaml')) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
}

function Mask-DeviceId([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return 'unknown' }
    if ($Id.Length -le 8) { return ('*' * $Id.Length) }
    return $Id.Substring(0, 4) + '...' + $Id.Substring($Id.Length - 4)
}

function Get-PubspecVersion {
    param([string]$ProjectRoot)
    $text = Get-Content (Join-Path $ProjectRoot 'pubspec.yaml') -Raw -Encoding UTF8
    if ($text -match '(?m)^version:\s*([\d.]+)\+(\d+)\s*$') {
        return @{ Name = $matches[1]; Code = $matches[2] }
    }
    return @{ Name = 'unknown'; Code = 'unknown' }
}

function Parse-FlutterToolVersions {
    param([string]$VersionText)
    $flutter = 'unknown'; $dart = 'unknown'
    if ($VersionText -match 'Flutter\s+(\S+)') { $flutter = $matches[1] }
    if ($VersionText -match 'Dart\s+(\S+)') { $dart = $matches[1] }
    return @{ Flutter = $flutter; Dart = $dart }
}

function Test-AnalyzeHasErrors { param([string[]]$Lines)
    foreach ($line in $Lines) { if ($line -match '^\s*error\s*-') { return $true } }
    return $false
}

function Get-AnalyzeIssueLines { param([string[]]$Lines, [string]$Severity)
    return @($Lines | Where-Object { $_ -match "^\s*$Severity\s*-" })
}

function Stop-OwnedProcesses {
    foreach ($proc in @($Script:OwnedProcesses)) {
        try {
            if ($proc -and -not $proc.HasExited) {
                Write-Status "停止脚本创建的 logcat 进程 PID=$($proc.Id)"
                $proc.Kill()
                $proc.WaitForExit(3000) | Out-Null
            }
        } catch {
            Write-Warning "无法停止 PID=$($proc.Id): $_"
        }
    }
    $Script:OwnedProcesses.Clear()
}

function Register-CleanupHandlers {
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Stop-OwnedProcesses
        if ($Script:OutputDir) {
            try { Write-SummaryMarkdown -Final } catch { }
        }
    }
    try {
        $cancel = [Console]::CancelKeyPress
        if ($null -ne $cancel) {
            $handler = [ConsoleCancelEventHandler]{
                param($sender, $e)
                $e.Cancel = $true
                Write-Host ''
                Write-Status '收到 Ctrl+C，正在清理脚本创建的 logcat 进程...'
                Stop-OwnedProcesses
                if ($Script:OutputDir) {
                    try {
                        $Script:SummaryState.Status = 'aborted'
                        $Script:SummaryState.FailReason = '用户 Ctrl+C 中断'
                        Write-SummaryMarkdown -Final
                    } catch { }
                }
                [Environment]::Exit(130)
            }
            $cancel.Add($handler)
        }
    } catch {
        Write-Verbose "当前环境不支持 CancelKeyPress 钩子: $_"
    }
}

function Get-ScenarioPaths {
    param([hashtable]$Definition, [string]$OutputDir)
    $prefix = $Definition.FilePrefix
    return [ordered]@{
        FullLog    = Join-Path $OutputDir "${prefix}_full.log"
        GestureLog = Join-Path $OutputDir "${prefix}_gesture.log"
        Csv        = Join-Path $OutputDir "${prefix}_results.csv"
        Meta       = Join-Path $OutputDir "${prefix}_meta.json"
    }
}

function Get-AdbProperty {
    param([string]$DeviceId, [string]$Prop)
    return (Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('-s', $DeviceId, 'shell', 'getprop', $Prop) -AllowFailure).StdOut.Trim()
}

function Get-AdbShellValue {
    param([string]$DeviceId, [string]$Command)
    return (Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('-s', $DeviceId, 'shell', $Command) -AllowFailure).StdOut.Trim()
}

function Get-DeviceRefreshRate {
    param([string]$DeviceId)
    try {
        $peak = Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @(
            '-s', $DeviceId, 'shell', 'settings', 'get', 'system', 'peak_refresh_rate'
        ) -AllowFailure -TimeoutSeconds 8
        $val = $peak.StdOut.Trim()
        if ($val -and $val -ne 'null') { return "$val Hz" }
    } catch {
        Write-Verbose "读取刷新率失败: $_"
    }
    return 'unknown'
}

function Get-FlutterDeviceId {
    param($Device)
    if ($null -eq $Device) { return $null }
    if ($Device -is [string]) { return $Device }
    return [string]$Device.id
}

function Get-FlutterDeviceName {
    param($Device)
    if ($null -eq $Device) { return 'unknown' }
    if ($Device -is [string]) { return $Device }
    return [string]$Device.name
}

function Get-FlutterAndroidPhysicalDevices {
    $result = Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList @('devices', '--machine') -AllowFailure
    $list = New-Object System.Collections.Generic.List[object]
    try { $parsed = $result.StdOut | ConvertFrom-Json } catch { return @() }
    foreach ($d in @($parsed)) {
        $platform = [string]$d.targetPlatform
        if ($platform -notmatch '^android') { continue }
        if ($d.emulator -eq $true) { continue }
        if ($d.isSupported -eq $false) { continue }
        [void]$list.Add($d)
    }
    return [object[]]$list.ToArray()
}

function Get-AdbDeviceStateMap {
    $map = @{}
    $r = Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('devices', '-l') -AllowFailure
    foreach ($line in ($r.StdOut -split "`n")) {
        if ($line -match '^(?<id>\S+)\s+(?<state>\S+)') { $map[$matches['id']] = $matches['state'] }
    }
    return $map
}

function Select-AndroidDevice {
    while ($true) {
        $flutterDevices = @(Get-FlutterAndroidPhysicalDevices)
        $adbStates = Get-AdbDeviceStateMap
        if (@($flutterDevices).Count -eq 0) {
            Write-Host '未检测到 Android 真机（已排除模拟器）。'
            $input = Read-Host '连接后输入 retry 或 Enter 重试，quit 退出'
            if ($input -eq 'quit') { throw '用户取消：无可用 Android 真机' }
            continue
        }
        $ready = @(); $unauthorized = @(); $offline = @()
        foreach ($d in $flutterDevices) {
            $deviceId = Get-FlutterDeviceId $d
            if (-not $deviceId) { continue }
            $state = $adbStates[$deviceId]
            if ($state -eq 'unauthorized') { $unauthorized += $d; continue }
            if ($state -eq 'offline') { $offline += $d; continue }
            if ($state -eq 'device') { $ready += $d }
        }
        if (@($unauthorized).Count -gt 0) {
            Write-Host '设备 unauthorized：请在手机上允许 USB 调试并勾选始终允许。'
            $input = Read-Host '完成后 retry/Enter 重试，quit 退出'
            if ($input -eq 'quit') { throw '用户取消：设备未授权' }
            continue
        }
        if (@($offline).Count -gt 0 -and @($ready).Count -eq 0) {
            Write-Host '设备 offline：请重新连接。'
            $input = Read-Host '完成后 retry/Enter 重试，quit 退出'
            if ($input -eq 'quit') { throw '用户取消：设备 offline' }
            continue
        }
        if (@($ready).Count -eq 0) {
            $input = Read-Host 'ADB 状态异常，retry 或 quit'
            if ($input -eq 'quit') { throw '用户取消：ADB 状态异常' }
            continue
        }
        if (@($ready).Count -eq 1) {
            $selected = @($ready)[0]
            Write-Status "自动选择: $(Get-FlutterDeviceName $selected) [$(Get-FlutterDeviceId $selected)]"
            return $selected
        }
        for ($i = 0; $i -lt @($ready).Count; $i++) {
            Write-Host "[$($i+1)] $(Get-FlutterDeviceName $ready[$i]) id=$(Get-FlutterDeviceId $ready[$i])"
        }
        $choice = Read-Host '选择设备编号'
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le @($ready).Count) {
            return $ready[[int]$choice - 1]
        }
    }
}

function Collect-DeviceInfo {
    param([string]$DeviceId)
    Write-Status '采集设备信息（manufacturer / model / ABI / 分辨率）...'
    $wmSize = Get-AdbShellValue -DeviceId $DeviceId -Command 'wm size'
    $resolution = if ($wmSize) { $wmSize -replace 'Physical size:\s*', '' } else { 'unknown' }
    $info = [ordered]@{
        manufacturer = Get-AdbProperty -DeviceId $DeviceId -Prop 'ro.product.manufacturer'
        model = Get-AdbProperty -DeviceId $DeviceId -Prop 'ro.product.model'
        androidVersion = Get-AdbProperty -DeviceId $DeviceId -Prop 'ro.build.version.release'
        apiLevel = Get-AdbProperty -DeviceId $DeviceId -Prop 'ro.build.version.sdk'
        abi = Get-AdbProperty -DeviceId $DeviceId -Prop 'ro.product.cpu.abi'
        resolution = $resolution
        density = (Get-AdbShellValue -DeviceId $DeviceId -Command 'wm density') -replace 'Physical density:\s*', ''
        refreshRate = Get-DeviceRefreshRate -DeviceId $DeviceId
        deviceId = $DeviceId
        deviceIdMasked = (Mask-DeviceId $DeviceId)
    }
    Write-Status "设备: $($info.manufacturer) $($info.model) | Android $($info.androidVersion) | ABI $($info.abi)"
    return $info
}

function Find-DebugApk {
    param([string]$ProjectRoot, [string]$DeviceAbi)
    $candidates = @(Join-Path $ProjectRoot 'build\app\outputs\flutter-apk\app-debug.apk')
    $splitDir = Join-Path $ProjectRoot 'build\app\outputs\flutter-apk'
    if (Test-Path $splitDir) {
        $abiMap = @{ 'arm64-v8a'='app-arm64-v8a-debug.apk'; 'armeabi-v7a'='app-armeabi-v7a-debug.apk'; 'x86_64'='app-x86_64-debug.apk'; 'x86'='app-x86-debug.apk' }
        if ($abiMap.ContainsKey($DeviceAbi)) {
            $split = Join-Path $splitDir $abiMap[$DeviceAbi]
            if (Test-Path $split) { $candidates = @($split) + $candidates }
        }
    }
    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-Path $path) { return (Resolve-Path $path).Path }
    }
    return $null
}

function Resolve-LauncherActivity {
    param([string]$DeviceId, [string]$PackageId)
    $r = Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('-s', $DeviceId, 'shell', 'cmd', 'package', 'resolve-activity', '--brief', $PackageId) -AllowFailure
    $lines = @($r.StdOut.Trim() -split "`n" | Where-Object { $_ -and $_ -notmatch 'No activity found' })
    if ($lines.Count -ge 1 -and $lines[-1] -match '/') { return $lines[-1].Trim() }
    return "$PackageId/.MainActivity"
}

function Start-ScenarioLogcat {
    param([string]$DeviceId, [string]$FullLogPath)
    Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('-s', $DeviceId, 'logcat', '-c') -AllowFailure | Out-Null
    $adbExe = Get-ToolExecutable 'adb'
    $stderrPath = $FullLogPath + '.stderr'
    $proc = Start-Process -FilePath $adbExe `
        -ArgumentList @('-s', $DeviceId, 'logcat', '-v', 'threadtime') `
        -RedirectStandardOutput $FullLogPath `
        -RedirectStandardError $stderrPath `
        -NoNewWindow -PassThru
    $Script:OwnedProcesses.Add($proc) | Out-Null
    return [PSCustomObject]@{ Process = $proc; Pid = $proc.Id; StdErrPath = $stderrPath }
}

function Stop-ScenarioLogcat {
    param($Capture)
    if ($null -eq $Capture) { return }
    try {
        if ($Capture.Process -and -not $Capture.Process.HasExited) {
            $Capture.Process.Kill()
            $Capture.Process.WaitForExit(3000) | Out-Null
        }
    } catch { Write-Warning "停止 logcat 失败: $_" }
    if ($Capture.Process) { $Script:OwnedProcesses.Remove($Capture.Process) | Out-Null }
}

function Extract-ReaderGestureLines {
    param([string]$FullLogPath)
    if (-not (Test-Path $FullLogPath)) { return @() }
    $reader = New-Object System.IO.StreamReader($FullLogPath, [System.Text.Encoding]::UTF8, $true)
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -match '\[ReaderGesture\]') { $lines.Add($line) }
        }
    } finally { $reader.Close() }
    return [object[]]$lines.ToArray()
}

function Write-ScenarioMeta {
    param([string]$Path, [hashtable]$Data)
    Write-TextFile -Path $Path -Content ($Data | ConvertTo-Json -Depth 6)
}

function Show-ScenarioBrief {
    param([hashtable]$Definition)
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host "场景 $($Definition.Letter): $($Definition.Title)"
    Write-Host ('=' * 72)
    Write-Host '通用设置:'
    foreach ($s in $Script:CommonSetup) { Write-Host "  - $s" }
    Write-Host '本场景:'
    foreach ($s in $Definition.Setup) { Write-Host "  - $s" }
    Write-Host '操作说明:'
    foreach ($s in $Definition.Instructions) { Write-Host "  - $s" }
    Write-Host ''
    Write-Host '交互命令: Enter=继续 | retry=重做当前 | skip=跳过当前 | quit=退出脚本'
    Write-Host ''
}

function Invoke-SlowDragTrial {
    param([int]$Trial, [string]$CsvPath, [string]$ScenarioId = 'A')
    while ($true) {
        $actionId = '{0}{1:D2}' -f $ScenarioId, $Trial
        if ($Script:ExperimentIvBypass -and $Script:SelectedDeviceId) {
            Send-TestActionMarker -DeviceId $Script:SelectedDeviceId -PackageId 'top.fumiama.copymanga_flutter' `
                -Phase 'started' -ScenarioId $ScenarioId -ActionId $actionId -ActionPhase 'singleSwipe'
        }
        Invoke-ActionCountdown
        Write-Host ">>> 第 $Trial 次：执行慢速长拖，完成后按 Enter（retry/skip/quit）"
        $cmd = Read-UserFlowCommand -Prompt '操作完成'
        if ($cmd -eq 'quit') { return 'quit' }
        if ($cmd -eq 'skip') {
            $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Write-CsvRow -Path $CsvPath -Fields @($Trial, '', '', '', $now, $now, 'skipped by user', 'skipped')
            return 'skip'
        }
        if ($cmd -eq 'retry') { continue }

        $start = (Get-Date).ToUniversalTime().ToString('o')
        $pageTurn = Read-YesNo '是否成功翻页? (y/n)'
        if ($pageTurn -eq 'quit') { return 'quit' }
        if ($pageTurn -eq 'skip') { continue }
        $lag = Read-YesNo '是否明显迟滞? (y/n)'
        if ($lag -eq 'quit') { return 'quit' }
        $menu = Read-YesNo '是否意外打开菜单? (y/n)'
        if ($menu -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注（可留空）'
        $end = (Get-Date).ToUniversalTime().ToString('o')
        Write-CsvRow -Path $CsvPath -Fields @($Trial, $pageTurn, $lag, $menu, $start, $end, $notes, 'completed')
        if ($Script:ExperimentIvBypass -and $Script:SelectedDeviceId) {
            Send-TestActionMarker -DeviceId $Script:SelectedDeviceId -PackageId 'top.fumiama.copymanga_flutter' `
                -Phase 'completed' -ScenarioId $ScenarioId -ActionId $actionId -ActionPhase 'singleSwipe'
        }
        return 'continue'
    }
}

function Invoke-FastSwipeSingleTrial {
    param([int]$Trial, [string]$CsvPath, [string]$ScenarioId)
    if ($Trial -gt 1) {
        Write-Host '等待 1 秒...'
        Start-Sleep -Seconds 1
    }
    $actionId = '{0}{1:D2}' -f $ScenarioId, $Trial
    while ($true) {
        if ($Script:ExperimentIvBypass -and $Script:SelectedDeviceId) {
            Send-TestActionMarker -DeviceId $Script:SelectedDeviceId -PackageId 'top.fumiama.copymanga_flutter' `
                -Phase 'started' -ScenarioId $ScenarioId -ActionId $actionId -ActionPhase 'singleSwipe'
        }
        Invoke-ActionCountdown
        Write-Host ">>> $actionId：快速短划，完成后按 Enter（retry/skip/quit）"
        $cmd = Read-UserFlowCommand -Prompt '操作完成'
        if ($cmd -eq 'quit') { return 'quit' }
        if ($cmd -eq 'skip') {
            $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Write-CsvRow -Path $CsvPath -Fields @($Trial, '', '', '', '', $now, $now, 'skipped', 'skipped')
            return 'skip'
        }
        if ($cmd -eq 'retry') { continue }

        $start = (Get-Date).ToUniversalTime().ToString('o')
        $pageTurn = Read-YesNo '是否成功翻页? (y/n)'
        if ($pageTurn -eq 'quit') { return 'quit' }
        $snap = Read-YesNo '是否发生位移后回弹? (y/n)'
        if ($snap -eq 'quit') { return 'quit' }
        $notRec = Read-YesNo '是否像完全没有识别到手势? (y/n)'
        if ($notRec -eq 'quit') { return 'quit' }
        $menu = Read-YesNo '是否意外打开菜单? (y/n)'
        if ($menu -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注（可留空）'
        $end = (Get-Date).ToUniversalTime().ToString('o')
        Write-CsvRow -Path $CsvPath -Fields @($Trial, $pageTurn, $snap, $notRec, $menu, $start, $end, $notes, 'completed')
        if ($Script:ExperimentIvBypass -and $Script:SelectedDeviceId) {
            Send-TestActionMarker -DeviceId $Script:SelectedDeviceId -PackageId 'top.fumiama.copymanga_flutter' `
                -Phase 'completed' -ScenarioId $ScenarioId -ActionId $actionId -ActionPhase 'singleSwipe'
        }
        return 'continue'
    }
}

function Invoke-ZoomCheckTrial {
    param([int]$Trial, [string]$CsvPath, [string]$ScenarioId)
    $checks = @(
        @{ type = 'pinchFromUnzoomed'; label = '未缩放状态双指捏合 3 次' },
        @{ type = 'doubleTap'; label = '双击缩放 3 次（若产品支持）' },
        @{ type = 'panWhenZoomed'; label = '放大后单指平移 3 次' },
        @{ type = 'swipeAfterReset'; label = '缩回 1.0 后单指横滑 3 次' }
    )
    if ($Trial -lt 1 -or $Trial -gt $checks.Count) { return 'continue' }
    $check = $checks[$Trial - 1]
    $actionId = '{0}{1}' -f $ScenarioId, $Trial
    while ($true) {
        if ($Script:ExperimentIvBypass -and $Script:SelectedDeviceId) {
            Send-TestActionMarker -DeviceId $Script:SelectedDeviceId -PackageId 'top.fumiama.copymanga_flutter' `
                -Phase 'started' -ScenarioId $ScenarioId -ActionId $actionId -ActionPhase $check.type
        }
        Invoke-ActionCountdown
        Write-Host ">>> $actionId ($check.type)：$($check.label)"
        Write-Host '完成后按 Enter（retry/skip/quit）'
        $cmd = Read-UserFlowCommand -Prompt '操作完成'
        if ($cmd -eq 'quit') { return 'quit' }
        if ($cmd -eq 'skip') {
            $now = (Get-Date).ToUniversalTime().ToString('o')
            Write-CsvRow -Path $CsvPath -Fields @($Trial, $check.type, '', 'skipped', $now, $now, 'skipped')
            return 'skip'
        }
        if ($cmd -eq 'retry') { continue }
        $start = (Get-Date).ToUniversalTime().ToString('o')
        $success = Read-YesNo '该检查是否成功（或部分可用）? (y/n)'
        if ($success -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注：实验模式下哪些能力不可用'
        $end = (Get-Date).ToUniversalTime().ToString('o')
        Write-CsvRow -Path $CsvPath -Fields @($Trial, $check.type, $success, $notes, $start, $end, 'completed')
        if ($Script:ExperimentIvBypass -and $Script:SelectedDeviceId) {
            Send-TestActionMarker -DeviceId $Script:SelectedDeviceId -PackageId 'top.fumiama.copymanga_flutter' `
                -Phase 'completed' -ScenarioId $ScenarioId -ActionId $actionId -ActionPhase $check.type
        }
        return 'continue'
    }
}

function Invoke-FastSwipeTrial {
    param([int]$Trial, [string]$CsvPath, [switch]$IsFirst)
    if (-not $IsFirst) {
        Write-Host '等待 1 秒，避免前一次 ballistic 动画干扰...'
        Start-Sleep -Seconds 1
    }
    while ($true) {
        Invoke-ActionCountdown
        Write-Host ">>> 第 $Trial 次：执行快速短划，完成后按 Enter（retry/skip/quit）"
        $cmd = Read-UserFlowCommand -Prompt '操作完成'
        if ($cmd -eq 'quit') { return 'quit' }
        if ($cmd -eq 'skip') {
            $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Write-CsvRow -Path $CsvPath -Fields @($Trial, '', '', '', '', $now, $now, 'skipped by user', 'skipped')
            return 'skip'
        }
        if ($cmd -eq 'retry') { continue }

        $start = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        $pageTurn = Read-YesNo '是否成功翻页? (y/n)'
        if ($pageTurn -eq 'quit') { return 'quit' }
        $snap = Read-YesNo '是否发生位移后回弹? (y/n)'
        if ($snap -eq 'quit') { return 'quit' }
        $notRec = Read-YesNo '是否像完全没有识别到手势? (y/n)'
        if ($notRec -eq 'quit') { return 'quit' }
        $menu = Read-YesNo '是否意外打开菜单? (y/n)'
        if ($menu -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注（可留空）'
        $end = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Write-CsvRow -Path $CsvPath -Fields @($Trial, $pageTurn, $snap, $notRec, $menu, $start, $end, $notes, 'completed')
        return 'continue'
    }
}

function Invoke-EdgeNextGroup {
    param([int]$Group, [string]$CsvPath, [switch]$IsFirst)
    if (-not $IsFirst) {
        Write-Host '组间等待 4 秒，降低边界提示状态残留...'
        Start-Sleep -Seconds 4
    }
    while ($true) {
        $groupStart = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'

        Invoke-ActionCountdown
        Write-Host ">>> 第 $Group 组 — 第一次独立 swipe，完成后按 Enter（retry/skip/quit）"
        $cmd1 = Read-UserFlowCommand -Prompt '第一次滑动完成'
        if ($cmd1 -eq 'quit') { return 'quit' }
        if ($cmd1 -eq 'skip') {
            $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Write-CsvRow -Path $CsvPath -Fields @($Group, '', '', '', '', $groupStart, $now, 'skipped by user', 'skipped')
            return 'skip'
        }
        if ($cmd1 -eq 'retry') { continue }

        Invoke-ActionCountdown
        Write-Host ">>> 第 $Group 组 — 第二次独立 swipe（同方向），完成后按 Enter（retry/skip/quit）"
        $cmd2 = Read-UserFlowCommand -Prompt '第二次滑动完成'
        if ($cmd2 -eq 'quit') { return 'quit' }
        if ($cmd2 -eq 'retry') { continue }

        $hint = Read-YesNo '第一次滑动后是否看到「再次滑动」类提示? (y/n)'
        if ($hint -eq 'quit') { return 'quit' }
        $changed = Read-YesNo '第二次滑动后是否成功进入下一章? (y/n)'
        if ($changed -eq 'quit') { return 'quit' }
        $dup = Read-YesNo '是否发生重复换章? (y/n)'
        if ($dup -eq 'quit') { return 'quit' }
        $skipCh = Read-YesNo '是否跳过一章? (y/n)'
        if ($skipCh -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注（可留空）'
        $groupEnd = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Write-CsvRow -Path $CsvPath -Fields @($Group, $hint, $changed, $dup, $skipCh, $groupStart, $groupEnd, $notes, 'completed')

        if ($changed -eq 'yes') {
            Write-Host '换章成功：请手动返回合适的章节尾页。'
            while ($true) {
                $ready = Read-UserFlowCommand -Prompt 'ready=继续本场景 | skip=跳过本场景剩余组 | quit=结束全部测试'
                if ($ready -eq 'quit') { return 'quit' }
                if ($ready -eq 'skip') { return 'skip_scenario' }
                if ($ready -eq 'ready' -or $ready -eq 'continue') { break }
                Write-Host '请输入 ready、skip 或 quit。'
            }
        }
        return 'continue'
    }
}

function Invoke-EdgePreviousGroup {
    param([int]$Group, [string]$CsvPath, [switch]$IsFirst)
    if (-not $IsFirst) { Start-Sleep -Seconds 4 }
    while ($true) {
        $groupStart = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Invoke-ActionCountdown
        Write-Host ">>> 第 $Group 组 — 第一次独立 swipe，完成后按 Enter"
        $cmd1 = Read-UserFlowCommand -Prompt '第一次滑动完成'
        if ($cmd1 -eq 'quit') { return 'quit' }
        if ($cmd1 -eq 'skip') {
            $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Write-CsvRow -Path $CsvPath -Fields @($Group, '', '', '', '', $groupStart, $now, 'skipped', 'skipped')
            return 'skip'
        }
        if ($cmd1 -eq 'retry') { continue }

        Invoke-ActionCountdown
        Write-Host ">>> 第 $Group 组 — 第二次独立 swipe"
        $cmd2 = Read-UserFlowCommand -Prompt '第二次滑动完成'
        if ($cmd2 -eq 'quit') { return 'quit' }
        if ($cmd2 -eq 'retry') { continue }

        $hint = Read-YesNo '第一次滑动是否出现提示? (y/n)'
        if ($hint -eq 'quit') { return 'quit' }
        $changed = Read-YesNo '第二次滑动是否进入上一章? (y/n)'
        if ($changed -eq 'quit') { return 'quit' }
        $dup = Read-YesNo '是否重复换章? (y/n)'
        if ($dup -eq 'quit') { return 'quit' }
        $skipCh = Read-YesNo '是否跳章? (y/n)'
        if ($skipCh -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注（可留空）'
        $groupEnd = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Write-CsvRow -Path $CsvPath -Fields @($Group, $hint, $changed, $dup, $skipCh, $groupStart, $groupEnd, $notes, 'completed')

        if ($changed -eq 'yes') {
            Write-Host '换章成功：请返回合适的章节首页。'
            while ($true) {
                $ready = Read-UserFlowCommand -Prompt 'ready=继续本场景 | skip=跳过本场景剩余组 | quit=结束全部测试'
                if ($ready -eq 'quit') { return 'quit' }
                if ($ready -eq 'skip') { return 'skip_scenario' }
                if ($ready -in @('ready', 'continue')) { break }
                Write-Host '请输入 ready、skip 或 quit。'
            }
        }
        return 'continue'
    }
}

function Invoke-MultitouchTrial {
    param([int]$Trial, [string]$CsvPath)
    while ($true) {
        Invoke-ActionCountdown
        Write-Host ">>> 第 $Trial 次 — 步骤 1/4：双指同时轻触（不要明显缩放），完成后 Enter"
        $c1 = Read-UserFlowCommand -Prompt '双指轻触完成'
        if ($c1 -eq 'quit') { return 'quit' }
        if ($c1 -eq 'skip') {
            $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Write-CsvRow -Path $CsvPath -Fields @($Trial, '', '', '', '', $now, $now, 'skipped', 'skipped')
            return 'skip'
        }
        if ($c1 -eq 'retry') { continue }

        Write-Host '>>> 步骤 2/4：双指全部松开，完成后 Enter'
        $c2 = Read-UserFlowCommand -Prompt '双指松开'
        if ($c2 -eq 'quit') { return 'quit' }
        if ($c2 -eq 'retry') { continue }

        Write-Host '>>> 步骤 3/4：等待 1 秒...'
        Start-Sleep -Seconds 1

        $start = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Invoke-ActionCountdown
        Write-Host '>>> 步骤 4/4：单指正常横向翻页，完成后 Enter'
        $c3 = Read-UserFlowCommand -Prompt '单指翻页完成'
        if ($c3 -eq 'quit') { return 'quit' }
        if ($c3 -eq 'retry') { continue }

        $twoFinger = 'yes'
        $pageTurn = Read-YesNo '双指后单指翻页是否成功? (y/n)'
        if ($pageTurn -eq 'quit') { return 'quit' }
        $locked = Read-YesNo '是否感觉页面被锁住? (y/n)'
        if ($locked -eq 'quit') { return 'quit' }
        $retouch = Read-YesNo '是否需要再次触摸才能恢复? (y/n)'
        if ($retouch -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注（可留空）'
        $end = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Write-CsvRow -Path $CsvPath -Fields @($Trial, $twoFinger, $pageTurn, $locked, $retouch, $start, $end, $notes, 'completed')
        return 'continue'
    }
}

function Invoke-LightDeepTrial {
    param([int]$Trial, [string]$CsvPath, [string]$SuggestedStyle)
    while ($true) {
        Write-Host ''
        Write-Host '轻滑：短距离、低力度、较快松手。'
        Write-Host '深滑：长距离、拖动感明显、滑过较大区域。'
        $style = Read-Host "第 $Trial 次风格 [light/deep]（建议 $SuggestedStyle，直接 Enter 采纳）"
        if ([string]::IsNullOrWhiteSpace($style)) { $style = $SuggestedStyle }
        $style = $style.Trim().ToLowerInvariant()
        if ($style -notin @('light', 'deep')) {
            Write-Host '请输入 light 或 deep。'
            continue
        }

        Invoke-ActionCountdown
        Write-Host ">>> 第 $Trial 次（$style）：完成后按 Enter（retry/skip/quit）"
        $cmd = Read-UserFlowCommand -Prompt '操作完成'
        if ($cmd -eq 'quit') { return 'quit' }
        if ($cmd -eq 'skip') {
            $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Write-CsvRow -Path $CsvPath -Fields @($Trial, $style, '', '', '', '', $now, $now, 'skipped', 'skipped')
            return 'skip'
        }
        if ($cmd -eq 'retry') { continue }

        $start = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        $pageTurn = Read-YesNo '是否成功翻页? (y/n)'
        if ($pageTurn -eq 'quit') { return 'quit' }
        $snap = Read-YesNo '是否位移后回弹? (y/n)'
        if ($snap -eq 'quit') { return 'quit' }
        $notRec = Read-YesNo '是否像未识别手势? (y/n)'
        if ($notRec -eq 'quit') { return 'quit' }
        $menu = Read-YesNo '是否意外打开菜单? (y/n)'
        if ($menu -eq 'quit') { return 'quit' }
        $notes = Read-Host '备注（可留空；勿将主观轻/深当作精确测量）'
        $end = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Write-CsvRow -Path $CsvPath -Fields @($Trial, $style, $pageTurn, $snap, $notRec, $menu, $start, $end, $notes, 'completed')
        return 'continue'
    }
}

function Invoke-TestScenario {
    param(
        [hashtable]$Definition,
        [string]$DeviceId,
        [string]$OutputDir,
        [int]$StartAt = 1
    )

    $paths = Get-ScenarioPaths -Definition $Definition -OutputDir $OutputDir
    $progress = Get-ScenarioProgress -Definition $Definition -OutputDir $OutputDir

    if ($progress.done) {
        Write-Status "场景 $($Definition.Letter) 已完成 ($($progress.completed)/$($Definition.RepeatCount))，跳过"
        return
    }

    if ($StartAt -lt 1) { $StartAt = 1 }
    if ($StartAt -gt $Definition.RepeatCount) { $StartAt = $progress.completed + 1 }

    if ($StartAt -gt 1) {
        Write-Host ''
        Write-Host "场景 $($Definition.Letter) 续跑：已完成 $($StartAt - 1) 组/次，从第 $StartAt 开始"
    } else {
        Show-ScenarioBrief -Definition $Definition
    }

    $prep = Read-UserFlowCommand -Prompt '准备好后按 Enter 开始本场景日志采集（skip 跳过 / quit 退出）'
    if ($prep -eq 'quit') { $Script:StopRequested = $true; return }
    if ($prep -eq 'skip') { Write-Status "跳过场景 $($Definition.Letter)"; return }

    Initialize-Csv -Path $paths.Csv -Header $Definition.CsvHeader

    $scenarioStart = Get-Date
    $isResumeSegment = ($StartAt -gt 1) -and (Test-Path $paths.FullLog)
    $segmentLog = $paths.FullLog
    if ($isResumeSegment) {
        $segmentLog = $paths.FullLog + '.resume_' + (Get-Date -Format 'HHmmss') + '.log'
    }

    $meta = [ordered]@{
        scenarioKey    = $Definition.Key
        scenarioLetter = $Definition.Letter
        title          = $Definition.Title
        filePrefix     = $Definition.FilePrefix
        type           = $Definition.Type
        repeatCount    = $Definition.RepeatCount
        csvHeader      = $Definition.CsvHeader
        startTime      = $scenarioStart.ToString('yyyy-MM-dd HH:mm:ss')
        deviceIdMasked = (Mask-DeviceId $DeviceId)
        resumeFrom     = $StartAt
    }
    Write-ScenarioMeta -Path $paths.Meta -Content $meta

    Write-Status "启动 logcat -> $(Split-Path $segmentLog -Leaf)$(if ($isResumeSegment) { '（续跑片段，结束后合并）' })"
    $capture = Start-ScenarioLogcat -DeviceId $DeviceId -FullLogPath $segmentLog
    Write-Status "logcat PID=$($capture.Pid)（仅跟踪此 PID，不会误杀其他 adb）"

    $abort = $false
    for ($i = $StartAt; $i -le $Definition.RepeatCount; $i++) {
        $result = switch ($Definition.Type) {
            'slow_drag'      { Invoke-SlowDragTrial -Trial $i -CsvPath $paths.Csv -ScenarioId $Definition.Letter }
            'fast_swipe'     { Invoke-FastSwipeTrial -Trial $i -CsvPath $paths.Csv -IsFirst:($i -eq $StartAt) }
            'fast_swipe_single' { Invoke-FastSwipeSingleTrial -Trial $i -CsvPath $paths.Csv -ScenarioId $Definition.Letter }
            'zoom_check'     { Invoke-ZoomCheckTrial -Trial $i -CsvPath $paths.Csv -ScenarioId $Definition.Letter }
            'edge_next'      { Invoke-EdgeNextGroup -Group $i -CsvPath $paths.Csv -IsFirst:($i -eq 1) }
            'edge_previous'  { Invoke-EdgePreviousGroup -Group $i -CsvPath $paths.Csv -IsFirst:($i -eq 1) }
            'multitouch'     { Invoke-MultitouchTrial -Trial $i -CsvPath $paths.Csv }
            'light_deep'     {
                $suggested = if ($i % 2 -eq 1) { 'light' } else { 'deep' }
                Invoke-LightDeepTrial -Trial $i -CsvPath $paths.Csv -SuggestedStyle $suggested
            }
            default { throw "未知场景类型: $($Definition.Type)" }
        }
        if ($result -eq 'quit') { $abort = $true; $Script:StopRequested = $true; break }
        if ($result -eq 'skip_scenario') { break }
    }

    Stop-ScenarioLogcat -Capture $capture
    Start-Sleep -Milliseconds 300

    if ($isResumeSegment -and (Test-Path $segmentLog)) {
        Append-TextFile -Path $paths.FullLog -Content ("`n=== RESUME $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') segment=$(Split-Path $segmentLog -Leaf) ===`n")
        Append-TextFile -Path $paths.FullLog -Content (Get-Content -Path $segmentLog -Raw -Encoding UTF8)
        Remove-Item -Path $segmentLog -Force -ErrorAction SilentlyContinue
    }

    $gestureLines = Extract-ReaderGestureLines -FullLogPath $paths.FullLog
    $gestureContent = if (@($gestureLines).Count -gt 0) { ($gestureLines -join "`n") + "`n" } else { '' }
    Write-TextFile -Path $paths.GestureLog -Content $gestureContent

    $scenarioEnd = Get-Date
    $meta.endTime = $scenarioEnd.ToString('yyyy-MM-dd HH:mm:ss')
    $meta.durationSeconds = [math]::Round(($scenarioEnd - $scenarioStart).TotalSeconds, 1)
    $meta.logcatPid = $capture.Pid
    $meta.gestureLineCount = @($gestureLines).Count
    $meta.aborted = $abort
    Write-ScenarioMeta -Path $paths.Meta -Content $meta

    [void]$Script:ExecutedScenarios.Add($Definition)
    Write-Status "场景 $($Definition.Letter) 结束: gesture 行 $(@($gestureLines).Count)"
}

function Import-ScenarioCsvRows {
    param([string]$CsvPath)
    if (-not (Test-Path $CsvPath)) { return @() }
    $rows = Import-Csv -Path $CsvPath -Encoding UTF8
    return @($rows | Where-Object { $_.status -ne 'skipped' })
}

function Count-Yes {
    param($Rows, [string]$Column)
    return ($Rows | Where-Object { $_.$Column -eq 'yes' } | Measure-Object).Count
}

function Compute-CsvStatistics {
    param([string]$OutputDir)

    $stats = @{}
    foreach ($def in $Script:ExecutedScenarios) {
        $paths = Get-ScenarioPaths -Definition $def -OutputDir $OutputDir
        $rows = Import-ScenarioCsvRows -CsvPath $paths.Csv
        $completed = @($rows).Count

        switch ($def.Type) {
            'slow_drag' {
                $success = Count-Yes $rows 'page_turn_success'
                $stats[$def.Key] = [ordered]@{
                    completed = $completed
                    page_turn_success = $success
                    page_turn_failure = $completed - $success
                    noticeable_lag = (Count-Yes $rows 'noticeable_lag')
                    menu_accidental = (Count-Yes $rows 'menu_accidental')
                }
            }
            'fast_swipe' {
                $success = Count-Yes $rows 'page_turn_success'
                $stats[$def.Key] = [ordered]@{
                    completed = $completed
                    page_turn_success = $success
                    page_turn_failure = $completed - $success
                    snap_back = (Count-Yes $rows 'snap_back')
                    not_recognized = (Count-Yes $rows 'not_recognized')
                    menu_accidental = (Count-Yes $rows 'menu_accidental')
                }
            }
            'edge_next' {
                $stats[$def.Key] = [ordered]@{
                    completed_groups = $completed
                    first_swipe_hint_seen = (Count-Yes $rows 'first_swipe_hint_seen')
                    second_swipe_chapter_changed = (Count-Yes $rows 'second_swipe_chapter_changed')
                    duplicate_chapter_change = (Count-Yes $rows 'duplicate_chapter_change')
                    skipped_chapter = (Count-Yes $rows 'skipped_chapter')
                }
            }
            'edge_previous' {
                $stats[$def.Key] = [ordered]@{
                    completed_groups = $completed
                    first_swipe_hint_seen = (Count-Yes $rows 'first_swipe_hint_seen')
                    second_swipe_chapter_changed = (Count-Yes $rows 'second_swipe_chapter_changed')
                    duplicate_chapter_change = (Count-Yes $rows 'duplicate_chapter_change')
                    skipped_chapter = (Count-Yes $rows 'skipped_chapter')
                }
            }
            'multitouch' {
                $success = Count-Yes $rows 'post_multitouch_page_turn_success'
                $stats[$def.Key] = [ordered]@{
                    completed = $completed
                    post_multitouch_page_turn_success = $success
                    post_multitouch_page_turn_failure = $completed - $success
                    felt_locked = (Count-Yes $rows 'felt_locked')
                    needed_retouch = (Count-Yes $rows 'needed_retouch')
                }
            }
            'light_deep' {
                $success = Count-Yes $rows 'page_turn_success'
                $stats[$def.Key] = [ordered]@{
                    completed = $completed
                    light_trials = @($rows | Where-Object { $_.swipe_style -eq 'light' }).Count
                    deep_trials = @($rows | Where-Object { $_.swipe_style -eq 'deep' }).Count
                    page_turn_success = $success
                    page_turn_failure = $completed - $success
                }
            }
        }
    }
    $Script:SummaryState.CsvStats = $stats
    return $stats
}

function Invoke-LogQualityCheck {
    param([string]$OutputDir)

    $report = New-Object System.Text.StringBuilder
    [void]$report.AppendLine('ReaderGesture 日志质量检查')
    [void]$report.AppendLine("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$report.AppendLine('')

    $scenariosToScan = @($Script:MandatoryScenarios) + @($Script:OptionalScenarioDefinitions)
    $totalValid = 0; $totalInvalid = 0; $totalGestureLines = 0
    $allEvents = @{}

    foreach ($def in $scenariosToScan) {
        $paths = Get-ScenarioPaths -Definition $def -OutputDir $OutputDir
        [void]$report.AppendLine("=== $($def.FilePrefix) : $($def.Title) ===")

        if (-not (Test-Path $paths.GestureLog)) {
            [void]$report.AppendLine('  手势日志文件不存在（可能未执行或已跳过）')
            [void]$report.AppendLine('')
            continue
        }

        $reader = New-Object System.IO.StreamReader($paths.GestureLog, [System.Text.Encoding]::UTF8, $true)
        $lines = [System.Collections.Generic.List[string]]::new()
        try { while (-not $reader.EndOfStream) { $lines.Add($reader.ReadLine()) } } finally { $reader.Close() }

        $valid = 0; $invalid = 0; $summaries = 0
        $sessionIds = [System.Collections.Generic.HashSet[string]]::new()
        $invalidSamples = [System.Collections.Generic.List[string]]::new()

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $totalGestureLines++
            $idx = $line.IndexOf('[ReaderGesture]')
            if ($idx -lt 0) { continue }
            $jsonPart = $line.Substring($idx + '[ReaderGesture]'.Length).Trim()
            try {
                $obj = $jsonPart | ConvertFrom-Json
                $valid++; $totalValid++
                if ($obj.event) {
                    if (-not $allEvents.ContainsKey($obj.event)) { $allEvents[$obj.event] = 0 }
                    $allEvents[$obj.event]++
                }
                if ($obj.event -eq 'gestureSummary' -and $obj.gestureSessionId) {
                    $summaries++
                    [void]$sessionIds.Add([string]$obj.gestureSessionId)
                }
            } catch {
                $invalid++; $totalInvalid++
                if ($invalidSamples.Count -lt 3) { $invalidSamples.Add($line) }
            }
        }

        [void]$report.AppendLine("  行数: $($lines.Count)")
        [void]$report.AppendLine("  有效 JSON: $valid")
        [void]$report.AppendLine("  无效 JSON: $invalid")
        [void]$report.AppendLine("  gestureSummary: $summaries")
        [void]$report.AppendLine("  唯一 gestureSessionId: $($sessionIds.Count)")
        if ($invalidSamples.Count -gt 0) {
            [void]$report.AppendLine('  无效样例:')
            foreach ($s in $invalidSamples) { [void]$report.AppendLine("    $s") }
        }
        [void]$report.AppendLine('')

        $Script:SummaryState.ScenarioResults[$def.Key] = @{
            gestureLines = $lines.Count
            validJson = $valid
            invalidJson = $invalid
            summaries = $summaries
        }
    }

    [void]$report.AppendLine('=== 汇总 ===')
    [void]$report.AppendLine("  ReaderGesture 总行: $totalGestureLines")
    [void]$report.AppendLine("  有效 JSON: $totalValid")
    [void]$report.AppendLine("  无效 JSON: $totalInvalid")

    $path = Join-Path $OutputDir 'log_quality_check.txt'
    Write-TextFile -Path $path -Content $report.ToString()
}

function Write-SummaryMarkdown {
    param([switch]$Final)

    if (-not $Script:OutputDir) { return }
    if (@($Script:SummaryState.CsvStats.Keys).Count -eq 0 -and (Test-Path $Script:OutputDir)) {
        $null = Compute-CsvStatistics -OutputDir $Script:OutputDir
    }

    $env = $Script:SummaryState.Environment
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Android 阅读器手势诊断测试摘要')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("状态: **$($Script:SummaryState.Status)**")
    if ($Script:SummaryState.FailReason) {
        [void]$sb.AppendLine("失败原因: $($Script:SummaryState.FailReason)")
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## 环境')
    [void]$sb.AppendLine('| 项 | 值 |')
    [void]$sb.AppendLine('|---|---|')
    foreach ($key in @('testStartTime','powershellVersion','flutterVersion','dartVersion','gitCommit','gitDirty','applicationId','launcherActivity','apkPath','deviceManufacturer','deviceModel','androidVersion','apiLevel','abi','resolution','density','refreshRate','deviceIdMasked','resumeMode')) {
        if (Test-MapContainsKey $env $key) { [void]$sb.AppendLine("| $key | $($env[$key]) |") }
    }
    [void]$sb.AppendLine('')

    if (Test-MapContainsKey $env 'analyzeResult') {
        [void]$sb.AppendLine('## 构建与检查')
        [void]$sb.AppendLine('| 步骤 | 结果 |')
        [void]$sb.AppendLine('|---|---|')
        foreach ($step in @('pubGetExit','analyzeResult','testResult','buildResult','installResult','launchResult')) {
            if (Test-MapContainsKey $env $step) { [void]$sb.AppendLine("| $step | $($env[$step]) |") }
        }
        [void]$sb.AppendLine('')
    }

    if (@($Script:SummaryState.CsvStats.Keys).Count -gt 0) {
        [void]$sb.AppendLine('## 肉眼结果统计')
        if (Test-MapContainsKey $Script:SummaryState.CsvStats 'a_slow_drag') {
            $s = $Script:SummaryState.CsvStats['a_slow_drag']
            [void]$sb.AppendLine('### 场景 A：慢速长拖')
            [void]$sb.AppendLine("| 指标 | 次数 |")
            [void]$sb.AppendLine('|---|---:|')
            [void]$sb.AppendLine("| 完成次数 | $($s.completed) |")
            [void]$sb.AppendLine("| 翻页成功 | $($s.page_turn_success) |")
            [void]$sb.AppendLine("| 翻页失败 | $($s.page_turn_failure) |")
            [void]$sb.AppendLine("| 明显迟滞 | $($s.noticeable_lag) |")
            [void]$sb.AppendLine("| 菜单误触 | $($s.menu_accidental) |")
            [void]$sb.AppendLine('')
        }
        if (Test-MapContainsKey $Script:SummaryState.CsvStats 'b_fast_swipe') {
            $s = $Script:SummaryState.CsvStats['b_fast_swipe']
            [void]$sb.AppendLine('### 场景 B：快速短划')
            [void]$sb.AppendLine("| 指标 | 次数 |")
            [void]$sb.AppendLine('|---|---:|')
            [void]$sb.AppendLine("| 完成次数 | $($s.completed) |")
            [void]$sb.AppendLine("| 翻页成功 | $($s.page_turn_success) |")
            [void]$sb.AppendLine("| 翻页失败 | $($s.page_turn_failure) |")
            [void]$sb.AppendLine("| 位移后回弹 | $($s.snap_back) |")
            [void]$sb.AppendLine("| 完全未识别 | $($s.not_recognized) |")
            [void]$sb.AppendLine("| 菜单误触 | $($s.menu_accidental) |")
            [void]$sb.AppendLine('')
        }
        if (Test-MapContainsKey $Script:SummaryState.CsvStats 'c_edge_next') {
            $s = $Script:SummaryState.CsvStats['c_edge_next']
            [void]$sb.AppendLine('### 场景 C：章节尾页双滑 → 下一章')
            [void]$sb.AppendLine("| 指标 | 次数 |")
            [void]$sb.AppendLine('|---|---:|')
            [void]$sb.AppendLine("| 完成组数 | $($s.completed_groups) |")
            [void]$sb.AppendLine("| 首次提示成功 | $($s.first_swipe_hint_seen) |")
            [void]$sb.AppendLine("| 第二次换章成功 | $($s.second_swipe_chapter_changed) |")
            [void]$sb.AppendLine("| 重复换章 | $($s.duplicate_chapter_change) |")
            [void]$sb.AppendLine("| 跳过章节 | $($s.skipped_chapter) |")
            [void]$sb.AppendLine('')
        }
        if (Test-MapContainsKey $Script:SummaryState.CsvStats 'd_multitouch') {
            $s = $Script:SummaryState.CsvStats['d_multitouch']
            [void]$sb.AppendLine('### 场景 D：双指干扰')
            [void]$sb.AppendLine("| 指标 | 次数 |")
            [void]$sb.AppendLine('|---|---:|')
            [void]$sb.AppendLine("| 完成次数 | $($s.completed) |")
            [void]$sb.AppendLine("| 双指后单指翻页成功 | $($s.post_multitouch_page_turn_success) |")
            [void]$sb.AppendLine("| 双指后单指翻页失败 | $($s.post_multitouch_page_turn_failure) |")
            [void]$sb.AppendLine("| 感觉被锁住 | $($s.felt_locked) |")
            [void]$sb.AppendLine("| 需再次触摸恢复 | $($s.needed_retouch) |")
            [void]$sb.AppendLine('')
        }
    }

    if (@($Script:SummaryState.ScenarioResults.Keys).Count -gt 0) {
        [void]$sb.AppendLine('## 场景日志质量')
        [void]$sb.AppendLine('| 场景 | 手势行 | 有效 JSON | 无效 JSON | gestureSummary |')
        [void]$sb.AppendLine('|---|---:|---:|---:|---:|')
        foreach ($def in (@($Script:MandatoryScenarios) + @($Script:OptionalScenarioDefinitions))) {
            if (Test-MapContainsKey $Script:SummaryState.ScenarioResults $def.Key) {
                $r = $Script:SummaryState.ScenarioResults[$def.Key]
                [void]$sb.AppendLine("| $($def.Letter) $($def.Title) | $($r.gestureLines) | $($r.validJson) | $($r.invalidJson) | $($r.summaries) |")
            }
        }
        [void]$sb.AppendLine('')
    }

    if (Test-Path $Script:OutputDir) {
        [void]$sb.AppendLine('## 输出文件')
        [void]$sb.AppendLine('```text')
        [void]$sb.AppendLine((Get-ChildItem -Path $Script:OutputDir | Sort-Object Name | ForEach-Object { $_.Name }) -join "`n")
        [void]$sb.AppendLine('```')
    }

    Write-TextFile -Path (Join-Path $Script:OutputDir 'summary.md') -Content $sb.ToString()
}

function Test-ScenarioDefinitionsConsistency {
    $errors = @()
    $all = @($Script:MandatoryScenarios) + @($Script:OptionalScenarioDefinitions)
    $prefixes = @{}

    foreach ($def in $all) {
        $paths = Get-ScenarioPaths -Definition $def -OutputDir 'C:\dummy\test_output'
        $expectedNames = @(
            "$($def.FilePrefix)_full.log",
            "$($def.FilePrefix)_gesture.log",
            "$($def.FilePrefix)_results.csv",
            "$($def.FilePrefix)_meta.json"
        )
        foreach ($name in $expectedNames) {
            $found = $false
            foreach ($p in $paths.Values) {
                if ((Split-Path $p -Leaf) -eq $name) { $found = $true; break }
            }
            if (-not $found) { $errors += "场景 $($def.Key) 缺少输出映射: $name" }
        }
        if ($prefixes.ContainsKey($def.FilePrefix)) {
            $errors += "重复 FilePrefix: $($def.FilePrefix)"
        }
        $prefixes[$def.FilePrefix] = $true

        if ($def.CsvHeader.Split(',') -notcontains 'status') {
            $errors += "场景 $($def.Key) CSV 缺少 status 列"
        }
    }

    foreach ($required in @('a_slow_drag','b_fast_swipe','c_edge_next','d_multitouch')) {
        if (($all | ForEach-Object { $_.Key }) -notcontains $required) {
            $errors += "缺少必测场景: $required"
        }
    }

    return $errors
}

function Invoke-DryRun {
    param([string]$ProjectRoot)

    Write-Status 'DryRun：验证场景定义、文件名与 CSV/summary 一致性（不连接真机）'
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:OutputDir = Join-Path $projectRoot "test_output\dryrun_$timestamp"
    New-Item -ItemType Directory -Path $Script:OutputDir -Force | Out-Null

    $defErrors = Test-ScenarioDefinitionsConsistency
    if (@($defErrors).Count -gt 0) {
        throw ("DryRun 场景定义错误:`n" + ($defErrors -join "`n"))
    }
    Write-Status "场景定义检查通过（$(@($Script:MandatoryScenarios).Count) 必测 + $(@($Script:OptionalScenarioDefinitions).Count) 可选）"

    foreach ($def in (@($Script:MandatoryScenarios) + @($Script:OptionalScenarioDefinitions))) {
        $paths = Get-ScenarioPaths -Definition $def -OutputDir $Script:OutputDir
        Initialize-Csv -Path $paths.Csv -Header $def.CsvHeader
        $headerFile = Get-Content -Path $paths.Csv -Encoding UTF8 -TotalCount 1
        if ($headerFile -ne $def.CsvHeader) {
            throw "CSV 表头不一致: $($def.Key) 期望 '$($def.CsvHeader)' 实际 '$headerFile'"
        }
    }
    Write-Status 'CSV 表头写入/读取一致'

    # 模拟各场景一行数据并验证 summary 统计
    Write-CsvRow -Path (Join-Path $Script:OutputDir 'scenario_a_slow_drag_results.csv') -Fields @('1','yes','no','no','t0','t1','dry','completed')
    Write-CsvRow -Path (Join-Path $Script:OutputDir 'scenario_b_fast_swipe_results.csv') -Fields @('1','no','yes','yes','no','t0','t1','dry','completed')
    Write-CsvRow -Path (Join-Path $Script:OutputDir 'scenario_c_edge_next_results.csv') -Fields @('1','yes','yes','no','no','t0','t1','dry','completed')
    Write-CsvRow -Path (Join-Path $Script:OutputDir 'scenario_d_multitouch_results.csv') -Fields @('1','yes','no','yes','yes','t0','t1','dry','completed')

    $Script:ExecutedScenarios.Clear()
    foreach ($d in $Script:MandatoryScenarios) { $Script:ExecutedScenarios.Add($d) | Out-Null }

    $stats = Compute-CsvStatistics -OutputDir $Script:OutputDir
    if ($stats['a_slow_drag'].page_turn_success -ne 1) { throw 'DryRun: 场景 A 统计异常' }
    if ($stats['b_fast_swipe'].not_recognized -ne 1) { throw 'DryRun: 场景 B 统计异常' }
    if ($stats['c_edge_next'].second_swipe_chapter_changed -ne 1) { throw 'DryRun: 场景 C 统计异常' }
    if ($stats['d_multitouch'].felt_locked -ne 1) { throw 'DryRun: 场景 D 统计异常' }
    Write-Status 'summary 统计逻辑验证通过'

  # 验证 UTF-8 gesture 日志筛选
    $sampleLog = "03-04 12:00:00.000 12345 12345 I flutter : [ReaderGesture] {""event"":""gestureSummary"",""gestureSessionId"":""gs-1""}`n"
    $samplePath = Join-Path $Script:OutputDir 'sample_full.log'
    Write-TextFile -Path $samplePath -Content $sampleLog
    $extracted = Extract-ReaderGestureLines -FullLogPath $samplePath
    if (@($extracted).Count -ne 1) { throw 'DryRun: ReaderGesture 筛选失败' }
    $line = @($extracted)[0]
    $obj = ($line.Substring($line.IndexOf('[ReaderGesture]') + 15).Trim()) | ConvertFrom-Json
    if ($obj.event -ne 'gestureSummary') { throw 'DryRun: JSON 解析失败' }
    Write-Status 'UTF-8 logcat 筛选与 JSON 解析通过'

    $Script:SummaryState.Status = 'dry-run-ok'
    $Script:SummaryState.Environment = @{ testStartTime = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); dryRun = 'yes' }
    Write-SummaryMarkdown -Final
    Write-Status "DryRun 完成: $Script:OutputDir"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

try {
    Register-CleanupHandlers

    $startDir = Get-Location
    $projectRoot = Find-ProjectRoot -StartDir $startDir
    if (-not $projectRoot) {
        $projectRoot = Find-ProjectRoot -StartDir (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    if (-not $projectRoot) { throw '无法定位 Flutter 项目根目录。' }
    Set-Location $projectRoot
    Write-Status "项目根目录: $projectRoot"

    if ($DryRun) {
        Initialize-RequiredTools -ProjectRoot $projectRoot
        Invoke-DryRun -ProjectRoot $projectRoot
        exit 0
    }

    if ($FinalizeOutputDir) {
        if (-not (Test-Path $FinalizeOutputDir)) { throw "目录不存在: $FinalizeOutputDir" }
        $Script:OutputDir = (Resolve-Path $FinalizeOutputDir).Path
        Write-Status "仅生成摘要: $Script:OutputDir"
        $Script:SummaryState.Environment = @{
            testStartTime = 'unknown'
            finalizeOnly  = 'yes'
            outputDir     = $Script:OutputDir
        }
        $envFile = Join-Path $Script:OutputDir 'environment.txt'
        if (Test-Path $envFile) {
            foreach ($line in (Get-Content $envFile -Encoding UTF8)) {
                if ($line -match '^([^=]+)=(.*)$') {
                    $Script:SummaryState.Environment[$matches[1]] = $matches[2]
                }
            }
        }
        Complete-TestRun -Status 'completed'
        Write-Status "完成: $(Join-Path $Script:OutputDir 'summary.md')"
        exit 0
    }

    Initialize-RequiredTools -ProjectRoot $projectRoot
    if (-not (Test-CommandAvailable 'flutter')) { throw 'flutter 不可用（请检查 PATH 或 android\local.properties 中的 flutter.sdk）' }
    if (-not (Test-CommandAvailable 'adb')) { throw 'adb 不可用（请检查 PATH 或 android\local.properties 中的 sdk.dir）' }
    Write-Status "flutter: $(Get-ToolExecutable 'flutter')"
    Write-Status "adb: $(Get-ToolExecutable 'adb')"

    $defErrors = Test-ScenarioDefinitionsConsistency
    if (@($defErrors).Count -gt 0) { throw ($defErrors -join "`n") }

    $resumeMode = [bool]$ResumeOutputDir
    if ($resumeMode) {
        if (-not (Test-Path $ResumeOutputDir)) { throw "续跑目录不存在: $ResumeOutputDir" }
        $Script:OutputDir = (Resolve-Path $ResumeOutputDir).Path
        Write-Status "续跑模式，输出目录: $Script:OutputDir"
        Show-ResumePlan -OutputDir $Script:OutputDir
    } else {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        if ($ExperimentIvBypass) {
            $Script:OutputDir = Join-Path $projectRoot "test_output\android_iv_experiment_$timestamp"
            $Script:ExperimentIvBypass = $true
        } else {
            $Script:OutputDir = Join-Path $projectRoot "test_output\android_$timestamp"
        }
        New-Item -ItemType Directory -Path $Script:OutputDir -Force | Out-Null
        Write-Status "输出目录: $Script:OutputDir"
    }

    $testStart = Get-Date
    $flutterVer = Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList @('--version') -AllowFailure
    $toolVersions = Parse-FlutterToolVersions -VersionText ($flutterVer.StdOut + "`n" + $flutterVer.StdErr)
    $gitCommit = 'unknown'; $gitDirty = 'unknown'
    if (Test-CommandAvailable 'git') {
        $c = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('rev-parse','HEAD') -WorkingDirectory $projectRoot -AllowFailure
        if ($c.ExitCode -eq 0) { $gitCommit = $c.StdOut.Trim() }
        $st = Invoke-ExternalCommand -FilePath 'git' -ArgumentList @('status','--porcelain') -WorkingDirectory $projectRoot -AllowFailure
        $gitDirty = if ($st.StdOut.Trim()) { 'yes (uncommitted changes present)' } else { 'no' }
    }

    if (-not $resumeMode) {
        Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList @('doctor','-v') -WorkingDirectory $projectRoot -StdOutFile (Join-Path $Script:OutputDir 'flutter_doctor.txt') -AllowFailure | Out-Null
        Write-Status 'flutter doctor 完成，枚举设备...'
        Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList @('devices') -WorkingDirectory $projectRoot -StdOutFile (Join-Path $Script:OutputDir 'flutter_devices.txt') -AllowFailure | Out-Null
    } else {
        Write-Status '续跑：跳过 flutter doctor / pub get / analyze / test / build / install'
    }

    Write-Status '选择 Android 真机...'
    $device = Select-AndroidDevice
    $deviceId = Get-FlutterDeviceId $device
    $Script:SelectedDeviceId = $deviceId
    $deviceInfo = Collect-DeviceInfo -DeviceId $deviceId
    $pubspecVer = Get-PubspecVersion -ProjectRoot $projectRoot
    $applicationId = 'top.fumiama.copymanga_flutter'

    $Script:SummaryState.Environment = [ordered]@{
        testStartTime = $testStart.ToString('yyyy-MM-dd HH:mm:ss')
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        flutterVersion = $toolVersions.Flutter
        dartVersion = $toolVersions.Dart
        gitCommit = $gitCommit
        gitDirty = $gitDirty
        applicationId = $applicationId
        deviceManufacturer = $deviceInfo.manufacturer
        deviceModel = $deviceInfo.model
        androidVersion = $deviceInfo.androidVersion
        apiLevel = $deviceInfo.apiLevel
        abi = $deviceInfo.abi
        resolution = $deviceInfo.resolution
        density = $deviceInfo.density
        refreshRate = $deviceInfo.refreshRate
        deviceIdMasked = $deviceInfo.deviceIdMasked
        resumeMode = $(if ($resumeMode) { 'yes' } else { 'no' })
        experimentIvBypass = $(if ($Script:ExperimentIvBypass) { 'yes' } else { 'no' })
    }

    if ($resumeMode) {
        Append-TextFile -Path (Join-Path $Script:OutputDir 'environment.txt') -Content ("resumeAt=$($testStart.ToString('yyyy-MM-dd HH:mm:ss'))`n")
    } else {
        Write-TextFile -Path (Join-Path $Script:OutputDir 'environment.txt') -Content (($Script:SummaryState.Environment.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n") + "`n"
    }

    $includeE = $false
    $includeF = $false

    if (-not $resumeMode) {
        Write-Status 'flutter pub get ...'
        $pubGet = Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList @('pub','get') -WorkingDirectory $projectRoot -AllowFailure
        Write-TextFile -Path (Join-Path $Script:OutputDir 'pub_get.txt') -Content ($pubGet.StdOut + "`n" + $pubGet.StdErr)
        $Script:SummaryState.Environment['pubGetExit'] = $pubGet.ExitCode
        Write-Status "flutter pub get 完成 (exit $($pubGet.ExitCode))"

        Write-Status 'flutter analyze ...（约 10–30 秒）'
        $analyze = Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList @('analyze') -WorkingDirectory $projectRoot -AllowFailure
        $analyzeLines = @($analyze.StdOut -split "`n") + @($analyze.StdErr -split "`n")
        Write-TextFile -Path (Join-Path $Script:OutputDir 'analyze.txt') -Content ($analyze.StdOut + "`n" + $analyze.StdErr)
        $Script:SummaryState.AnalyzeInfos = @(Get-AnalyzeIssueLines -Lines $analyzeLines -Severity 'info')
        $Script:SummaryState.AnalyzeWarnings = @(Get-AnalyzeIssueLines -Lines $analyzeLines -Severity 'warning')
        if (Test-AnalyzeHasErrors -Lines $analyzeLines) {
            $Script:SummaryState.Status = 'failed'
            $Script:SummaryState.FailReason = 'flutter analyze 存在 error'
            $Script:SummaryState.Environment['analyzeResult'] = 'FAILED'
            Write-SummaryMarkdown; throw $Script:SummaryState.FailReason
        }
        $Script:SummaryState.Environment['analyzeResult'] = "passed (info=$(@($Script:SummaryState.AnalyzeInfos).Count), warning=$(@($Script:SummaryState.AnalyzeWarnings).Count))"
        Write-Status 'flutter analyze 通过'

        Write-Status 'flutter test ...（约 15–30 秒）'
        $tests = Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList @('test') -WorkingDirectory $projectRoot -AllowFailure
        Write-TextFile -Path (Join-Path $Script:OutputDir 'tests.txt') -Content ($tests.StdOut + "`n" + $tests.StdErr)
        if ($tests.ExitCode -ne 0) {
            $Script:SummaryState.Status = 'failed'; $Script:SummaryState.FailReason = 'flutter test 失败'
            $Script:SummaryState.Environment['testResult'] = 'FAILED'; Write-SummaryMarkdown; throw $Script:SummaryState.FailReason
        }
        $Script:SummaryState.Environment['testResult'] = 'passed'
        Write-Status 'flutter test 通过'

        Write-Status 'flutter build apk --debug ...（约 30–90 秒，请耐心等待）'
        $buildArgs = @(
            'build','apk','--debug',
            "--dart-define=APP_VERSION_NAME=$($pubspecVer.Name)",
            "--dart-define=APP_VERSION_CODE=$($pubspecVer.Code)",
            "--dart-define=FLUTTER_SDK_VERSION=$($toolVersions.Flutter)"
        )
        if ($Script:ExperimentIvBypass) {
            $buildArgs += '--dart-define=READER_GESTURE_EXPERIMENT_BYPASS_IV_WHEN_UNZOOMED=true'
        }
        $build = Invoke-ExternalCommand -FilePath 'flutter' -ArgumentList $buildArgs -WorkingDirectory $projectRoot -AllowFailure
        Write-TextFile -Path (Join-Path $Script:OutputDir 'build.txt') -Content ($build.StdOut + "`n" + $build.StdErr)
        if ($build.ExitCode -ne 0) {
            $Script:SummaryState.Status = 'failed'; $Script:SummaryState.FailReason = 'build 失败'
            $Script:SummaryState.Environment['buildResult'] = 'FAILED'; Write-SummaryMarkdown; throw $Script:SummaryState.FailReason
        }
        $Script:SummaryState.Environment['buildResult'] = 'passed'
        Write-Status '构建完成'

        $apkPath = Find-DebugApk -ProjectRoot $projectRoot -DeviceAbi $deviceInfo.abi
        if (-not $apkPath) { throw '找不到 debug APK' }
        $Script:SummaryState.Environment['apkPath'] = $apkPath

        Write-Status "安装 APK: $apkPath"
        $install = Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('-s',$deviceId,'install','-r',$apkPath) -AllowFailure
        Write-TextFile -Path (Join-Path $Script:OutputDir 'install.txt') -Content ($install.StdOut + "`n" + $install.StdErr)
        if ($install.ExitCode -ne 0) {
            $Script:SummaryState.Status = 'failed'; $Script:SummaryState.FailReason = 'install 失败'
            $Script:SummaryState.Environment['installResult'] = 'FAILED'; Write-SummaryMarkdown; throw $Script:SummaryState.FailReason
        }
        $Script:SummaryState.Environment['installResult'] = 'passed'
        Write-Status '安装完成'

        $launcher = Resolve-LauncherActivity -DeviceId $deviceId -PackageId $applicationId
        $Script:SummaryState.Environment['launcherActivity'] = $launcher
        Write-Status "启动 App: $launcher"
        $launch = Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('-s',$deviceId,'shell','am','start','-n',$launcher) -AllowFailure
        Write-TextFile -Path (Join-Path $Script:OutputDir 'launch.txt') -Content ($launch.StdOut + "`n" + $launch.StdErr)
        if ($launch.ExitCode -ne 0) {
            $Script:SummaryState.Status = 'failed'; $Script:SummaryState.FailReason = 'launch 失败'
            $Script:SummaryState.Environment['launchResult'] = 'FAILED'; Write-SummaryMarkdown; throw $Script:SummaryState.FailReason
        }
        $Script:SummaryState.Environment['launchResult'] = 'passed'
        Write-Status 'App 已启动'

        Write-Host ''
        Write-Host '必测场景: A 慢速长拖 | B 快速短划 | C 尾页双滑下一章 | D 双指干扰'
        $includeE = ((Read-Host '是否执行可选场景 E（章节首页双滑上一章）? [y/N]').Trim().ToLowerInvariant() -eq 'y')
        $includeF = ((Read-Host '是否执行可选场景 F（轻滑与深滑对照）? [y/N]').Trim().ToLowerInvariant() -eq 'y')

        Write-Host '请手动进入阅读器；准备好后按 Enter 开始测试场景。'
        if ($Script:ExperimentIvBypass) {
            Write-Host '【实验模式】READER_GESTURE_EXPERIMENT_BYPASS_IV_WHEN_UNZOOMED=true'
            Write-Host '仅执行 E-A / E-B / E-Z，不匹配基线 A–D。'
        }
        [void](Read-Host)
    } else {
        $launcher = Resolve-LauncherActivity -DeviceId $deviceId -PackageId $applicationId
        $Script:SummaryState.Environment['launcherActivity'] = $launcher
        Write-Status "续跑：尝试唤起 App $launcher"
        $launch = Invoke-ExternalCommand -FilePath 'adb' -ArgumentList @('-s',$deviceId,'shell','am','start','-n',$launcher) -AllowFailure
        Append-TextFile -Path (Join-Path $Script:OutputDir 'launch.txt') -Content ("`n=== RESUME $($testStart.ToString('yyyy-MM-dd HH:mm:ss')) ===`n" + $launch.StdOut + "`n" + $launch.StdErr)
        Write-Host '请确认：横向模式、r2l=false、图片未放大，并停在章节尾页（场景 C）或章内页（场景 D）。'
        Write-Host '准备好后按 Enter 继续续跑...'
        [void](Read-Host)
    }

    if ($Script:ExperimentIvBypass) {
        foreach ($def in $Script:ExperimentScenarios) {
            Invoke-TestScenario -Definition $def -DeviceId $deviceId -OutputDir $Script:OutputDir
            if ($Script:StopRequested) { break }
        }
    } else {
        foreach ($def in $Script:MandatoryScenarios) {
            $progress = Get-ScenarioProgress -Definition $def -OutputDir $Script:OutputDir
            if ($progress.done) { continue }
            $startAt = $progress.completed + 1
            Invoke-TestScenario -Definition $def -DeviceId $deviceId -OutputDir $Script:OutputDir -StartAt $startAt
            if ($Script:StopRequested) { break }
        }
        if (-not $Script:StopRequested -and $includeE) {
            Invoke-TestScenario -Definition $Script:OptionalScenarioDefinitions[0] -DeviceId $deviceId -OutputDir $Script:OutputDir
            if ($Script:StopRequested) { }
        }
        if (-not $Script:StopRequested -and $includeF) {
            Invoke-TestScenario -Definition $Script:OptionalScenarioDefinitions[1] -DeviceId $deviceId -OutputDir $Script:OutputDir
        }
    }

    if ($Script:ExperimentIvBypass -and -not $Script:StopRequested) {
        Export-ReaderGestureJsonl -DeviceId $deviceId -OutputDir $Script:OutputDir -PackageId $applicationId
    }

    if ($Script:StopRequested) {
        Complete-TestRun -Status 'stopped_by_user'
        Write-Host ''
        Write-Status "测试已由用户停止。已保存场景 A–C 数据: $Script:OutputDir"
        exit 0
    }

    Complete-TestRun -Status 'completed'
    Write-Host ''
    Write-Status "全部完成。结果目录: $Script:OutputDir"
    Write-Host '请查看 summary.md 与 log_quality_check.txt。'

} catch {
    if ($Script:StopRequested) {
        try { Complete-TestRun -Status 'stopped_by_user' } catch { }
        Write-Host ''
        Write-Status "测试已由用户停止。结果目录: $Script:OutputDir"
        exit 0
    }
    if ($Script:SummaryState.Status -eq 'running') {
        $Script:SummaryState.Status = 'aborted'
        $Script:SummaryState.FailReason = $_.Exception.Message
    }
    try { Write-SummaryMarkdown -Final } catch { }
    Write-Error $_
    exit 1
} finally {
    Stop-OwnedProcesses
}
