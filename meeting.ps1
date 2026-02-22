[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path

$MeetingsDir = Join-Path $RootDir "knowledge/meetings"
$AudioDir = Join-Path $MeetingsDir "_audio"
$LogDir = Join-Path $MeetingsDir "log"
$PidFile = Join-Path $AudioDir ".recording.pid"
$InfoFile = Join-Path $AudioDir ".recording.info"
$TranscribePidFile = Join-Path $AudioDir ".transcribe.pid"
$TranscribeInfoFile = Join-Path $AudioDir ".transcribe.info"
$TranscribeTaskFile = Join-Path $AudioDir ".transcribe.task"
$TranscribeJobFile = Join-Path $AudioDir ".transcribe.job.json"
$TranscribeRunnerLogFile = Join-Path $AudioDir ".transcribe.runner.log"
$AsyncRunnerDir = Join-Path $env:LOCALAPPDATA "CodexMeeting"
$AsyncRunnerScript = Join-Path $AsyncRunnerDir "run-meeting-async.ps1"
$ScriptPath = $MyInvocation.MyCommand.Path
$CliArgs = @($CommandArgs)

if ($env:MEETING_DEBUG -eq "1") {
    $debugPath = Join-Path $AudioDir ".debug.args.txt"
    $debugLines = @(
        "Command=$Command"
        ("CommandArgsCount={0}" -f $CommandArgs.Count)
        ("CommandArgs={0}" -f ($CommandArgs -join " | "))
    )
    Set-Content -LiteralPath $debugPath -Value $debugLines -Encoding UTF8
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ""
    )

    $v = [Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not [string]::IsNullOrWhiteSpace($v)) {
        return $v
    }

    $v = [Environment]::GetEnvironmentVariable($Name, "User")
    if (-not [string]::IsNullOrWhiteSpace($v)) {
        return $v
    }

    $v = [Environment]::GetEnvironmentVariable($Name, "Machine")
    if (-not [string]::IsNullOrWhiteSpace($v)) {
        return $v
    }

    return $Default
}

$KeepAudio = if ($env:MEETING_KEEP_AUDIO) { $env:MEETING_KEEP_AUDIO } else { "0" }
$WhisperModel = if ($env:MEETING_WHISPER_MODEL) { $env:MEETING_WHISPER_MODEL } else { "small" }
$WhisperLang = if ($env:MEETING_WHISPER_LANGUAGE) { $env:MEETING_WHISPER_LANGUAGE } else { "Japanese" }
$WindowsForcedInputDevice = Get-ConfigValue -Name "MEETING_WINDOWS_FORCE_INPUT_DEVICE" -Default "マイク (Logi C270 HD WebCam)"
$WebInputGainSystem = if ($env:MEETING_WEB_INPUT_GAIN_SYSTEM) { $env:MEETING_WEB_INPUT_GAIN_SYSTEM } elseif ($env:MEETING_WEB_INPUT_GAIN_BLACKHOLE) { $env:MEETING_WEB_INPUT_GAIN_BLACKHOLE } else { "1.0" }
$WebInputGainMic = if ($env:MEETING_WEB_INPUT_GAIN_MIC) { $env:MEETING_WEB_INPUT_GAIN_MIC } else { "1.0" }
$WebAutoLevel = if ($env:MEETING_WEB_AUTO_LEVEL) { $env:MEETING_WEB_AUTO_LEVEL } else { "1" }
$WebLimiter = if ($env:MEETING_WEB_LIMITER) { $env:MEETING_WEB_LIMITER } else { "1" }
$WebLimiterFilter = if ($env:MEETING_WEB_LIMITER_FILTER) { $env:MEETING_WEB_LIMITER_FILTER } else { "alimiter=limit=0.95:attack=5:release=50" }
$TranscribeRunnerTaskName = Get-ConfigValue -Name "MEETING_TRANSCRIBE_TASK_NAME" -Default "CodexMeetingTranscribeRunner"

