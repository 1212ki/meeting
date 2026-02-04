# Meeting Tool - CLAUDE.md

## トリガーワード
- 「議事録取って」「録音開始」「会議を記録」「議事メモ」「開始」

## いつ使うか
- 会議・ミーティング・商談の録音が必要なとき
- 文字起こしテキストから議事録を作成するとき

## 基本コマンド

```bash
# 録音開始
tools/meeting/meeting start "会議名" --社内
tools/meeting/meeting start "会議名" --商談
tools/meeting/meeting start "会議名" --社内 --web  # Web会議

# 録音停止 → 文字起こし → 要約 → 保存 → Slack通知
tools/meeting/meeting stop

# 既存文字起こしの再処理
tools/meeting/meeting reprocess <transcript.txt>

# メモ取り込み
tools/meeting/meeting import <memo.md>
```

## 運用ルール

1. **即時実行**: 「議事録取って」「開始」等の指示は確認なしで即実行
2. **Webオプション**: 「Web」「Meet」「Zoom」等の明示がある場合のみ `--web` を付ける
3. **Slack通知**: 常に送信（確認不要）
4. **タイムアウト**: start=10秒以上、stop=2時間以上

## カテゴリと保存先

| オプション | 保存先 |
|-----------|--------|
| `--商談` | `knowledge/meetings/商談/` |
| `--社内` | `knowledge/meetings/社内/` |
| `--プライベート` | `knowledge/meetings/private/` |
| `--side-business` | `knowledge/meetings/side-business/` |

## 詳細

- 詳細運用: `tools/meeting/agents.md`
- 使い方: `tools/meeting/README.md`
- 定例名: `tools/meeting/regular-meetings.tsv`
