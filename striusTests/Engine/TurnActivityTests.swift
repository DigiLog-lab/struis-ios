import Foundation
import Testing
@testable import strius

/// 待ちの表示(信頼性計画 P2・W11)の、出来事から言葉を作る部分。
struct TurnActivityTests {
    @Test func streamHidesPrivateBlocksAndPartialTags() {
        #expect(TurnReplyStream.visible("こんにちは。\n<struis_progress_update>{\"a\":1}") == "こんにちは。")
        #expect(TurnReplyStream.visible("説明です<str") == "説明です")
        #expect(TurnReplyStream.visible("説明です<") == "説明です")
        #expect(TurnReplyStream.visible("a < b のとき") == "a < b のとき")
    }

    @Test func streamShowsOnlyClosedMath() {
        #expect(TurnReplyStream.visible("式は $x^2+1$ で、次は $x^") == "式は $x^2+1$ で、次は")
        #expect(TurnReplyStream.visible("式は \\(x+1\\) と \\(y") == "式は \\(x+1\\) と")
        #expect(TurnReplyStream.visible("$$x^2$$ と $$y") == "$$x^2$$ と")
        #expect(TurnReplyStream.visible("**大事** と **ここ") == "**大事** と")
        #expect(TurnReplyStream.visible("値段は \\$5 です") == "値段は \\$5 です")
    }

    @Test func approximateMathIsReadable() {
        #expect(TurnReplyStream.approximateMath("$x^2+4x+4$") == "x²+4x+4")
        #expect(TurnReplyStream.approximateMath("\\(\\frac{1}{2}\\)") == "(1)/(2)")
    }

