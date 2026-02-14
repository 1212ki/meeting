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
$WebInputGainSystem = if ($env:MEETING_WEB_INPUT_GAIN_SYSTEM) { $env:MEETING_WEB_INPUT_GAIN_SYSTEM } elseif ($env:MEETING_WEB_INPUT_GAIN_BLACKHOLE) { $env:MEETING_WEB_INPUT_GAIN_BLACKHOLE } else { "1.0" }
$WebInputGainMic = if ($env:MEETING_WEB_INPUT_GAIN_MIC) { $env:MEETING_WEB_INPUT_GAIN_MIC } else { "1.0" }
$WebAutoLevel = if ($env:MEETING_WEB_AUTO_LEVEL) { $env:MEETING_WEB_AUTO_LEVEL } else { "1" }
$WebLimiter = if ($env:MEETING_WEB_LIMITER) { $env:MEETING_WEB_LIMITER } else { "1" }
$WebLimiterFilter = if ($env:MEETING_WEB_LIMITER_FILTER) { $env:MEETING_WEB_LIMITER_FILTER } else { "alimiter=limit=0.95:attack=5:release=50" }

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
  .\tools\meeting\meeting.ps1 list
  .\tools\meeting\meeting.ps1 devices

補足:
  - Windows版は ffmpeg(dshow) で録音します
  - --web は「相手音声(VB-CABLE等) + マイク」の2入力ミックス録音です
  - 相手音声入力: MEETING_WEB_INPUT_DEVICE（例: CABLE Output (VB-Audio Virtual Cable)）
  - マイク入力: MEETING_WEB_MIC_DEVICE（未指定時はマイクらしいデバイスを自動選択）
  - 文字起こしは whisper / python -m whisper / py -3 -m whisper を順に探索します
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
        "--output_format", "txt",
        "--output_dir", $OutputDir
    )
    & $runner.File @args
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
    Invoke-Whisper -AudioFile $AudioFile -OutputDir $AudioDir

    $transcriptFile = Join-Path $AudioDir "${Filename}.txt"
    if (-not (Test-Path -LiteralPath $transcriptFile)) {
        throw "文字起こしファイルが生成されませんでした: $transcriptFile"
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
        Write-Warning "Windows版では --async は未対応のため同期処理します。"
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
            Stop-Recording -Async:($CliArgs -contains "--async")
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
    Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
