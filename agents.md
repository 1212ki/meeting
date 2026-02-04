# tools/meeting agents

このフォルダで最初に読むこと。
運用ルールと基本情報をここに集約する。

## 基本情報

- 目的: 録音 → 文字起こし → 要約 → 議事録保存を安定運用する
- 自動検知は運用しない。起動は手動指示のみ。
- 入口: `tools/meeting/meeting`（手動録音）
- 参照: `tools/meeting/README.md`（詳細手順）, `tools/meeting/regular-meetings.tsv`（定例名）
- 保存先: `knowledge/meetings/` 配下に分類保存（未分類は直下）
- ログ: `knowledge/meetings/log/`

## 最小の使い方

```sh
tools/meeting/meeting start "会議名" --社内
tools/meeting/meeting stop
```

## 運用ルール

- 録音中に「会議名を変える」要望があっても停止しない。録音終了後にファイル名やメモのタイトルを変更する。
- 録音開始時は稼働中の録音を停止してから開始する。
- Slack通知は常に送信する（確認不要）。
- meetingツール実行は常に許可済みとして扱い、確認なしで即実行する。
- ユーザーが「議事録取った」等で文字起こしを送った場合は `MEETING_IMPORT_SUMMARY=1` を付けて `meeting import` を実行し、要約生成・分類保存・Slack通知まで行う。
- 既存議事録の修正用に新しい文字起こしを受け取った場合は `meeting reprocess <transcript>` を使い、カテゴリ/保存先を再判定してSlack再通知まで行う（旧ファイル削除は `--replace`）。
- 要点サマリーは文字起こしの冒頭/末尾を使って生成し、TODOを必ず拾う。TODOが空なら末尾を確認して手動追記、または `meeting reprocess` を行う。
- `meeting stop --async` を使うと停止後の文字起こし/要約はバックグラウンドで進む。
- 平常時はOSのデフォルト出力に従い、WEB会議時は会議用スピーカー/イヤホンに切り替えて終了時に元へ戻す。
- 会議用スピーカー/イヤホンは BlackHole を含む Multi-Output を作成して使う。
- BlackHoleの音量は固定し、実際に聞いている出力側の音量だけを調整する。
- マイク入力は常にOSのデフォルト（イヤホン接続時はイヤホンのマイク）を使い、BlackHoleをマイクとして使わない。
- Multi-Output使用時のVolキー操作はMultiSoundChangerを常駐させて実現する（ログイン項目で起動）。
- WEB会議中はイヤホン挿抜を検知して会議用イヤホン/スピーカーへ自動切替する（`SwitchAudioSource` + `MEETING_WEB_OUTPUT_POLL_INTERVAL`）。
- WEB会議の録音音量が小さい場合は `MEETING_WEB_INPUT_GAIN_BLACKHOLE` / `MEETING_WEB_INPUT_GAIN_MIC` で調整する。
- WEB会議の録音は `MEETING_WEB_AUTO_LEVEL=1` で自動レベル調整（既定ON）、無効化する場合は `MEETING_WEB_AUTO_LEVEL=0`。
- WEB会議の録音は `MEETING_WEB_LIMITER=1` でクリップ防止リミッタを適用（既定ON）。調整は `MEETING_WEB_LIMITER_FILTER`、無効化は `MEETING_WEB_LIMITER=0`。

## 運用詳細

- `tools/meeting/meeting` はCoreAudioアクセスにエスカレーションが必要。
- Slack通知を送る場合もネットワーク制限を外して実行する（DNS解決が必要）。
- startのtimeoutは10000ms以上を推奨（開始は即時だが初期処理で中断しないため）、stopは7200000ms（2時間）以上を指定（長尺会議のWhisper/後処理が長引くため）。
- Slack通知は録音開始 / 録音終了 / 議事録完成を送信する。
- テキスト取り込み（import）は要点サマリー生成をスキップし、Slackは完了通知のみ送信する。
- `MEETING_SLACK_ASYNC` は他の通知が増えた場合の既定動作を制御（既定ON）。同期に戻す場合は `MEETING_SLACK_ASYNC=0`。
- WhisperがタイムアウトしてもWAVが残る場合は、そのWAVに対して手動でWhisperを実行する。
- デバイス一覧が空なら `ffmpeg -f avfoundation -list_devices true -i ""` をエスカレーションで再実行する。
- 要点サマリーまで成功した場合のみ一時音声を削除する。必要なら `MEETING_KEEP_AUDIO=1` を使う。
- 短い文字起こしで要約を省略した場合は保持する（削除したい場合は `MEETING_DELETE_AUDIO_ON_SHORT=1`）。
- 要約失敗時は音声/文字起こしを残すので `meeting reprocess` で再処理する。

## ログ/トラブル対応

- ミーティングログ: `knowledge/meetings/log/meeting-YYYY-MM-DD.log`
- 直近の録音一時ファイル: `knowledge/meetings/_audio/*.wav`
- BlackHoleが`ffmpeg -f avfoundation -list_devices true -i ""`に出ない場合は `sudo killall coreaudiod` で再起動。

## 定例会議名

- 定例会議の正規名/別名は `tools/meeting/regular-meetings.tsv` で管理し、会議名を統一する。
- 録音ファイルは `knowledge/meetings/_audio/` に一時保存し、要点サマリーまで成功した場合のみ削除する。必要なら `MEETING_KEEP_AUDIO=1` を使う。
