# Meeting Tool - CLAUDE.md

## トリガーワード
- 「議事録取って」「録音開始」「会議を記録」「議事メモ」「開始」

## いつ使うか
- 会議・ミーティング・商談の録音が必要なとき
- 文字起こしテキストから議事録を作成するとき

## 基本コマンド

```bash
# 録音開始
tools/meeting/meeting start "会議名"
tools/meeting/meeting start "会議名" --web  # Web会議

# 録音停止 → 文字起こし → 要約 → 保存 → Slack通知
tools/meeting/meeting stop

# 既存文字起こしの再処理
tools/meeting/meeting reprocess <transcript.txt>

# メモ取り込み
tools/meeting/meeting import <memo.md>

# Windows (PowerShell)
tools/meeting/meeting.cmd start "会議名"
tools/meeting/meeting.cmd start "会議名" --web
tools/meeting/meeting.cmd stop
tools/meeting/meeting.cmd list
```

## 運用ルール

1. **即時実行**: 「議事録取って」「開始」等の指示は確認なしで即実行
2. **Webオプション**: 「Web」「Meet」「Zoom」等の明示がある場合のみ `--web` を付ける
3. **カテゴリ判定**: 起動時はカテゴリを固定せず、停止後に文字起こし内容を見てカテゴリ/保存先を判断・修正する
4. **Slack通知**: 常に送信（確認不要）
5. **タイムアウト**: start=10秒以上、stop=2時間以上
6. **Windows対面録音の入力固定**: 非Web録音は `MEETING_WINDOWS_FORCE_INPUT_DEVICE` を優先する（既定: `マイク (Logi C270 HD WebCam)`）。見つからない場合は開始を中止する。

## カテゴリと保存先

| オプション | 保存先 |
|-----------|--------|
| `--商談` | `knowledge/meetings/商談/` |
| `--社内` | `knowledge/meetings/社内/` |
| `--プライベート` | `knowledge/meetings/private/` |
| `--side-business` | `knowledge/meetings/side-business/` |

## Codex CLI対応

Codex CLIで使用する場合、以下のコマンドプレフィックスが `~/.codex/config.toml` で承認済みである必要がある：

```toml
approved_command_prefixes = [
  ["tools/meeting/meeting", "start"],
  ["tools/meeting/meeting", "stop"],
  ["tools/meeting/meeting", "reprocess"],
  ["tools/meeting/meeting", "import"]
]
```

初回実行時に「Always allow」を選択しても承認される。

## 詳細

- 詳細運用: `tools/meeting/agents.md`
- 使い方: `tools/meeting/README.md`
- 定例名: `tools/meeting/regular-meetings.tsv`
