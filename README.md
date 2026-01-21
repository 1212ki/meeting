# Meeting Recording Tool

最初に `tools/meeting/agents.md` を確認すること。

録音 → 文字起こし → 要約 → 議事録保存までを行うローカルツール。

## 手動録音

```sh
tools/meeting/meeting start "会議名" --商談
tools/meeting/meeting start "会議名" --社内
tools/meeting/meeting start "会議名" --プライベート
tools/meeting/meeting start "会議名" --side-business
tools/meeting/meeting start "会議名" --activity
tools/meeting/meeting start "会議名" --thoughts
tools/meeting/meeting start "会議名" --life

tools/meeting/meeting start "会議名" --商談 --web
tools/meeting/meeting start "会議名" --プライベート --side-business kondate-loop --web

tools/meeting/meeting stop

tools/meeting/meeting reprocess /path/to/transcript.txt
tools/meeting/meeting reprocess /path/to/transcript.txt --md /path/to/meeting.md --replace
```

- `--web` を付けない場合は対面会議として開始します。
- Web会議でプラットフォームが不明な場合は `Web` として扱います。

## 保存先の方針

- 既定は `knowledge/meetings/` 配下に保存します。
- 自動分類できない場合は `knowledge/meetings/` 直下に保存します。

| 種別 | 保存先 |
| --- | --- |
| 社内 | `knowledge/meetings/社内/` |
| 商談 | `knowledge/meetings/商談/` |
| private | `knowledge/meetings/private/` |
| side-business | `knowledge/meetings/side-business/` |
| 活動 | `knowledge/meetings/activities/` |
| thoughts | `knowledge/meetings/thoughts/` |
| life | `knowledge/meetings/life/` |
| 未分類 | `knowledge/meetings/` |

- ファイル名は `YYYYMMDD_会議名.md`。同日同名は `_02` 以降の連番で回避します。
- 定例名の正規化は `tools/meeting/regular-meetings.tsv` で管理します。

## 録音ファイル

- 一時保存先: `knowledge/meetings/_audio/`
- 既定では**要点サマリーまで成功**した場合に削除（保持したい場合は `MEETING_KEEP_AUDIO=1`）。
- 文字起こしが短く要約を省略した場合は保持します（削除したい場合は `MEETING_DELETE_AUDIO_ON_SHORT=1`）。
- 失敗時は録音データを残し、手動再処理できます。

## 再処理（既存文字起こし）

- 文字起こしテキストを渡すと、分類/要約/通知を再実行します。
- `--md` を指定すると既存議事録の情報（日付/タイトル）を優先します。
- `--replace` を付けた場合のみ旧ファイルを削除します（未指定なら旧ファイルは残ります）。

```sh
tools/meeting/meeting reprocess knowledge/meetings/_audio/2026-01-20_0900_title.txt
tools/meeting/meeting reprocess transcript.txt --md knowledge/meetings/社内/20260120_週次定例.md --replace
```

## Slack通知

`SLACK_WEBHOOK_URL` を使用し、`tools/podcast-summarizer/.env` を自動で読み込みます。
別Webhookを使いたい場合は `MEETING_SLACK_WEBHOOK_URL` を設定してください。

通知文言:
- 録音開始: `録音を開始しました-会議名:{会議名} {環境(対面/Meet/Teams/Zoom/Web)}`
- 録音終了: `録音を終了しました-{時間} 文字起こし中...`
- 議事録完成: `議事録を作成しました` + `パス：{保存先}`
  - 決定事項と持ち帰りタスクのみを簡潔に添えます。

## 自動録音（Meet / Zoom / Teams）

`tools/meeting/watch` を常駐させると、Meet/Zoom/Teamsの開始・終了に合わせて自動録音します。

### 前提

- Macが起きていてログイン済み（スリープ中は検知・録音不可）
- ChromeのタブURL取得許可（自動化）
- Zoomのウィンドウ検知許可（アクセシビリティ）
- マイク許可
- Web会議の相手音声を録る場合はBlackHoleを使用
- 本文解析によるタイトル/分類には `claude` または `codex` CLI が必要

### 起動（手動）

```sh
tools/meeting/watch
```

### 起動（ログイン時に自動）

```sh
cp tools/meeting/launchd/com.itsuki.meeting.watch.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.itsuki.meeting.watch.plist
```

停止:

```sh
launchctl unload ~/Library/LaunchAgents/com.itsuki.meeting.watch.plist
```

### 動作ルール

- Meet開始: `https://meet.google.com/<会議コード>` のタブが開いた時点
- Meet終了: そのタブが消えた時点
- Zoom開始/終了: 会議ウィンドウの出現/消失
- Teams開始/終了: 会議ウィンドウ or meeting URL の出現/消失

### watchの保存先指定（任意）

- `MEETING_WATCH_SIDE_BUSINESS=kondate-loop` を設定すると、`knowledge/meetings/side-business/kondate-loop/` に固定されます。
- `MEETING_WATCH_ACTIVITY=1` を設定すると、`knowledge/meetings/activities/` に固定されます。

## Web会議の音声ルーティング

- 相手音声を録るために BlackHole を使います。
- マイク入力はOSデフォルト（イヤホン接続時はイヤホンのマイク）。BlackHoleをマイクとして使いません。
- Multi-Output Device（例: スピーカー + BlackHole）を作成し、出力に設定します。
- 会議用スピーカー/イヤホンは **BlackHoleを含むMulti-Output** として作成してください。
- イヤホン挿抜の自動切替に対応します。
- Multi-Output時の音量操作は `/Applications/MultiSoundChanger.app` を常駐させて行います。

主要環境変数:
- `MEETING_WEB_INPUT_DEVICE`（既定: BlackHole 2ch）
- `MEETING_WEB_MIC_DEVICE` / `MEETING_WEB_MIC_DEVICE_EARPHONE`
- `MEETING_WEB_INPUT_GAIN_BLACKHOLE` / `MEETING_WEB_INPUT_GAIN_MIC`
- `MEETING_WEB_AUTO_LEVEL` / `MEETING_WEB_AUTO_LEVEL_FILTER`
- `MEETING_WEB_LIMITER` / `MEETING_WEB_LIMITER_FILTER`
- `MEETING_WEB_OUTPUT_DEVICE` / `MEETING_WEB_OUTPUT_AUTO_SWITCH`

## ログ

- ログ保存先: `knowledge/meetings/log/`
- 日次ログ: `meeting-YYYY-MM-DD.log`, `watch-YYYY-MM-DD.log`
- 保持期間: 14日（`MEETING_LOG_RETENTION_DAYS` で変更可能）

## トラブルシューティング

- `ffmpeg` が見つからない: `brew install ffmpeg`
- `whisper` が見つからない: `python3 -m pip install openai-whisper`
- Web検知が動かない: Chrome/Zoom/Teamsの自動化・アクセシビリティ権限を確認
- 出力自動切替が動かない: `SwitchAudioSource` の導入と `MEETING_WEB_OUTPUT_AUTO_SWITCH=1` を確認
