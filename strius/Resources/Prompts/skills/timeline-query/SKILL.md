---
name: timeline-query
description: 学習者の知識グラフと解答の台帳に問い合わせる(前提・誤解・過去の解答・組み合わせ)。× が続いた時だけ使う。
---

# timeline-query

`struis.timeline_query` を直接呼びます。シェルからは呼べません。

| query | 引数 | 返すもの |
|---|---|---|
| `prerequisites` | `skill_id` | 未定着の前提と何段先か(WITH RECURSIVE でたどった結果) |
| `misconceptions` | `skill_id` | その「できること」と前提に付いた典型的な誤解 |
| `history` | `skill_id` | 直近5回の問題・○ / ×・誤答の種類・書いたもの・正しくは・詳細・日付 |
| `combination` | `skill_id`, `other_skill_id` | それぞれの ○ の回数と、両方を使う問題の ○ / × |

同じ間違いかどうかは、誤答の種類ではなく、書いたものと詳細を読んで判断してください。
