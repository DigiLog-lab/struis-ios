import Foundation

/// 単元づくりの答えの分解(待ち時間の体験 §4.1)。端末で一瞬で確実に終わる処理だけを使う(W2):
/// 日付は `NSDataDetector`、学年は規則、科目・単元名は同梱の単元一覧(`UnitCatalog`)の辞書。
/// 意味の読み取りが要る言い換えはしない。つまずきは「どこでつまずいているか」への答えをそのまま 1 つのチップにする。
/// 拾えなかった要素はチップにしない(作り話のチップを出さない)。
nonisolated enum UnitCreationDecomposer {
    struct Answer: Sendable, Equatable {
        /// 答えた問い(`TurnCoordinator.unitCreationQuestions` の key)。
        let questionKey: String
        let text: String
    }

    struct Chip: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable {
            case grade, subject, unit, date, stumble
        }

        let kind: Kind
        /// チップに出す文字(学年・科目・単元名・日付は整えた形、つまずきは学習者の言葉のまま)。
        let label: String
        /// どの答えの、どこから拾ったか(文字数の位置)。
        let answerIndex: Int
        let range: Range<Int>
        /// 単元名のチップなら一覧の単元名、科目なら一覧の科目名、学年なら「中3」など(ふるいで使う)。
        let key: String

        var id: String { "\(answerIndex):\(range.lowerBound):\(kind.rawValue)" }

        /// このチップで規則として絞れるか(日付・つまずきは規則では絞れない)。
        var filters: Bool { kind == .grade || kind == .subject || kind == .unit }

        func keeps(_ candidate: UnitCatalog.Candidate) -> Bool {
            switch kind {
            case .grade: candidate.unit.grades.contains(key)
            case .subject: UnitCatalog.subjectMatches(unitSubject: candidate.unit.subject, chip: key)
            case .unit: candidate.unit.name == key
            case .date, .stumble: true
            }
        }
    }

    static let stumbleKey = "stumble"
    static let testKey = "test"

    static func chips(_ answers: [Answer]) -> [Chip] {
        var result: [Chip] = []
        for (index, answer) in answers.enumerated() {
            let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if answer.questionKey == stumbleKey {
                // つまずきは、答えをそのまま 1 つのチップにする(言い換えない)。
                result.append(Chip(kind: .stumble, label: text, answerIndex: index, range: 0..<answer.text.count, key: ""))
                continue
            }
            var taken: [Range<Int>] = []
            var found: [Chip] = []
            func take(_ chip: Chip) {
                guard !taken.contains(where: { $0.overlaps(chip.range) }) else { return }
                taken.append(chip.range)
                found.append(chip)
            }
            for chip in dates(answer.text, answerIndex: index, isTestAnswer: answer.questionKey == testKey) { take(chip) }
            for chip in grades(answer.text, answerIndex: index) { take(chip) }
            for chip in dictionaryMatches(answer.text, answerIndex: index) { take(chip) }
            result.append(contentsOf: found.sorted { $0.range.lowerBound < $1.range.lowerBound })
        }
        return result
    }

    // MARK: - 日付(NSDataDetector)

    static func dates(_ text: String, answerIndex: Int, isTestAnswer: Bool) -> [Chip] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let ns = text as NSString
        // Data detectors can omit Japanese numeric dates under an English system locale.
        // Normalize only explicit year/month/day spellings, then let the same detector
        // validate them. Keep the source ranges; never infer a day from "来月".
        let pattern = #"(?<![0-9０-９])(?:([0-9０-９]+)\s*年\s*)?([0-9０-９]+)\s*月\s*([0-9０-９]+)\s*日"#
        let originalMatches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let context = try? NSRegularExpression(pattern: #"(?:令和|平成|昭和|大正|明治|来年|再来年|今年|昨年|去年|一昨年|翌年|明年|next\s+year|last\s+year|this\s+year)(?:\s*の)?\s*$"#, options: .caseInsensitive)
        let numericMatches = (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        let literals = numericMatches.filter { literal in
            // Era/relative prefixes belong to Foundation's existing interpretation.
            // Also preserve any detector result that includes preceding date context.
            if originalMatches.contains(where: { $0.date != nil && $0.range.location < literal.range.location && NSIntersectionRange($0.range, literal.range) == literal.range }) { return false }
            let prefix = ns.substring(to: literal.range.location)
            return context?.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) == nil
        }
        var found: [Chip] = originalMatches.compactMap { match in
            // Invalid numeric dates must not be rolled into a different day by a detector.
            guard !literals.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { return nil }
            guard let date = match.date, let range = Range(match.range, in: text) else { return nil }
            // 日まで書かれた日付だけ(「来月」だけから日を作らない)。
            let written = String(text[range])
            guard written.contains("日") || written.contains("/") || written.contains("／") || written.contains("曜") else { return nil }
            let components = Calendar(identifier: .gregorian).dateComponents(in: match.timeZone ?? .current, from: date)
            guard let month = components.month, let day = components.day else { return nil }
            let label = (isTestAnswer ? "テスト " : "") + "\(month)/\(day)"
            return Chip(kind: .date, label: label, answerIndex: answerIndex, range: offsets(text, range), key: label)
        }
        for literal in literals {
            func number(_ group: Int) -> Int? {
                let range = literal.range(at: group)
                guard range.location != NSNotFound else { return nil }
                return Int(ns.substring(with: range).precomposedStringWithCompatibilityMapping)
            }
            let year: Int
            if literal.range(at: 1).location == NSNotFound {
                year = Calendar(identifier: .gregorian).component(.year, from: Date())
            } else {
                guard let writtenYear = number(1) else { continue }
                year = writtenYear
            }
            guard let month = number(2), let day = number(3), (1...12).contains(month), (1...31).contains(day), (1...9999).contains(year),
                  let range = Range(literal.range, in: text) else { continue }
            let normalized = String(format: "%04d-%02d-%02d", year, month, day)
            let whole = NSRange(location: 0, length: normalized.utf16.count)
            guard let match = detector.firstMatch(in: normalized, range: whole), match.range == whole, let date = match.date else { continue }
            let components = Calendar(identifier: .gregorian).dateComponents(in: match.timeZone ?? .current, from: date)
            guard components.year == year, components.month == month, components.day == day else { continue }
            let label = (isTestAnswer ? "テスト " : "") + "\(month)/\(day)"
            found.append(Chip(kind: .date, label: label, answerIndex: answerIndex, range: offsets(text, range), key: label))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - 学年(規則)

    private static let gradePatterns: [(pattern: String, prefix: String)] = [
        (#"(?:中学|中)\s*([1-3１-３一二三])\s*(?:年生|年)?"#, "中"),
        (#"(?:高校|高)\s*([1-3１-３一二三])\s*(?:年生|年)?"#, "高"),
        (#"(?:小学|小)\s*([1-6１-６一二三四五六])\s*(?:年生|年)?"#, "小"),
    ]

    static func grades(_ text: String, answerIndex: Int) -> [Chip] {
        var chips: [Chip] = []
        for (pattern, prefix) in gradePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let whole = Range(match.range, in: text), let digit = Range(match.range(at: 1), in: text),
                      let number = gradeNumber(String(text[digit]))
                else { continue }
                let label = prefix + String(number)
                chips.append(Chip(kind: .grade, label: label, answerIndex: answerIndex, range: offsets(text, whole), key: label))
            }
        }
        return chips
    }

    private static func gradeNumber(_ raw: String) -> Int? {
        let kanji = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6]
        if let value = kanji[raw] { return value }
        return Int(raw.precomposedStringWithCompatibilityMapping)
    }

    // MARK: - 科目・単元名(同梱の単元一覧の辞書)

    /// 辞書の見出し(書き方 → チップ)。長い書き方から先に探し、重なった所は拾わない(「数学Ⅱ」の中の「数学」を拾わない)。
    private static let dictionary: [(needle: String, kind: Chip.Kind, label: String)] = {
        var entries: [(String, Chip.Kind, String)] = UnitCatalog.subjectAliases.map { ($0.0, .subject, $0.1) }
        for unit in UnitCatalog.units {
            for name in [unit.name] + unit.aliases { entries.append((name, .unit, unit.name)) }
        }
        var seen = Set<String>()
        return entries.flatMap { entry in variants(entry.0).map { ($0, entry.1, entry.2) } }
            .filter { seen.insert($0.0 + "|" + $0.2).inserted }
            .sorted { $0.0.count > $1.0.count }
    }()

    /// 漢数字と算用数字の書き方の違い(「二次関数」と「2次関数」)。
    private static func variants(_ word: String) -> [String] {
        var values = [word]
        for (a, b) in [("1次", "一次"), ("2次", "二次"), ("3次", "三次"), ("2乗", "二乗")] {
            if word.contains(a) { values.append(word.replacingOccurrences(of: a, with: b)) }
            if word.contains(b) { values.append(word.replacingOccurrences(of: b, with: a)) }
        }
        return values
    }

    static func dictionaryMatches(_ text: String, answerIndex: Int) -> [Chip] {
        var chips: [Chip] = []
        var taken: [Range<Int>] = []
        var labels = Set<String>()
        for entry in dictionary {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: entry.needle, options: [.caseInsensitive, .widthInsensitive], range: searchStart..<text.endIndex) {
                let range = offsets(text, found)
                searchStart = found.upperBound
                guard !taken.contains(where: { $0.overlaps(range) }) else { continue }
                taken.append(range)
                // 同じ単元・科目は 1 つのチップにする(2 回書かれていても)。
                guard labels.insert("\(entry.kind.rawValue)|\(entry.label)").inserted else { continue }
                chips.append(Chip(kind: entry.kind, label: entry.label, answerIndex: answerIndex, range: range, key: entry.label))
            }
        }
        return chips
    }

    private static func offsets(_ text: String, _ range: Range<String.Index>) -> Range<Int> {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return lower..<upper
    }
}
