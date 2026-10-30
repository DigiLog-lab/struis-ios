import Foundation
import GRDB

/// 学習タイムラインの射影の行(Issue #46「台帳に記録するもの」)。今の台帳と同じく、正本は `ledger_events` で、
/// この表はそこから作り直せる派生。記録はすべて点(「できること」)の ID に紐づける(名前を変えても記録は切れない)。

/// その人の「できること」1つ(知識グラフの点)。
nonisolated struct TimelineSkillRecord: LedgerRow {
    static let entity = LedgerEntity.timelineSkills
    var id: String  // quad.vertex_form
    var name: String
    var kind: String  // procedure | concept | combination | memorized
    var unitId: String?
    var status: String  // mastered | practicing | assumed
    /// ○(ヒントなし・目安時間内)だった日(yyyy-MM-dd、重なりなし)。数が定着の基準に届いたら定着。
    var correctDates: [String]
    var masteryThreshold: Int  // 3(外れた人は 4)
    var attempts: Int
    var lastCorrectAt: String?
    var nextReviewAt: String?
    /// 定着してから ○ だった回数(復習の間隔を決める)。
    var reviewCount: Int
    /// 分けた・まとめた先(元の点は残して記録を引き継ぐ)。
    var replacedBy: [String]
    var source: String  // initial | app | review | batch
    var createdAt: String
    var updatedAt: String
    /// 前提をまだ調べていないか: pending(今の単元の中身。次の段で分解する)| unexplored(まだ掘っていない。前に習う内容で、
    /// 1段下りる時に掘る)| done(直前の前提まで調べた)。前の版で作った点は空で、タイムラインを開いた時に付ける。
    var expansion: String? = nil
    var entityID: String { id }
    var correctDays: Int { correctDates.count }
    var isDug: Bool { expansion == "done" }
    var isActive: Bool { replacedBy.isEmpty }
}

/// 「○○には××が要る」(前提)か「○○でよくある勘違い」(典型的な誤解)の 1 本(知識グラフの線)。
nonisolated struct TimelineSkillEdgeRecord: LedgerRow {
    static let entity = LedgerEntity.timelineSkillEdges
    var id: String
    /// 使う側(先)。
    var skillId: String
    /// 前提の側(元)。誤解の線は `skillId` と同じ点で、中身は `note`。
    var requiresSkillId: String
    var relation: String  // prerequisite | misconception
    var source: String  // initial | app | review
    var note: String
    var createdAt: String
    var entityID: String { id }
}

/// 知識グラフへの操作、1 回分(アプリがその場で直した記録と、上位モデルの見直し)。
nonisolated struct TimelineMapChangeRecord: LedgerRow {
    static let entity = LedgerEntity.timelineMapChanges
    var id: String
    /// add_prerequisite | assume | split | merge | back_to_practice | review | build | combination | remove_edge | remove_node
    var kind: String
    var detail: LedgerJSON
    var attemptIds: [String]
    /// 上位モデルの見直しに渡したか。
    var reviewed: Bool
    var source: String  // app | review | build
    var createdAt: String
    var entityID: String { id }
}

/// 5枚を頼んだ呼び出し、1 回分。グラフを作る・見直す呼び出しも同じ表に `purpose` で分けて持つ。
nonisolated struct TimelineBatchRecord: LedgerRow {
    static let entity = LedgerEntity.timelineBatches
    var id: String
    var purpose: String  // cards | graph_build | graph_extend | graph_review
    var status: String  // requested | ready | failed | discarded
    var reason: String
    /// 頼んだ時の直近10問の正答率(数えない問題を除く)。
    var accuracy: Double?
    var levelCap: Int?
    var request: LedgerJSON
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    /// 受け取りを断って作り直させた回数(skills の ID・段の上限・検算)。
    var retries: Int
    var rejected: [String]
    var error: String?
    var createdAt: String
    var updatedAt: String
    var entityID: String { id }
}

/// カード 1 枚。
nonisolated struct TimelineCardRecord: LedgerRow {
    static let entity = LedgerEntity.timelineCards
    var id: String
    var batchId: String?
    var position: Int
    /// solve | order | find_error | compare | fill_line | next_step | graph_match | sort | predict | inverse | reason | howto | reveal | guide
    var kind: String
    var level: Int
    var skills: [String]
    var typeName: String
    var prompt: String
    var math: String
    var question: String
    var answerKey: String
    var answerExpr: String
    var checkpoints: [String]
    var commonMistakes: [String]
    var estimatedSeconds: Int
    /// 「さっきの続き」: position・total・changed・previous・chain_id。
    var chain: LedgerJSON?
    /// やさしい版なら元のカード。
    var easierOf: String?
    var subunitId: String?
    var unitId: String?
    /// 種類ごとの材料(steps・mistake_steps・facts・compare・reason・howto・diagnostic・選択肢など)。
    var payload: LedgerJSON
    var origin: String  // batch | easier | rapid | history | derived | guide
    var status: String  // unused | shown | answered | discarded | broken
    var createdAt: String
    var updatedAt: String
    var entityID: String { id }
}