    @Test func partialScannerCountsFinishedObjects() {
        let text = #"{"items":[{"label":"(1)","verdict":"correct"},{"label":"(2)","verd"#
        let scan = PartialJSONScanner.scan(text)
        #expect(scan.arrays["items"]?.count == 1)
        let grading = TurnActivityLabels.structuredPartial(taskType: "workbook_grading", text: text)
        #expect(grading?.done == 1)
        #expect(grading?.label == "「(1)」まで見ました")
        let unit = TurnActivityLabels.structuredPartial(taskType: "workbook_unit", text: #"{"unit_title":"二次関数","subunits":[{"n":5,"title":"平方完成"}"#)
        #expect(unit?.done == 1)
        #expect(unit?.label == "小単元を 1 つ並べました（平方完成）")
        let titleOnly = TurnActivityLabels.structuredPartial(taskType: "workbook_unit", text: #"{"unit_title":"二次関数","sub"#)
        #expect(titleOnly?.label == "単元名を「二次関数」にしました")
        let set = TurnActivityLabels.structuredPartial(taskType: "workbook_set", text: #"{"problems":[{"prompt":"a {b}","answer_key":"c","checkpoints":["}"]},{"prompt":"#)
        #expect(set?.done == 1)
        // 一枚は問題文だけを渡す(答え・採点の観点は渡さない)。
        #expect(set?.items == ["a {b}"])
    }

    @Test func collectorFindsFinishedProposalOnce() {
        let collector = ReplyStreamCollector()
        #expect(collector.append(itemID: "a", delta: "全体像のカードを出すね。\n<struis_workbook_proposal>{\"request\": \"一次関数") == nil)
        #expect(collector.append(itemID: "a", delta: "の変化の割合\"}</struis_workbook_proposal>") == "一次関数の変化の割合")
        #expect(collector.append(itemID: "a", delta: "\n<struis_memory_update>NO_UPDATE</struis_memory_update>") == nil)
    }

    @Test func commandLabelsNameWhatWasRead() {
        #expect(TurnActivityLabels.command("python3 -c 'print(1)' tutor_desk/inbox/x/document-1.pdf").started == "送られた PDF を読んでいます")
        #expect(TurnActivityLabels.command("python3 read.py document-1.pdf --page 150").started == "送られた PDF の 150 ページ目を読んでいます")
        #expect(TurnActivityLabels.command("cat struis_context/summary.md").finished == "これまでの学習の記録を確かめました")
        #expect(TurnActivityLabels.command("echo hi").started == "手元で確かめています")
    }

    @Test func privateBlockSaysWhatIsBeingWritten() {
        #expect(TurnReplyStream.privateBlockLabel("返事。\n<struis_progress_update>{\"goals\":[{\"title\":\"係数を半分にする\",\"st") == "学習の進み具合を記録しています（係数を半分にする）")
        #expect(TurnReplyStream.privateBlockLabel("返事。\n<struis_memory_update>NO") == "覚えておくことを書き留めています")
        #expect(TurnReplyStream.privateBlockLabel("返事だけ") == nil)
        // 書きかけのタグ名は数えない。前のブロックがあればそれを言う。
        #expect(TurnReplyStream.privateBlockLabel("返事。\n<struis_m") == nil)
        #expect(TurnReplyStream.privateBlockLabel("返事。\n<struis_memory_update>x</struis_memory_update>\n<struis_pro") == "覚えておくことを書き留めています")
    }

    @Test func reasoningHeadlineOnlyWhenJapanese() {
        #expect(TurnActivityLabels.reasoningHeadline("**例題を選ぶ**\n\n係数を…") == "例題を選ぶ")
        #expect(TurnActivityLabels.reasoningHeadline("**Planning the example**\n\nI need") == nil)
    }

    @Test func silenceLadderStepsEveryTenSeconds() {
        let start = Date(timeIntervalSince1970: 0)
        var activity = TurnActivity(startedAt: start)
        func text(_ seconds: TimeInterval) -> String? { TurnSilence.statement(for: activity, now: start.addingTimeInterval(seconds))?.text }
        #expect(text(5) == nil)
        #expect(text(12) == "AI の最初の応答を待っています")
        #expect(text(22) == "AI の応答を待っています（混み合っている可能性があります）")
        let texts = stride(from: 5.0, through: 65, by: 10).map { text($0) }
        #expect(Set(texts.compactMap { $0 }).count == 6)
        #expect(TurnSilence.statement(for: activity, now: start.addingTimeInterval(61))?.offersChoice == true)
        activity.lastEventAt = start.addingTimeInterval(30)
        activity.lastVisibleChangeAt = start.addingTimeInterval(30)
        #expect(text(35) == nil)
        // 出来事は届き続けているが、見えるものが変わらない。
        activity.lastEventAt = start.addingTimeInterval(44)
        #expect(text(45) == "同じ作業を続けています")
        activity.lastEventAt = start.addingTimeInterval(30)
        #expect(text(41) == "AI が続きを考えています")
        activity.keepWaitingAt = start.addingTimeInterval(100)
        #expect(text(120) == "このまま待っています。応答が届いたらすぐに出します")
        activity.finished = true
        #expect(text(200) == nil)
    }

    @Test func silenceNamesTheRunningWork() {
        let start = Date(timeIntervalSince1970: 0)
        var activity = TurnActivity(startedAt: start)
        activity.lastEventAt = start
        activity.runningTools = ["cmd-1"]
        #expect(TurnSilence.statement(for: activity, now: start.addingTimeInterval(15))?.text == "この作業を続けています")
        let late = TurnSilence.statement(for: activity, now: start.addingTimeInterval(65))
        #expect(late?.offersChoice == true)
        #expect(late?.text.hasPrefix("この作業が 1 分以上") == true)
        activity.runningTools = []
        activity.compacting = true
        #expect(TurnSilence.statement(for: activity, now: start.addingTimeInterval(25))?.text == "会話が長くなったので、整理に時間がかかっています")
    }

    // MARK: Skill ごとの待ちの言葉(配信Skillの説明)

    private static var coachSkills: URL? {
        guard let path = ProcessInfo.processInfo.environment["STRUIS_TEST_SKILLS_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 配信する Skill はすべて、添付が無い時の言葉(default)を持ち、本文を読む間に抽象的な言葉へ落ちない。
    @Test(.enabled(if: Self.coachSkills != nil, "STRUIS_TEST_SKILLS_DIR is unset; delivery skills are external inputs"))
    func everyDeliveredSkillHasItsOwnWaitingWords() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: try #require(Self.coachSkills).path).filter { !$0.hasPrefix(".") }
        #expect(!names.isEmpty)
        for name in names {
            let text = try String(contentsOf: try #require(Self.coachSkills).appendingPathComponent("\(name)/SKILL.md"), encoding: .utf8)
            let labels = try #require(SkillWaiting.parse(skillMarkdown: text), "\(name) has no metadata.struis-waiting.default")
            for pair in labels.values {
                #expect(pair != SkillWaiting.unknownSkill)
                #expect(!pair.started.contains("手元で確かめ"))
            }
            #expect(DeliveryManifest.assetNames.contains("skill:" + name.replacingOccurrences(of: "-", with: "_")))
        }
    }

    @Test(.enabled(if: Self.coachSkills != nil, "STRUIS_TEST_SKILLS_DIR is unset; delivery skills are external inputs"))
    func readingTheDocumentSkillShowsItsWordsByAttachment() throws {
        let text = try String(contentsOf: try #require(Self.coachSkills).appendingPathComponent("struis-document/SKILL.md"), encoding: .utf8)
        var skills = SkillWaiting()
        skills.labels["struis-document"] = try #require(SkillWaiting.parse(skillMarkdown: text))
        let cmd = "cat /var/mobile/x/workspace/01a0/.agents/skills/struis-document/SKILL.md"
        skills.attachments = .pdf
        #expect(TurnActivityLabels.command(cmd, skills: skills).started == "PDF の読み方を確かめています")
        #expect(TurnActivityLabels.command(cmd, skills: skills).finished == "PDF の読み方を確かめました")
        skills.attachments = .image
        #expect(TurnActivityLabels.command("sed -n '1,80p' .agents/skills/struis-document/SKILL.md", skills: skills).started == "写真の見方を確かめています")
        skills.attachments = .none
        #expect(TurnActivityLabels.command(cmd, skills: skills).started == "資料の読み方を確かめています")
        // 名前に document を含んでも、送られた PDF を読む出来事と取り違えない。
        #expect(TurnActivityLabels.command("cat tutor_desk/inbox/m/document-1.pdf", skills: skills).started == "送られた PDF を読んでいます")
        #expect(SkillWaiting.skillName(fromWorkspacePath: ".agents/skills/struis-document/SKILL.md") == "struis-document")
        #expect(SkillWaiting.skillName(fromWorkspacePath: "AGENTS.md") == nil)
    }

    @Test func runnerShowsSkillWordsForStartedAndCompletedCommands() {
        var skills = SkillWaiting()
        skills.labels["struis-document"] = ["default": .init(started: "資料の読み方を確かめています", finished: "資料の読み方を確かめました")]
        let item: [String: Any] = ["type": "commandExecution", "id": "c1", "command": "cat .agents/skills/struis-document/SKILL.md"]
        #expect(CodexTurnRunner.startedItemEvent(item, skills: skills)?.label == "資料の読み方を確かめています")
        #expect(CodexTurnRunner.completedItemEvent(item, phase: "", skills: skills)?.label == "資料の読み方を確かめました")
    }
}
