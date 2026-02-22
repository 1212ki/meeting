# Meeting Recording Tool

録音 → 文字起こし → 要約 → 議事録保存 → Slack通知を一括で行うローカルツール。

> 最初に `tools/meeting/agents.md` を確認すること。

## コマンド一覧

| コマンド | 説明 |
|---------|------|
| `meeting start "会議名" --カテゴリ [--web] [--platform]` | 録音開始 |
| `meeting stop [--async]` | 録音停止 → 文字起こし → 要約 → 保存 → Slack通知 |
| `meeting setup-async` | Windowsの非同期runnerタスクを作成/確認 |
| `meeting status` | 録音/文字起こしワーカーの状態を表示 |
| `meeting list` | 録音一覧を表示 |
| `meeting reprocess <transcript.txt>` | 既存文字起こしの再処理（分類/要約/通知を再実行） |
| `meeting import <memo.md>` | コピペ文字起こしメモの取り込み |

## カテゴリと保存先

| オプション | 保存先 |
|-----------|--------|
| `--商談` | `knowledge/meetings/商談/` |
| `--社内` | `knowledge/meetings/社内/` |
| `--プライベート` | `knowledge/meetings/private/` |
| `--side-business [subdir]` | `knowledge/meetings/side-business/[subdir]/` |
| `--activity` | `knowledge/meetings/activities/` |
| `--thoughts` | `knowledge/meetings/thoughts/` |
| `--life` | `knowledge/meetings/life/` |
| (未分類) | `knowledge/meetings/` |

## 定例フォルダの扱い

- 会議名が `regular-meetings.tsv` に一致し、かつ `knowledge/meetings/<カテゴリ>/<定例名>/` が存在する場合は、そこへ保存する。
- 定例フォルダが存在しない場合は従来通り `knowledge/meetings/<カテゴリ>/` 直下に保存する。

## 基本的な使い方

### 対面会議

```sh
meeting start "A社提案"
# ... 会議中 ...
meeting stop
```

### Web会議

```sh
meeting start "週次定例" --web --platform meet
# ... 会議中 ...
meeting stop
```

### バックグラウンド処理

```sh
meeting stop --async  # 文字起こし/要約をバックグラウンドで実行
```

## Windowsでの使い方

WindowsではBash版（`tools/meeting/meeting`）ではなく、PowerShell版を使う。

```powershell
# 録音開始
tools\meeting\meeting.cmd start "週次定例"

# 停止 -> 文字起こし
tools\meeting\meeting.cmd stop

# 停止（非同期） -> 文字起こしはバックグラウンド実行
tools\meeting\meeting.cmd stop --async

# 非同期runnerの初期化（初回または不調時）
tools\meeting\meeting.cmd setup-async

# 状態確認
tools\meeting\meeting.cmd status

# 一覧
tools\meeting\meeting.cmd list

# デバイス確認
tools\meeting\meeting.ps1 devices
```

`meeting.cmd` は `--web` 等のオプションをWindows向けに調整して `meeting.ps1` を呼び出す。

### Windows依存

- `ffmpeg`（録音）
- `whisper` または `python -m whisper` / `py -3 -m whisper`（文字起こし）
- 非Web録音の入力は `MEETING_WINDOWS_FORCE_INPUT_DEVICE` を優先（既定: `マイク (Logi C270 HD WebCam)`）
- `stop --async` は Windows でも利用可能（進捗確認は `meeting status`）
- `stop --async` は固定runnerタスク（`schtasks`）を使ってバックグラウンド実行する（PowerShell親プロセスから分離）
- 初回またはタスク不調時は `meeting setup-async` を実行してrunnerを再作成する
- 互換用に `MEETING_WINDOWS_INPUT_DEVICE` も参照（`MEETING_WINDOWS_FORCE_INPUT_DEVICE` 未設定時のみ）
- `--web` 指定時:
  - 相手音声: `MEETING_WEB_INPUT_DEVICE`（例: `CABLE Output (VB-Audio Virtual Cable)`）
  - マイク: `MEETING_WEB_MIC_DEVICE`

### WindowsでWeb会議を録る最短手順（VB-CABLE）

1. VB-CABLEをインストールする
2. 会議アプリのスピーカー出力を `CABLE Input (VB-Audio Virtual Cable)` にする
3. 以下を設定する