/// 1 枚に対する 1 回の解答。
nonisolated struct TimelineAttemptRecord: LedgerRow {
    static let entity = LedgerEntity.timelineAttempts
    var id: String
    var cardId: String
    /// 答案の画像(`StruisPaths.captures` からの相対パス)。撮らないカードは nil。
    var capturePath: String?
    var verdict: String  // grading | correct | wrong | skipped | unreadable | failed
    var checkpointResults: LedgerJSON
    /// 間違いごとに kind・where・wrote・correct・detail。
    var errors: LedgerJSON
    var learnerAnswer: String
    var cause: String  // practice | connection | unknown
    var seconds: Double
    /// そのカードの初回か(やさしい版や解き直しは false)。
    var firstTry: Bool
    /// ヒントあり(「やり方の確認」を開いた・解く前に「質問」を使った)。
    var assisted: Bool
    var skipReason: String?
    var keySuspect: Bool
    /// 直近10問の正答率に数えるか(その日の最初の1問・やさしい版・速攻・飛ばした問題は数えない)。
    var countsForAccuracy: Bool
    var feedback: String
    var createdAt: String
    var gradedAt: String?
    /// 採点したモデルの正誤: correct | partial(答えは合うが途中に誤り)| wrong。`verdict` は partial を wrong にした値
    /// (切り替え・正答率・定着は partial を × として数える)。前の版の行は空。
    var grade: String? = nil
    /// 採点したモデルが自分の言葉で書いたメモ(次にこの生徒を教える人へ)。今日の記録に載せる。
    var notes: String? = nil
    /// 手書きの書き起こし。
    var transcript: String? = nil
    /// 関係するスキルの ID。1 つならその点に ○× を付け、2 つ以上なら付けずに置いて見直しで決める。
    var skillIds: [String]? = nil
    /// スキルの ○× を見直しで決める(ID が 2 つ以上だった)。
    var skillsPending: Bool? = nil
    /// スキルごとに付けた ○×(correct | wrong)。採点で ID が 1 つだった時と、見直しで決めた時に入る。前の版の行は空で、
    /// その時はカードの skills に答案全体の正誤を付けたものとして読む。
    var skillMarks: [String: String]? = nil
    /// 生徒が判定に納得できないと伝えた内容(結果の画面の「質問」から)。
    var dispute: String? = nil
    /// 見直しのメモ(前の判定を直した時はその理由)。
    var reviewNotes: String? = nil
    var reviewedAt: String? = nil
    /// 生徒が判定に納得できないと伝えた時刻。
    var disputedAt: String? = nil
    var entityID: String { id }
}

/// 今日の記録の 1 件(採点・出題・見直しのどの依頼にも付ける)。出来事(採点が終わった・見直しが終わった・申し出があった・
/// スキルが足された・単元が変わった)ごとに、その時点の文を保存する。一度書いた文は書き換えない(依頼の先頭のキャッシュを
/// 後から外さないため)。並びは保存した順(`seq`)。
nonisolated struct TimelineLogRecord: LedgerRow {
    static let entity = LedgerEntity.timelineLog
    var id: String
    /// yyyy-MM-dd(端末の暦)。
    var day: String
    /// その日の中の順。その日最初の「今の単元とスキルの一覧」は先頭に入る。
    var seq: Int
    var kind: String  // context | unit | skills | attempt | skip_reason | dispute | review | revise
    var attemptId: String?
    var unitId: String?
    /// この件で一覧に載せたスキル(単元とスキルの一覧・足されたスキル)。
    var skillIds: [String]
    var text: String
    var createdAt: String
    var entityID: String { id }
}

/// 2択カードを出した 1 回分。
nonisolated struct TimelineDipRecord: LedgerRow {
    static let entity = LedgerEntity.timelineDips
    var id: String
    var trigger: String  // slow | skips | away
    var chosen: String?  // rapid | continue
    var cardsAfter: Int
    var createdAt: String
    var updatedAt: String
    var entityID: String { id }
}