function Ensure-Dirs {
    $dirs = @(
        $MeetingsDir,
        $AudioDir,
        $LogDir,
        (Join-Path $MeetingsDir "社内"),
        (Join-Path $MeetingsDir "商談"),
        (Join-Path $MeetingsDir "private"),
        (Join-Path $MeetingsDir "side-business"),
        (Join-Path $MeetingsDir "activities"),
        (Join-Path $MeetingsDir "thoughts"),
        (Join-Path $MeetingsDir "life")
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

function Show-Help {
    @"
Meeting Recording Tool (Windows)

使い方:
  .\tools\meeting\meeting.ps1 start "会議名" --商談
  .\tools\meeting\meeting.ps1 start "会議名" --社内
  .\tools\meeting\meeting.ps1 start "会議名" --社内 --web
  .\tools\meeting\meeting.ps1 stop [--async]
  .\tools\meeting\meeting.ps1 setup-async
  .\tools\meeting\meeting.ps1 status
  .\tools\meeting\meeting.ps1 list
  .\tools\meeting\meeting.ps1 devices

補足:
  - Windows版は ffmpeg(dshow) で録音します
  - 非Web録音は MEETING_WINDOWS_FORCE_INPUT_DEVICE（既定: マイク (Logi C270 HD WebCam)）を優先します
  - --web は「相手音声(VB-CABLE等) + マイク」の2入力ミックス録音です
  - 相手音声入力: MEETING_WEB_INPUT_DEVICE（例: CABLE Output (VB-Audio Virtual Cable)）
  - マイク入力: MEETING_WEB_MIC_DEVICE（未指定時はマイクらしいデバイスを自動選択）
  - 文字起こしは whisper / python -m whisper / py -3 -m whisper を順に探索します
  - stop --async は停止後の文字起こしをバックグラウンド実行します（状態確認: status）
  - --async は固定runnerタスク（schtasks）を使って PowerShell 親プロセスから分離起動します
"@
}

function Ensure-Dependency {
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw "ffmpeg が見つかりません。インストール後に再実行してください。"
    }
}

function Get-DShowAudioDevices {
    $lines = & ffmpeg -list_devices true -f dshow -i dummy 2>&1
    $devices = @()
    foreach ($line in $lines) {
        if ($line -match '"(.+?)"\s+\(audio\)') {
            $devices += $matches[1]
        }
    }
    return $devices | Select-Object -Unique
}

function Find-FirstDeviceByPatterns {
    param(
        [string[]]$Devices,
        [string[]]$IncludePatterns,
        [string[]]$ExcludePatterns = @()
    )

    foreach ($device in $Devices) {
        $ok = $false
        foreach ($pattern in $IncludePatterns) {
            if ($device -match $pattern) {
                $ok = $true
                break
            }
        }
        if (-not $ok) {
            continue
        }
        $excluded = $false
        foreach ($pattern in $ExcludePatterns) {
            if ($device -match $pattern) {
                $excluded = $true
                break
            }
        }
        if (-not $excluded) {
            return $device
        }
    }
    return ""
}

function Resolve-InputDevice {
    param(
        [string]$WebMode
    )

    $devices = @(Get-DShowAudioDevices)
    if ($devices.Count -eq 0) {
        throw "録音デバイスが見つかりません。ffmpegのdshowデバイス一覧を確認してください。"
    }

    if (-not $WebMode) {
        $forced = $WindowsForcedInputDevice
        if (-not [string]::IsNullOrWhiteSpace($forced)) {
            foreach ($d in $devices) {
                if ($d -eq $forced) {
                    return $d
                }
            }
            foreach ($d in $devices) {
                if ($d -like "*$forced*") {
                    return $d
                }
            }

            $found = $devices -join ", "
            throw "固定入力デバイス '$forced' が見つかりません。接続またはデバイス名を確認してください。検出デバイス: $found"
        }
    }

    $requested = ""
    if ($WebMode) {
        $requested = Get-ConfigValue -Name "MEETING_WEB_INPUT_DEVICE"
    } else {
        $requested = Get-ConfigValue -Name "MEETING_WINDOWS_INPUT_DEVICE"
    }

    if ($requested) {
        foreach ($d in $devices) {
            if ($d -eq $requested) {
                return $d
            }
        }
        foreach ($d in $devices) {
            if ($d -like "*$requested*") {
                return $d
            }
        }
        Write-Warning "指定デバイス '$requested' が見つからないため既定デバイスを使用します。"
    }

    $micCandidate = Find-FirstDeviceByPatterns -Devices $devices -IncludePatterns @(
        "Microphone",
        "マイク",
        "(^| )Mic( |$)",
        "Headset"
    ) -ExcludePatterns @(
        "Loopback",
        "CABLE Output",
        "VB-Audio",
        "Stereo Mix",
        "ステレオ[ ]*ミキサ",
        "Wave Out Mix",
        "^In[ ]*[0-9]+-[0-9]+"
    )
    if ($micCandidate) {
        return $micCandidate
    }

    return $devices[0]
}

function Resolve-WebAudioDevices {
    $devices = @(Get-DShowAudioDevices)
    if ($devices.Count -eq 0) {
        throw "録音デバイスが見つかりません。ffmpegのdshowデバイス一覧を確認してください。"
    }

    $remoteRequested = Get-ConfigValue -Name "MEETING_WEB_INPUT_DEVICE"
    $micRequested = Get-ConfigValue -Name "MEETING_WEB_MIC_DEVICE"

    $remoteDevice = ""
    if ($remoteRequested) {
        if ($devices -contains $remoteRequested) {
            $remoteDevice = $remoteRequested
        } else {
            Write-Warning "MEETING_WEB_INPUT_DEVICE '$remoteRequested' が見つからないため自動選択します。"
        }
    }
    if (-not $remoteDevice) {
        $remoteDevice = Find-FirstDeviceByPatterns -Devices $devices -IncludePatterns @(
            "Loopback",
            "CABLE Output",
            "VB-Audio",
            "Stereo Mix",
            "ステレオ[ ]*ミキサ",
            "Wave Out Mix"
        )
    }
    if (-not $remoteDevice) {
        $remoteDevice = $devices[0]
        Write-Warning "相手音声用の仮想入力が見つからないため '$remoteDevice' を使用します。"
    }

    $micDevice = ""
    if ($micRequested) {
        if ($devices -contains $micRequested) {
            $micDevice = $micRequested
        } else {
            Write-Warning "MEETING_WEB_MIC_DEVICE '$micRequested' が見つからないため自動選択します。"
        }
    }
    if (-not $micDevice) {
        $micDevice = Find-FirstDeviceByPatterns -Devices $devices -IncludePatterns @(
            "Microphone",
            "マイク",
            "(^| )Mic( |$)",
            "Headset"
        ) -ExcludePatterns @(
            "Loopback",
            "CABLE Output",
            "VB-Audio",
            "Stereo Mix",
            "ステレオ[ ]*ミキサ",
            "Wave Out Mix"
        )
    }
    if (-not $micDevice) {
        $fallback = @($devices | Where-Object { $_ -ne $remoteDevice })
        if ($fallback.Count -gt 0) {
            $micDevice = $fallback[0]
        }
    }

    $mixEnabled = $false
    if ($micDevice -and $micDevice -ne $remoteDevice) {
        $mixEnabled = $true
    } else {
        if ($micDevice -eq $remoteDevice) {
            Write-Warning "相手音声とマイクが同一デバイスのため単一入力録音になります。"
        } else {
            Write-Warning "マイク候補が見つからないため単一入力録音になります。"
        }
    }

    return @{
        RemoteDevice = $remoteDevice
        MicDevice = $micDevice
        MixEnabled = $mixEnabled
    }
}

function Show-AudioDevices {
    Ensure-Dependency
    $devices = @(Get-DShowAudioDevices)
    Write-Host ""
    Write-Host "===== dshow audio devices ====="
    if ($devices.Count -eq 0) {
        Write-Host "  (なし)"
        return
    }
    foreach ($d in $devices) {
        Write-Host "  - $d"
    }
    Write-Host ""
}

function ConvertTo-ProcessArgumentString {
    param([string[]]$ArgList)

    $quoted = foreach ($a in $ArgList) {
        if ($a -match '[\s"`]') {
            '"' + ($a -replace '"', '\"') + '"'
        } else {
            $a
        }
    }
    return ($quoted -join " ")
}

function Parse-IntOrDefault {
    param(
        [string]$Value,
        [int]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }
    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Parse-DoubleOrDefault {
    param(
        [string]$Value,
        [double]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }
    $parsed = 0.0
    if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function Format-Seconds {
    param([double]$Value)
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", $Value)
}

function Write-RunnerLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $TranscribeRunnerLogFile -Value "[$ts] $Message" -Encoding UTF8
}

function Get-ProcessFromPidFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    $pidValue = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$pidValue)) {
        return $null
    }
    return Get-Process -Id $pidValue -ErrorAction SilentlyContinue
}