```powershell
$env:MEETING_WEB_INPUT_DEVICE = "CABLE Output (VB-Audio Virtual Cable)"
$env:MEETING_WEB_MIC_DEVICE = "マイク デバイス名"
```

4. 録音開始

```powershell
tools\meeting\meeting.cmd start "週次定例" --web --platform teams
```

5. 停止

```powershell
tools\meeting\meeting.cmd stop
```

補足:
- `--web` は「相手音声 + マイク」の2入力ミックス録音を試みる
- 片方しか見つからない場合は単一入力にフォールバックする
- カテゴリは起動時に固定せず、停止後に文字起こし内容を見て判断する運用を推奨

### 副業プロジェクトの会議

```sh
meeting start "Kondate Loop定例" --プライベート --side-business kondate-loop --web --platform zoom
```

## 処理フロー

```
┌─────────────────────────────────────────────────────────────┐
│  meeting start "会議名" --カテゴリ [--web]                    │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  録音中（ffmpeg）                                            │
│  - 対面: OSデフォルトマイク                                   │
│  - Web: BlackHole + マイクのミックス                          │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  meeting stop                                               │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│  1. 録音停止 → WAVファイル保存                                │
│  2. Whisperで文字起こし                                      │
│  3. LLMで要約・議事録生成                                     │
│  4. knowledge/meetings/ 配下に保存                           │
│  5. Slack通知（開始/終了/完成）                               │
└─────────────────────────────────────────────────────────────┘
```

## 要点サマリーとTODO

- 要点サマリーは文字起こしの冒頭/末尾を使って生成し、TODO（特にItsukiのアクション）を必ず拾う。
- TODOが空の場合は `meeting reprocess` で再生成するか、議事録に手動で追記する。

## 再処理（reprocess）

既存の文字起こしファイルから、分類/要約/Slack通知を再実行する。

```sh
meeting reprocess /path/to/transcript.txt
meeting reprocess transcript.txt --md /path/to/meeting.md --replace
```

| オプション | 説明 |
|-----------|------|
| `--md <path>` | 既存議事録の情報（日付/タイトル）を優先 |
| `--title <title>` | タイトルを指定 |
| `--date YYYY-MM-DD` | 日付を指定 |
| `--replace` | `--md` 指定ファイルを上書き |

## メモ取り込み（import）

コピペした文字起こしメモを取り込み、完了通知を送信する（要約は生成しない）。

```sh
meeting import /path/to/memo.md
meeting import /path/to/memo.md --社内
```

- `## 文字起こし全文` セクションがあればそれを使用
- なければ全文を文字起こしとして扱う
- 元のメモファイルは分類先に移動
- 要約も必要な場合は `MEETING_IMPORT_SUMMARY=1` を設定

## Web会議の音声ルーティング

### 構成

```
┌──────────────────────────────────────────────────────────┐
│ Multi-Output Device（会議用スピーカー）                    │
│   ├── 実際のスピーカー/イヤホン → 自分で聞く               │
│   └── BlackHole 2ch → 録音ツールへ                       │
└──────────────────────────────────────────────────────────┘
                              +
┌──────────────────────────────────────────────────────────┐
│ マイク入力（OSデフォルト）→ 自分の声を録音                  │
└──────────────────────────────────────────────────────────┘
```

### 設定ポイント

- **出力**: Multi-Output Device（スピーカー + BlackHole）を作成して使用
- **マイク入力**: OSデフォルト（イヤホン接続時はイヤホンのマイク）
- **BlackHole音量**: 固定（実際に聞く出力側の音量だけ調整）
- **音量操作**: MultiSoundChanger.appを常駐（ログイン項目）
- **自動切替**: イヤホン挿抜に応じて会議用イヤホン/スピーカーへ自動切替（`SwitchAudioSource`）

### 環境変数

| 変数 | 説明 |
|------|------|
| `MEETING_WEB_INPUT_DEVICE` | BlackHoleデバイス名（既定: BlackHole 2ch） |
| `MEETING_WEB_MIC_DEVICE` | マイクデバイス名 |
| `MEETING_WEB_MIC_DEVICE_EARPHONE` | イヤホン時のマイクデバイス名 |
| `MEETING_WEB_INPUT_GAIN_BLACKHOLE` | BlackHole入力ゲイン |
| `MEETING_WEB_INPUT_GAIN_MIC` | マイク入力ゲイン |
| `MEETING_WEB_AUTO_LEVEL` | 自動レベル調整（既定ON） |
| `MEETING_WEB_LIMITER` | クリップ防止リミッタ（既定ON） |
| `MEETING_WEB_OUTPUT_DEVICE` | 出力デバイス名（未指定/autoで自動選択） |
| `MEETING_WEB_OUTPUT_AUTO_SWITCH` | 出力自動切替（1で有効） |
| `MEETING_WEB_OUTPUT_POLL_INTERVAL` | 出力自動切替の監視頻度（秒、既定: 5） |

## 録音ファイル

- **一時保存先**: `knowledge/meetings/_audio/`
- **削除タイミング**: 要点サマリーまで成功した場合
- **保持したい場合**: `MEETING_KEEP_AUDIO=1`
- **短い録音で要約省略時**: 保持（削除は `MEETING_DELETE_AUDIO_ON_SHORT=1`）
- **失敗時**: 録音データを残し、手動再処理可能

## Slack通知

- `SLACK_WEBHOOK_URL` を使用（`tools/podcast-summarizer/.env` を自動読み込み）
- 別Webhookを使う場合は `MEETING_SLACK_WEBHOOK_URL` を設定
- 通知タイミング: 録音開始 / 録音終了 / 議事録完成
- 通知内容:
  - 録音開始: `録音を開始しました-会議名:{会議名} {環境(対面/Meet/Teams/Zoom/Web)}`
  - 録音終了: `録音を終了しました-{時間} 文字起こし中...`
  - 議事録完成: `議事録を作成しました` + `パス` + `要点/決定事項/TODO`

## ログ・トラブル対応

### ログ

- **保存先**: `knowledge/meetings/log/`
- **日次ログ**: `meeting-YYYY-MM-DD.log`
- **保持期間**: 14日（`MEETING_LOG_RETENTION_DAYS` で変更可能）

### トラブルシューティング

| 問題 | 対処 |
|------|------|
| `ffmpeg` が見つからない | `brew install ffmpeg` |
| `whisper` が見つからない | `python3 -m pip install openai-whisper` |
| 出力自動切替が動かない | `SwitchAudioSource` の導入と `MEETING_WEB_OUTPUT_AUTO_SWITCH=1` を確認 |
| デバイス一覧が空 | `ffmpeg -f avfoundation -list_devices true -i ""` をエスカレーションで再実行 |
| BlackHoleが表示されない | `sudo killall coreaudiod` で再起動 |
| Whisperがタイムアウト | WAVファイルに対して手動でWhisperを実行 |

## ファイル名規則

- 形式: `YYYYMMDD_会議名.md`
- 同日同名: `_02` 以降の連番で回避
- 会議名が無題/不明: 文字起こしからタイトルを推測
- 会議名に日付が含まれる場合: ファイル名では先頭の日付のみ使用
- 定例名の正規化: `tools/meeting/regular-meetings.tsv` で管理

## タイムアウト設定

- **start**: 10000ms以上を推奨（開始は即時だが初期処理で中断しないため）
- **stop**: 7200000ms（2時間）以上を推奨（長尺会議のWhisper/後処理が長引くため）

## 文字起こし負荷調整（Windows）

- `MEETING_WHISPER_PRIORITY`（既定: `BelowNormal`）
  - Whisperプロセス優先度。`Idle` / `BelowNormal` / `Normal` / `AboveNormal` / `High`
- `MEETING_TRIM_SILENCE`（既定: `1`）
  - 文字起こし前に保守的な無音トリミングを実施（先頭・末尾のみ）
- `MEETING_TRIM_NOISE_DB`（既定: `-45`）
  - 無音判定しきい値（dB）
- `MEETING_TRIM_SILENCE_DURATION`（既定: `0.7`）
  - 無音として判定する最小継続秒数
- `MEETING_TRIM_TRAILING_MIN_SECONDS`（既定: `8`）
  - 末尾無音をトリムする最小秒数
- `MEETING_TRIM_LEADING_MAX_SECONDS`（既定: `10`）
  - 先頭無音として削る上限秒数