function Clear-TranscribeState {
    Remove-Item -LiteralPath $TranscribePidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TranscribeInfoFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TranscribeTaskFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TranscribeJobFile -Force -ErrorAction SilentlyContinue
}

function Remove-TaskSafe {
    param([string]$TaskName)
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        return
    }
    & schtasks /Delete /TN $TaskName /F *> $null
}

function Test-TaskExists {
    param([string]$TaskName)
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        return $false
    }
    & schtasks /Query /TN $TaskName *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-RunnerShellExecutable {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw "pwsh が見つかりません。stop --async には PowerShell 7 (pwsh) が必要です。"
    }
    return $pwsh.Source
}

function Ensure-AsyncRunnerScript {
    if (-not (Test-Path -LiteralPath $AsyncRunnerDir)) {
        New-Item -ItemType Directory -Path $AsyncRunnerDir -Force | Out-Null
    }

    $escapedScriptPath = $ScriptPath -replace "'", "''"
    $escapedJobPath = $TranscribeJobFile -replace "'", "''"
    $content = @(
        '$ErrorActionPreference = ''Stop'''
        'try {'
        '  & ''' + $escapedScriptPath + ''' _process-job ''' + $escapedJobPath + ''''
        '  exit 0'
        '} catch {'
        '  Write-Error $_'
        '  exit 1'
        '}'
    )
    Set-Content -LiteralPath $AsyncRunnerScript -Value $content -Encoding Unicode
}

function Ensure-TranscribeRunnerTask {
    Ensure-AsyncRunnerScript
    $runnerExe = Get-RunnerShellExecutable

    if (Test-TaskExists -TaskName $TranscribeRunnerTaskName) {
        $queryText = (& schtasks /Query /TN $TranscribeRunnerTaskName /V /FO LIST 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $queryText -like "*$AsyncRunnerScript*" -and $queryText -like "*$runnerExe*") {
            return
        }
        Remove-TaskSafe -TaskName $TranscribeRunnerTaskName
    }

    $taskCommand = "`"$runnerExe`" -NoProfile -ExecutionPolicy Bypass -File `"$AsyncRunnerScript`""
    $createOutput = (& schtasks /Create /TN $TranscribeRunnerTaskName /SC ONCE /SD 2099/12/31 /ST 23:59 /TR $taskCommand /F 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace($createOutput)) {
            throw "runnerタスクの作成に失敗しました。"
        }
        throw "runnerタスクの作成に失敗しました: $createOutput"
    }
}

function Start-TranscriptionWorkerViaTaskScheduler {
    param(
        [Parameter(Mandatory = $true)][string]$AudioFile,
        [Parameter(Mandatory = $true)][string]$Filename,
        [Parameter(Mandatory = $true)][string]$MeetingName,
        [string]$Category = ""
    )

    Ensure-TranscribeRunnerTask

    $payload = @{
        audioFile = $AudioFile
        filename = $Filename
        meetingName = $MeetingName
        category = $Category
        taskName = $TranscribeRunnerTaskName
    } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $TranscribeJobFile -Value $payload -Encoding UTF8

    $runOutput = (& schtasks /Run /TN $TranscribeRunnerTaskName 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace($runOutput)) {
            throw "非同期タスクの起動に失敗しました。"
        }
        throw "非同期タスクの起動に失敗しました: $runOutput"
    }

    Set-Content -LiteralPath $TranscribeTaskFile -Value $TranscribeRunnerTaskName -Encoding UTF8
    $meta = "会議名=$MeetingName / 音声=$AudioFile / task=$TranscribeRunnerTaskName / job=$TranscribeJobFile"
    Set-Content -LiteralPath $TranscribeInfoFile -Value $meta -Encoding UTF8

    Write-Host "文字起こしをバックグラウンドで開始しました (Task=$TranscribeRunnerTaskName)"
    Write-Host "状態確認: .\tools\meeting\meeting.ps1 status"
}

function Resolve-WhisperPriorityClass {
    $raw = Get-ConfigValue -Name "MEETING_WHISPER_PRIORITY" -Default "BelowNormal"
    switch ($raw.ToLowerInvariant()) {
        "idle" { return [System.Diagnostics.ProcessPriorityClass]::Idle }
        "belownormal" { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        "normal" { return [System.Diagnostics.ProcessPriorityClass]::Normal }
        "abovenormal" { return [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
        "high" { return [System.Diagnostics.ProcessPriorityClass]::High }
        default {
            Write-Warning "MEETING_WHISPER_PRIORITY='$raw' は不正なため BelowNormal を使用します。"
            return [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        }
    }
}

function Set-ProcessPrioritySafe {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessPriorityClass]$PriorityClass,
        [string]$Context = "process"
    )

    try {
        if (-not $Process.HasExited) {
            $Process.PriorityClass = $PriorityClass
        }
    } catch {
        Write-Warning "$Context の優先度設定に失敗しました: $($_.Exception.Message)"
    }
}

function Get-AudioDurationSeconds {
    param([Parameter(Mandatory = $true)][string]$AudioFile)

    $durationRaw = ""
    try {
        $durationRaw = (& ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $AudioFile 2>$null | Select-Object -First 1)
    } catch {
        return 0.0
    }
    if ([string]::IsNullOrWhiteSpace($durationRaw)) {
        return 0.0
    }
    $duration = 0.0
    if ([double]::TryParse($durationRaw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
        return $duration
    }
    return 0.0
}

function Prepare-AudioForTranscription {
    param(
        [Parameter(Mandatory = $true)][string]$AudioFile,
        [Parameter(Mandatory = $true)][string]$Filename
    )

    $trimEnabled = Parse-IntOrDefault -Value (Get-ConfigValue -Name "MEETING_TRIM_SILENCE" -Default "1") -Default 1
    if ($trimEnabled -ne 1) {
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }

    $noiseDb = Parse-DoubleOrDefault -Value (Get-ConfigValue -Name "MEETING_TRIM_NOISE_DB" -Default "-45") -Default -45.0
    $silenceMin = Parse-DoubleOrDefault -Value (Get-ConfigValue -Name "MEETING_TRIM_SILENCE_DURATION" -Default "0.7") -Default 0.7
    $trailingMin = Parse-DoubleOrDefault -Value (Get-ConfigValue -Name "MEETING_TRIM_TRAILING_MIN_SECONDS" -Default "8") -Default 8.0
    $leadingMax = Parse-DoubleOrDefault -Value (Get-ConfigValue -Name "MEETING_TRIM_LEADING_MAX_SECONDS" -Default "10") -Default 10.0

    $duration = Get-AudioDurationSeconds -AudioFile $AudioFile
    if ($duration -le 0.0) {
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }

    $noiseSpec = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.###}dB", $noiseDb)
    $minSpec = Format-Seconds -Value $silenceMin
    $detectFilter = "silencedetect=noise=$noiseSpec:d=$minSpec"
    $detectLines = @()
    try {
        $detectLines = & ffmpeg -hide_banner -i $AudioFile -af $detectFilter -f null NUL 2>&1
    } catch {
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }

    $silenceStarts = New-Object System.Collections.Generic.List[double]
    $silenceEnds = New-Object System.Collections.Generic.List[double]
    foreach ($line in $detectLines) {
        if ($line -match 'silence_start:\s*([0-9.]+)') {
            $value = 0.0
            if ([double]::TryParse($matches[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                $silenceStarts.Add($value)
            }
        }
        if ($line -match 'silence_end:\s*([0-9.]+)') {
            $value = 0.0
            if ([double]::TryParse($matches[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                $silenceEnds.Add($value)
            }
        }
    }

    $leadTrim = 0.0
    if ($silenceStarts.Count -gt 0 -and [math]::Abs($silenceStarts[0]) -lt 0.05 -and $silenceEnds.Count -gt 0) {
        $candidate = $silenceEnds[0]
        if ($candidate -ge 0.5 -and $candidate -le $leadingMax) {
            $leadTrim = $candidate
        }
    }

    $tailTrim = 0.0
    $trimEnd = $duration
    if ($silenceStarts.Count -gt 0) {
        $lastStart = $silenceStarts[$silenceStarts.Count - 1]
        $lastEnd = -1.0
        if ($silenceEnds.Count -gt 0) {
            $lastEnd = $silenceEnds[$silenceEnds.Count - 1]
        }
        $silenceToEnd = [math]::Max(0.0, $duration - $lastStart)
        $tailLooksTrailing = ($lastEnd -le $lastStart) -or ([math]::Abs($duration - $lastEnd) -le 1.0)
        if ($silenceToEnd -ge $trailingMin -and $tailLooksTrailing) {
            $tailTrim = $silenceToEnd
            $trimEnd = $lastStart
        }
    }

    if ($leadTrim -le 0.0 -and $tailTrim -le 0.0) {
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }

    $trimmedDuration = $trimEnd - $leadTrim
    if ($trimmedDuration -lt 10.0 -or $trimmedDuration -ge $duration) {
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }

    $trimmedFile = Join-Path $AudioDir "${Filename}.transcribe.wav"
    Remove-Item -LiteralPath $trimmedFile -Force -ErrorAction SilentlyContinue

    $startSpec = Format-Seconds -Value $leadTrim
    $endSpec = Format-Seconds -Value $trimEnd
    $trimFilter = "atrim=start=$startSpec:end=$endSpec,asetpts=PTS-STARTPTS"
    try {
        & ffmpeg -y -i $AudioFile -af $trimFilter -acodec pcm_s16le -ar 16000 $trimmedFile *> $null
    } catch {
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }

    if (-not (Test-Path -LiteralPath $trimmedFile)) {
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }
    $trimmedSize = (Get-Item -LiteralPath $trimmedFile).Length
    if ($trimmedSize -le 0) {
        Remove-Item -LiteralPath $trimmedFile -Force -ErrorAction SilentlyContinue
        return @{
            Path = $AudioFile
            WasTrimmed = $false
            LeadTrim = 0.0
            TailTrim = 0.0
        }
    }

    return @{
        Path = $trimmedFile
        WasTrimmed = $true
        LeadTrim = $leadTrim
        TailTrim = $tailTrim
    }
}

function Resolve-WhisperRunner {
    if ($env:MEETING_WHISPER_BIN) {
        return @{ File = $env:MEETING_WHISPER_BIN; Prefix = @() }
    }
    if (Get-Command whisper -ErrorAction SilentlyContinue) {
        return @{ File = "whisper"; Prefix = @() }
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return @{ File = "python"; Prefix = @("-m", "whisper") }
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
        return @{ File = "py"; Prefix = @("-3", "-m", "whisper") }
    }
    throw "whisper が見つかりません。'pip install openai-whisper' を実行してください。"
}

function Invoke-Whisper {
    param(
        [Parameter(Mandatory = $true)][string]$AudioFile,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $runner = Resolve-WhisperRunner
    $args = @()
    $args += $runner.Prefix
    $args += @(
        $AudioFile,
        "--language", $WhisperLang,
        "--model", $WhisperModel,
        "--verbose", "False",
        "--output_format", "txt",
        "--output_dir", $OutputDir
    )
    $argString = ConvertTo-ProcessArgumentString -ArgList $args
    $origPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    try {
        $proc = Start-Process -FilePath $runner.File -ArgumentList $argString -WindowStyle Hidden -PassThru
        $priorityClass = Resolve-WhisperPriorityClass
        Set-ProcessPrioritySafe -Process $proc -PriorityClass $priorityClass -Context "Whisper"
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            throw "文字起こしに失敗しました (exit=$($proc.ExitCode))。"
        }
    } finally {
        if ($null -eq $origPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        } else {
            $env:PYTHONIOENCODING = $origPythonIoEncoding
        }
    }
}

function Sanitize-FileName {
    param([string]$Name)
    $safe = $Name -replace '^[0-9]{4}[-/]?[0-9]{2}[-/]?[0-9]{2}[_ -]*', ''
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = $Name
    }
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "無題"
    }
    $safe = $safe.Trim()
    $safe = $safe -replace '[\\/:*?"<>|]', "_"
    $safe = $safe -replace '\s+', "_"
    return $safe.Trim("_")
}

function Parse-StartOptions {
    param([string[]]$ArgList)

    $result = @{
        Category = ""
        StorageArea = ""
        ProjectName = ""
        WebMode = ""
        Platform = ""
    }

    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $token = $ArgList[$i]
        switch ($token) {
            "--商談" { $result.Category = "商談"; $result.StorageArea = "work" }
            "-商談" { $result.Category = "商談"; $result.StorageArea = "work" }
            "--shoudan" { $result.Category = "商談"; $result.StorageArea = "work" }
            "-shoudan" { $result.Category = "商談"; $result.StorageArea = "work" }
            "--社内" { $result.Category = "社内"; $result.StorageArea = "work" }
            "-社内" { $result.Category = "社内"; $result.StorageArea = "work" }
            "--shanai" { $result.Category = "社内"; $result.StorageArea = "work" }
            "-shanai" { $result.Category = "社内"; $result.StorageArea = "work" }
            "--プライベート" { $result.Category = "プライベート"; $result.StorageArea = "private" }
            "-プライベート" { $result.Category = "プライベート"; $result.StorageArea = "private" }
            "--private" { $result.Category = "プライベート"; $result.StorageArea = "private" }
            "-private" { $result.Category = "プライベート"; $result.StorageArea = "private" }
            "--side-business" {
                $result.StorageArea = "side-business"
                if ($i + 1 -lt $ArgList.Count -and -not $ArgList[$i + 1].StartsWith("-")) {
                    $result.ProjectName = $ArgList[$i + 1]
                    $i++
                }
            }
            "-side-business" {
                $result.StorageArea = "side-business"
                if ($i + 1 -lt $ArgList.Count -and -not $ArgList[$i + 1].StartsWith("-")) {
                    $result.ProjectName = $ArgList[$i + 1]
                    $i++
                }
            }
            "--activity" { $result.StorageArea = "activity" }
            "-activity" { $result.StorageArea = "activity" }
            "--thoughts" { $result.StorageArea = "thoughts" }
            "-thoughts" { $result.StorageArea = "thoughts" }
            "--life" { $result.StorageArea = "life" }
            "-life" { $result.StorageArea = "life" }
            "--auto" { $result.StorageArea = "auto" }
            "-auto" { $result.StorageArea = "auto" }
            "--web" { $result.WebMode = "web" }
            "-web" { $result.WebMode = "web" }
            "--WEB" { $result.WebMode = "web" }
            "-WEB" { $result.WebMode = "web" }
            "--platform" {
                if ($i + 1 -lt $ArgList.Count) {
                    $result.Platform = $ArgList[$i + 1]
                    $i++
                }
            }
            "-platform" {
                if ($i + 1 -lt $ArgList.Count) {
                    $result.Platform = $ArgList[$i + 1]
                    $i++
                }
            }
        }
    }

    return $result
}

function Has-Flag {
    param(
        [string[]]$Args,
        [Parameter(Mandatory = $true)][string]$LongFlag
    )

    if ($Args -contains $LongFlag) {
        return $true
    }
    if ($LongFlag.StartsWith("--")) {
        $shortStyle = "-" + $LongFlag.Substring(2)
        if ($Args -contains $shortStyle) {
            return $true
        }
    }
    return $false
}

function Start-Recording {
    param(
        [Parameter(Mandatory = $true)][string]$MeetingName,
        [string[]]$StartArgs = @()
    )

    if ([string]::IsNullOrWhiteSpace($MeetingName)) {
        throw "会議名を指定してください。"
    }

    if (Test-Path -LiteralPath $PidFile) {
        throw "既に録音中です。先に stop を実行してください。"
    }

    Ensure-Dependency
    $opt = Parse-StartOptions -ArgList $StartArgs

    $dateStr = Get-Date -Format "yyyy-MM-dd_HHmm"
    $safeName = Sanitize-FileName -Name $MeetingName
    $filename = "${dateStr}_${safeName}"
    $audioFile = Join-Path $AudioDir "${filename}.wav"
    $ffArgs = @()
    $inputLabel = ""
    $mixLabel = ""

    if ($opt.WebMode) {
        $webDevices = Resolve-WebAudioDevices
        $remoteDevice = [string]$webDevices.RemoteDevice
        $micDevice = [string]$webDevices.MicDevice
        $mixEnabled = [bool]$webDevices.MixEnabled

        if ($mixEnabled) {
            $filter = "[0:a]volume=$WebInputGainSystem[sys];[1:a]volume=$WebInputGainMic[mic];[sys][mic]amix=inputs=2:duration=longest:dropout_transition=2[mix]"
            if ($WebAutoLevel -eq "1") {
                $filter += ";[mix]dynaudnorm[mix2]"
            } else {
                $filter += ";[mix]anull[mix2]"
            }
            if ($WebLimiter -eq "1") {
                $filter += ";[mix2]$WebLimiterFilter[out]"
            } else {
                $filter += ";[mix2]anull[out]"
            }
            $ffArgs = @(
                "-f", "dshow",
                "-i", "audio=$remoteDevice",
                "-f", "dshow",
                "-i", "audio=$micDevice",
                "-filter_complex", $filter,
                "-map", "[out]",
                "-acodec", "pcm_s16le",
                "-ar", "16000",
                $audioFile
            )
            $inputLabel = "$remoteDevice + $micDevice"
            $mixLabel = "2入力ミックス"
        } else {
            $ffArgs = @(
                "-f", "dshow",
                "-i", "audio=$remoteDevice",
                "-acodec", "pcm_s16le",
                "-ar", "16000",
                $audioFile
            )
            $inputLabel = $remoteDevice
            $mixLabel = "単一入力"
        }
    } else {
        $device = Resolve-InputDevice -WebMode $opt.WebMode
        $ffArgs = @(
            "-f", "dshow",
            "-i", "audio=$device",
            "-acodec", "pcm_s16le",
            "-ar", "16000",
            $audioFile
        )
        $inputLabel = $device
    }

    $ffArgString = ConvertTo-ProcessArgumentString -ArgList $ffArgs
    $ffmpegLog = Join-Path $AudioDir "${filename}.ffmpeg.log"
    Remove-Item -LiteralPath $ffmpegLog -Force -ErrorAction SilentlyContinue

    if ($env:MEETING_DEBUG -eq "1") {
        Write-Host "DEBUG web_mode=[$($opt.WebMode)]"
        Write-Host "DEBUG args=[$ffArgString]"
    }

    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffArgString -WindowStyle Hidden -PassThru -RedirectStandardError $ffmpegLog
    Start-Sleep -Seconds 1
    if ($proc.HasExited) {
        $logTail = ""
        if (Test-Path -LiteralPath $ffmpegLog) {
            $logTail = (Get-Content -LiteralPath $ffmpegLog -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
        }
        throw "録音開始に失敗しました。入力: $inputLabel`nffmpeg: $ffArgString`n$logTail"
    }

    $startEpoch = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding UTF8
    $info = @(
        $filename, $MeetingName, $opt.Category, $opt.StorageArea, $opt.ProjectName, $opt.Platform, $opt.WebMode, $startEpoch
    ) -join "|"
    Set-Content -LiteralPath $InfoFile -Value $info -Encoding UTF8

    Write-Host ""
    Write-Host "録音を開始しました"
    Write-Host "  会議名: $MeetingName"
    Write-Host "  カテゴリ: $($opt.Category)"
    if ($opt.WebMode) {
        Write-Host "  モード: WEB会議 ($mixLabel)"
    }
    Write-Host "  入力: $inputLabel"
    Write-Host "停止するには: .\tools\meeting\meeting.ps1 stop"
}

function Process-Recording {
    param(
        [Parameter(Mandatory = $true)][string]$AudioFile,
        [Parameter(Mandatory = $true)][string]$Filename,
        [Parameter(Mandatory = $true)][string]$MeetingName,
        [string]$Category = ""
    )

    Write-Host "文字起こしを開始します..."
    $prepared = Prepare-AudioForTranscription -AudioFile $AudioFile -Filename $Filename
    $audioForWhisper = [string]$prepared.Path
    $cleanupTrimmedFile = ""
    if ($prepared.WasTrimmed) {
        $cleanupTrimmedFile = $audioForWhisper
        $leadSec = Format-Seconds -Value ([double]$prepared.LeadTrim)
        $tailSec = Format-Seconds -Value ([double]$prepared.TailTrim)
        Write-Host "  無音トリミング: 先頭 ${leadSec}s / 末尾 ${tailSec}s"
    }

    try {
        Invoke-Whisper -AudioFile $audioForWhisper -OutputDir $AudioDir
    } finally {
        if ($cleanupTrimmedFile -and (Test-Path -LiteralPath $cleanupTrimmedFile)) {
            Remove-Item -LiteralPath $cleanupTrimmedFile -Force -ErrorAction SilentlyContinue
        }
    }

    $actualTranscriptFile = Join-Path $AudioDir ("{0}.txt" -f [System.IO.Path]::GetFileNameWithoutExtension($audioForWhisper))
    $transcriptFile = Join-Path $AudioDir "${Filename}.txt"
    if (-not (Test-Path -LiteralPath $actualTranscriptFile)) {
        throw "文字起こしファイルが生成されませんでした: $actualTranscriptFile"
    }
    if ($actualTranscriptFile -ne $transcriptFile) {
        Move-Item -LiteralPath $actualTranscriptFile -Destination $transcriptFile -Force
    }

    $transcriptSize = (Get-Item -LiteralPath $transcriptFile).Length
    if ($transcriptSize -eq 0) {
        throw "文字起こし結果が空でした。録音音声を保持したので確認してください: $AudioFile"
    }

    Write-Host ""
    Write-Host "文字起こしが完了しました"
    Write-Host "  会議名: $MeetingName"
    Write-Host "  カテゴリ: $Category"
    Write-Host "  文字起こし: $transcriptFile"

    if ($KeepAudio -ne "1" -and (Test-Path -LiteralPath $AudioFile)) {
        Remove-Item -LiteralPath $AudioFile -Force -ErrorAction SilentlyContinue
    }
}

function Show-Status {
    $recordingProc = Get-ProcessFromPidFile -Path $PidFile
    $transcribeProc = Get-ProcessFromPidFile -Path $TranscribePidFile
    $taskName = ""
    if (Test-Path -LiteralPath $TranscribeTaskFile) {
        $taskName = Get-Content -LiteralPath $TranscribeTaskFile -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ((-not $transcribeProc) -and (-not [string]::IsNullOrWhiteSpace($taskName))) {
        if (-not (Test-TaskExists -TaskName $taskName)) {
            $taskName = ""
            Clear-TranscribeState
        }
    }

    if ((-not $transcribeProc) -and ([string]::IsNullOrWhiteSpace($taskName)) -and ((Test-Path -LiteralPath $TranscribePidFile) -or (Test-Path -LiteralPath $TranscribeInfoFile))) {
        Clear-TranscribeState
    }

    Write-Host ""
    Write-Host "===== meeting status ====="
    if ($recordingProc) {
        Write-Host "録音: 実行中 (PID=$($recordingProc.Id))"
    } else {
        Write-Host "録音: 停止中"
    }

    if ($transcribeProc) {
        Write-Host "文字起こし: 実行中 (PID=$($transcribeProc.Id))"
        $info = Get-Content -LiteralPath $TranscribeInfoFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($info)) {
            Write-Host "対象: $info"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($taskName)) {
        Write-Host "文字起こし: 起動中/実行中 (Task=$taskName)"
        $info = Get-Content -LiteralPath $TranscribeInfoFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($info)) {
            Write-Host "対象: $info"
        }
    } else {
        Write-Host "文字起こし: 停止中"
    }
    Write-Host ""
}

function Start-TranscriptionWorker {
    param(
        [Parameter(Mandatory = $true)][string]$AudioFile,
        [Parameter(Mandatory = $true)][string]$Filename,
        [Parameter(Mandatory = $true)][string]$MeetingName,
        [string]$Category = ""
    )

    $running = Get-ProcessFromPidFile -Path $TranscribePidFile
    if ($running) {
        throw "既に文字起こし処理中です (PID=$($running.Id))。status で確認してください。"
    }
    Clear-TranscribeState
    Start-TranscriptionWorkerViaTaskScheduler -AudioFile $AudioFile -Filename $Filename -MeetingName $MeetingName -Category $Category
}

function Setup-AsyncRunner {
    Ensure-Dirs
    Ensure-TranscribeRunnerTask
    Write-Host "非同期runnerタスクを確認しました: $TranscribeRunnerTaskName"
}

function Stop-Recording {
    param([switch]$Async)

    if (-not (Test-Path -LiteralPath $PidFile)) {
        throw "録音中のセッションがありません。"
    }

    $pidRaw = Get-Content -LiteralPath $PidFile -ErrorAction Stop | Select-Object -First 1
    $pidValue = [int]$pidRaw
    $info = ""
    if (Test-Path -LiteralPath $InfoFile) {
        $info = Get-Content -LiteralPath $InfoFile -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    $parts = @("", "", "", "", "", "", "", "")
    if ($info) {
        $split = $info -split '\|', 8
        for ($i = 0; $i -lt $split.Count; $i++) {
            $parts[$i] = $split[$i]
        }
    }

    $filename = $parts[0]
    $meetingName = $parts[1]
    $category = $parts[2]
    $startEpoch = $parts[7]

    Write-Host "録音を停止しています..."
    Stop-Process -Id $pidValue -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) {
        Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InfoFile -Force -ErrorAction SilentlyContinue

    if (-not $filename) {
        throw "録音メタ情報が壊れています。"
    }

    $audioFile = Join-Path $AudioDir "${filename}.wav"
    if (-not (Test-Path -LiteralPath $audioFile)) {
        throw "音声ファイルが見つかりません: $audioFile"
    }

    if ($startEpoch) {
        try {
            $diff = [DateTimeOffset]::Now.ToUnixTimeSeconds() - [long]$startEpoch
            $duration = "{0}m{1:d2}s" -f [math]::Floor($diff / 60), ($diff % 60)
            Write-Host "録音完了 (${duration})"
        } catch {
            Write-Host "録音完了"
        }
    } else {
        Write-Host "録音完了"
    }

    if ($Async) {
        Start-TranscriptionWorker -AudioFile $audioFile -Filename $filename -MeetingName $meetingName -Category $category
        return
    }

    Process-Recording -AudioFile $audioFile -Filename $filename -MeetingName $meetingName -Category $category
}

function List-Recordings {
    Write-Host ""
    Write-Host "===== 会議メモ一覧 ====="
    Write-Host ""

    foreach ($section in @("商談", "社内", "private")) {
        $dir = Join-Path $MeetingsDir $section
        Write-Host "【$section】"
        if (Test-Path -LiteralPath $dir) {
            $files = @(Get-ChildItem -LiteralPath $dir -Filter *.md -File | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
            if ($files.Count -gt 0) {
                foreach ($f in $files) {
                    Write-Host "  - $($f.Name)"
                }
            } else {
                Write-Host "  (なし)"
            }
        } else {
            Write-Host "  (なし)"
        }
        Write-Host ""
    }
}

Ensure-Dirs

try {
    switch ($Command) {
        "start" {
            if ($CliArgs.Count -lt 1) {
                throw "会議名を指定してください。"
            }
            $meetingName = $CliArgs[0]
            $rest = @()
            if ($CliArgs.Count -gt 1) {
                $rest = $CliArgs[1..($CliArgs.Count - 1)]
            }
            Start-Recording -MeetingName $meetingName -StartArgs $rest
        }
        "stop" {
            Stop-Recording -Async:(Has-Flag -Args $CliArgs -LongFlag "--async")
        }
        "status" {
            Show-Status
        }
        "_process" {
            if ($CliArgs.Count -lt 3) {
                throw "_process の引数が不足しています。"
            }
            $audioFile = $CliArgs[0]
            $filename = $CliArgs[1]
            $meetingName = $CliArgs[2]
            $category = ""
            if ($CliArgs.Count -ge 4) {
                $category = $CliArgs[3]
            }
            $taskName = ""
            if ($CliArgs.Count -ge 5) {
                $taskName = $CliArgs[4]
            }
            Set-Content -LiteralPath $TranscribePidFile -Value $PID -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($taskName)) {
                Set-Content -LiteralPath $TranscribeTaskFile -Value $taskName -Encoding UTF8
            }
            try {
                Write-RunnerLog "_process start filename=$filename"
                Process-Recording -AudioFile $audioFile -Filename $filename -MeetingName $meetingName -Category $category
                Write-RunnerLog "_process completed filename=$filename"
            } catch {
                Write-RunnerLog "_process failed filename=$filename error=$($_.Exception.Message)"
                throw
            } finally {
                if ((-not [string]::IsNullOrWhiteSpace($taskName)) -and ($taskName -ne $TranscribeRunnerTaskName)) {
                    Remove-TaskSafe -TaskName $taskName
                }
                Clear-TranscribeState
            }
        }
        "_process-job" {
            Write-RunnerLog "_process-job invoked args=$($CliArgs -join ' | ')"
            if ($CliArgs.Count -lt 1) {
                throw "_process-job の引数が不足しています。"
            }
            $jobFile = $CliArgs[0]
            if (-not (Test-Path -LiteralPath $jobFile)) {
                throw "ジョブファイルが見つかりません: $jobFile"
            }
            $raw = Get-Content -LiteralPath $jobFile -Raw -ErrorAction Stop
            $job = $raw | ConvertFrom-Json
            $audioFile = [string]$job.audioFile
            $filename = [string]$job.filename
            $meetingName = [string]$job.meetingName
            $category = [string]$job.category
            $taskName = [string]$job.taskName
            Set-Content -LiteralPath $TranscribePidFile -Value $PID -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($taskName)) {
                Set-Content -LiteralPath $TranscribeTaskFile -Value $taskName -Encoding UTF8
            }
            try {
                Write-RunnerLog "_process-job start filename=$filename task=$taskName"
                Process-Recording -AudioFile $audioFile -Filename $filename -MeetingName $meetingName -Category $category
                Write-RunnerLog "_process-job completed filename=$filename"
            } catch {
                Write-RunnerLog "_process-job failed filename=$filename error=$($_.Exception.Message)"
                throw
            } finally {
                if ((-not [string]::IsNullOrWhiteSpace($taskName)) -and ($taskName -ne $TranscribeRunnerTaskName)) {
                    Remove-TaskSafe -TaskName $taskName
                }
                Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue
                Clear-TranscribeState
            }
        }
        "setup-async" {
            Setup-AsyncRunner
        }
        "list" {
            List-Recordings
        }
        "devices" {
            Show-AudioDevices
        }
        "help" {
            Show-Help
        }
        "--help" {
            Show-Help
        }
        "-h" {
            Show-Help
        }
        default {
            Show-Help
            exit 1
        }
    }
} catch {
    if ($Command -eq "_process-job" -or $Command -eq "_process") {
        try {
            Write-RunnerLog "command=$Command failed: $($_.Exception.Message)"
        } catch {
            # no-op
        }
    }
    Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
