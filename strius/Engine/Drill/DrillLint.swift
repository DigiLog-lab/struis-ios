import Foundation

/// 点検で見つけた問題 1 つ。`message` はそのまま AI に返して書き直させる文。
nonisolated struct DrillIssue: Hashable, Sendable {
    /// 種類(decode・compile・count・undefined・display・numeric など)。
    let code: String
    let message: String
}

/// 表示の点検(docs/offline-drill/format.md「表示の点検」)。作った問題文・式・答えの文字列を見て、崩れた表示を見つける。
nonisolated enum DrillLint {
    /// 画面の数式描画(SwiftMath と、アプリの置き換え規則)が読める命令。ここに無い命令は使えない。
    static let allowedCommands: Set<String> = [
        "frac", "dfrac", "tfrac", "sqrt", "left", "right", "begin", "end", "text", "mathrm", "mathbf", "mathit", "boldsymbol", "bm", "overline", "underline",
        "binom", "operatorname", "displaystyle",
        "cdot", "times", "div", "pm", "mp", "le", "ge", "leq", "geq", "ne", "neq", "approx", "simeq", "sim", "equiv", "propto", "fallingdotseq",
        "infty", "pi", "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi",
        "rho", "sigma", "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega",
        "circ", "degree", "angle", "triangle", "perp", "parallel", "vec", "overrightarrow", "bar", "hat", "dot", "ddot", "tilde",
        "sin", "cos", "tan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "log", "ln", "exp", "lim", "max", "min", "gcd", "det",
        "sum", "int", "iint", "oint", "prod", "partial", "nabla",
        "to", "rightarrow", "leftarrow", "leftrightarrow", "longrightarrow", "Rightarrow", "Leftrightarrow", "uparrow", "downarrow",
        "quad", "qquad", "ldots", "cdots", "dots", "vdots", "ddots", "in", "notin", "subset", "cup", "cap", "emptyset", "mid", "vert", "lvert", "rvert",
        "lbrace", "rbrace", "langle", "rangle", "prime", "ell", "hbar", "therefore", "because", "cdotp", "colon", "ast", "star", "bullet",
    ]
    static let allowedEnvironments: Set<String> = ["cases", "pmatrix", "bmatrix", "vmatrix", "matrix", "aligned"]

    /// 係数として前に数を置く命令(`1\sqrt{2}`、`0\pi` を見つけるため)。
    private static let coefficientTargets: Set<String> = [
        "sqrt", "pi", "sin", "cos", "tan", "log", "ln", "exp", "vec", "overrightarrow", "frac", "dfrac", "tfrac", "left",
        "alpha", "beta", "gamma", "delta", "theta", "lambda", "mu", "omega", "phi", "varphi", "rho", "sigma", "tau", "Delta", "Omega",
    ]

    /// 文字列を、文と式(`$…$` の中)に分ける。`$` が閉じていなければ nil。
    static func split(_ mixed: String) -> (texts: [String], maths: [String])? {
        var texts: [String] = []
        var maths: [String] = []
        var current: String = ""
        var inMath: Bool = false
        var previous: Character = " "
        for c: Character in mixed {
            if c == "$", previous != "\\" {
                if inMath { maths.append(current) } else { texts.append(current) }
                current = ""
                inMath.toggle()
            } else {
                current.append(c)
            }
            previous = c
        }
        guard !inMath else { return nil }
        texts.append(current)
        return (texts, maths)
    }

    /// 問題 1 問の表示を点検する。見つけた問題を返す(空なら問題なし)。
    static func issues(in problem: DrillProblem) -> [String] {
        var found: [String] = []
        func mixed(_ value: String, _ place: String, isAnswer: Bool) {
            guard let pieces: (texts: [String], maths: [String]) = split(value) else {
                found.append("\(place)の「$」が閉じていません: \(value)")
                return
            }
            for text: String in pieces.texts {
                if let bad: Character = text.first(where: { (c: Character) -> Bool in "\\^_{}".contains(c) }) {
                    found.append("\(place)で、式が「$…$」の外にあります(「\(bad)」): \(value)")
                    break
                }
            }
            for math: String in pieces.maths {
                found += mathIssues(math, isAnswer: isAnswer).map { (issue: String) -> String in "\(place): \(issue): $\(math)$" }
            }
        }
        if problem.prompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty { found.append("問題文が空です") }
        if problem.answer.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty { found.append("答えが空です") }
        mixed(problem.prompt, "問題文", isAnswer: false)
        mixed(problem.answer, "答え", isAnswer: true)
        if !problem.math.isEmpty {
            if problem.math.contains("$") { found.append("math は LaTeX だけを書きます(「$」は要りません): \(problem.math)") }
            found += mathIssues(problem.math, isAnswer: false).map { (issue: String) -> String in "math: \(issue): \(problem.math)" }
        }
        return found
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    private static func isLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }

    /// 式 1 つ(LaTeX)の表示を点検する。`isAnswer` の時は、約分と平方根の整理も確かめる。
    static func mathIssues(_ math: String, isAnswer: Bool) -> [String] {
        var found: [String] = []
        let characters: [Character] = Array(math)
        if math.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty { return ["式が空です"] }
        for marker: String in ["nan", "NaN", "inf", "Optional(", "Drill"] where math.contains(marker) && !math.contains("\\inf") {
            found.append("値が数になっていません(\(marker))")
        }

        // 命令と環境。\text{…} と \mathrm{…} の中は、係数の点検から外す。
        var depth: Int = 0
        var index: Int = 0
        var plain: [Character] = []
        var skipDepth: Int? = nil
        while index < characters.count {
            let c: Character = characters[index]
            if c == "\\" {
                var end: Int = index + 1
                while end < characters.count, isLetter(characters[end]) { end += 1 }
                if end == index + 1 {
                    // \, \; \! \\ \{ \} \% など。空きとして残す。
                    if end < characters.count, !",;! \\{}%&:|".contains(characters[end]) { found.append("「\\\(characters[end])」は使えません") }
                    // 改行(\\)は式の切れ目。前後の数と文字をつなげて見ない。
                    if skipDepth == nil { plain.append(end < characters.count && characters[end] == "\\" ? ";" : " ") }
                    index = min(end + 1, characters.count)
                    continue
                }
                let name: String = String(characters[(index + 1)..<end])
                if !allowedCommands.contains(name) { found.append("命令「\\\(name)」は画面で描けません") }
                if name == "begin" || name == "end" {
                    let rest: String = String(characters[end...])
                    if let close: String.Index = rest.firstIndex(of: "}"), rest.hasPrefix("{") {
                        let environment: String = String(rest[rest.index(after: rest.startIndex)..<close])
                        if !allowedEnvironments.contains(environment) { found.append("環境「\(environment)」は画面で描けません") }
                        index = end + rest.distance(from: rest.startIndex, to: close) + 1
                        if skipDepth == nil { plain.append(" ") }
                        continue
                    }
                }
                if skipDepth == nil {
                    if name == "text" || name == "mathrm" || name == "operatorname" {
                        skipDepth = depth
                        plain.append("\u{1}")
                    } else {
                        plain.append("\\")
                        plain.append(contentsOf: name)
                        plain.append("\u{2}")
                    }
                }
                index = end
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth < 0 { found.append("波かっこ「}」が多すぎます"); depth = 0 }
                if let start: Int = skipDepth, depth == start { skipDepth = nil; index += 1; continue }
            }
            if skipDepth == nil { plain.append(c) } else if skipDepth == depth, c != "{" { skipDepth = nil; plain.append(c) }
            index += 1
        }
        if depth != 0 { found.append("波かっこが閉じていません") }

        // ここから先は、\text と \mathrm の中身を除いた文字列で見る。\u{1} は除いた跡、\u{2} は命令名の終わり。
        let compact: [Character] = plain.filter { (c: Character) -> Bool in c != " " && c != "\u{2}" }
        let compactText: String = String(compact)
        for pair: String in ["+-", "-+", "--", "++"] where compactText.contains(pair) {
            found.append("符号が重なっています(「\(pair)」)。+- は - に直します")
        }
        for pair: String in ["\\times-", "\\cdot-", "\\div-", "\\times+", "\\div+"] where compactText.contains(pair) {
            found.append("演算の後ろの符号つきの数は、かっこで囲みます(「\(pair)」)")
        }
        if compactText.contains("{}") {
            // 空の波かっこは、直後が ^ か _(前置きの添字)の時だけ使える。
            var search: Substring = Substring(compactText)
            while let range: Range<String.Index> = search.range(of: "{}") {
                let next: Character? = range.upperBound < search.endIndex ? search[range.upperBound] : nil
                if next != "^" && next != "_" { found.append("空の波かっこ「{}」があります"); break }
                search = search[range.upperBound...]
            }
        }
        if compactText.contains("()") { found.append("空のかっこ「()」があります") }

        // 数の並びを順に見る。
        let spaced: [Character] = plain
        var position: Int = 0
        func previousSignificant(_ at: Int) -> Character? {
            var cursor: Int = at - 1
            while cursor >= 0, spaced[cursor] == " " { cursor -= 1 }
            return cursor >= 0 ? spaced[cursor] : nil
        }
        func following(_ at: Int) -> (character: Character?, command: String?) {
            var cursor: Int = at
            while cursor < spaced.count, spaced[cursor] == " " { cursor += 1 }
            guard cursor < spaced.count else { return (nil, nil) }
            if spaced[cursor] == "\\" {
                var end: Int = cursor + 1
                while end < spaced.count, spaced[end] != "\u{2}" { end += 1 }
                return ("\\", String(spaced[(cursor + 1)..<end]))
            }
            return (spaced[cursor], nil)
        }
        while position < spaced.count {
            guard isDigit(spaced[position]) else { position += 1; continue }
            var end: Int = position
            while end < spaced.count, isDigit(spaced[end]) || (spaced[end] == "." && end + 1 < spaced.count && isDigit(spaced[end + 1])) { end += 1 }
            let literal: String = String(spaced[position..<end])
            let before: Character? = previousSignificant(position)
            let after: (character: Character?, command: String?) = following(end)
            let isScript: Bool = before == "^" || before == "_"
            let inScriptBraces: Bool = before == "{" && position >= 2 && (previousSignificant(position - 1) == "^" || previousSignificant(position - 1) == "_")
            if let fraction: Substring = literal.split(separator: ".").dropFirst().first, fraction.count > 10 {
                found.append("小数の桁が多すぎます(\(literal))。丸める桁数を決めてください")
            }
            // 指数の 1 と 0。積分や総和の上端(\int_{0}^{1}、\sum_{k=1}^{n})は指数ではないので見ない。
            let caret: Int? = { () -> Int? in
                var cursor: Int = position - 1
                while cursor >= 0, spaced[cursor] == " " || spaced[cursor] == "{" { cursor -= 1 }
                return cursor >= 0 && spaced[cursor] == "^" ? cursor : nil
            }()
            let isLimit: Bool = caret.map { (index: Int) -> Bool in isLimitSuperscript(spaced, caret: index) } ?? false
            if !isLimit, (isScript && before == "^") || (inScriptBraces && previousSignificant(position - 1) == "^" && after.character == "}") {
                if literal == "1" { found.append("1 乗は指数を書きません(x^1 は x)") }
                if literal == "0" { found.append("0 乗になっている所があります") }
                if isScript, literal.count > 1 { found.append("2 桁以上の指数は波かっこで囲みます(^\(literal))") }
            }
            if !isScript && !inScriptBraces {
                let attaches: Bool = after.character.map { (c: Character) -> Bool in isLetter(c) || c == "(" } ?? false
                let attachesCommand: Bool = after.command.map { (name: String) -> Bool in coefficientTargets.contains(name) } ?? false
                if literal == "1", attaches || attachesCommand {
                    found.append("係数の 1 は書きません(1x は x)")
                }
                if literal == "0" || Double(literal) == 0, attaches || attachesCommand {
                    found.append("係数が 0 の項があります(0x)")
                }
                if Double(literal) == 0, before == "-" {
                    found.append("「-0」になっている所があります")
                }
                if literal == "0", before == "+" || before == "-", after.character != "." {
                    let beforeSign: Character? = { () -> Character? in
                        var cursor: Int = position - 1
                        while cursor >= 0, spaced[cursor] == " " { cursor -= 1 }
                        cursor -= 1
                        while cursor >= 0, spaced[cursor] == " " { cursor -= 1 }
                        return cursor >= 0 ? spaced[cursor] : nil
                    }()
                    if beforeSign != nil, beforeSign != "=", beforeSign != "(", beforeSign != "," {
                        found.append("0 を足したり引いたりしています(+0)")
                    }
                }
            }
            position = end
        }

        // \frac と \sqrt の中身。
        found += structureIssues(String(plain.filter { (c: Character) -> Bool in c != "\u{2}" }), isAnswer: isAnswer)
        var seen: Set<String> = []
        return found.filter { (issue: String) -> Bool in seen.insert(issue).inserted }
    }

    /// `^` が、積分・総和の上端や、下付きの後ろの上付き(\int_{0}^{1}、\Big]_{0}^{1})か。
    private static func isLimitSuperscript(_ characters: [Character], caret: Int) -> Bool {
        var cursor: Int = caret - 1
        while cursor >= 0, characters[cursor] == " " { cursor -= 1 }
        guard cursor >= 0 else { return false }
        if characters[cursor] == "\u{2}" {
            // 命令の直後: \int^{…}、\sum^{…}
            var start: Int = cursor - 1
            while start >= 0, characters[start] != "\\" { start -= 1 }
            guard start >= 0 else { return false }
            return ["int", "sum", "prod", "iint", "oint"].contains(String(characters[(start + 1)..<cursor]))
        }
        if characters[cursor] == "}" {
            // 下付き `_{…}` の後ろか。
            var depth: Int = 0
            while cursor >= 0 {
                if characters[cursor] == "}" { depth += 1 }
                if characters[cursor] == "{" {
                    depth -= 1
                    if depth == 0 { break }
                }
                cursor -= 1
            }
            cursor -= 1
            while cursor >= 0, characters[cursor] == " " { cursor -= 1 }
            return cursor >= 0 && characters[cursor] == "_"
        }
        // 下付き `_a` の後ろか。
        var before: Int = cursor - 1
        while before >= 0, characters[before] == " " { before -= 1 }
        return before >= 0 && characters[before] == "_"
    }

    /// `{…}` の中身を取り出す(`open` は `{` の位置)。
    private static func group(_ characters: [Character], open: Int) -> (content: String, end: Int)? {
        guard open < characters.count, characters[open] == "{" else { return nil }
        var depth: Int = 0
        for index: Int in open..<characters.count {
            if characters[index] == "{" { depth += 1 }
            if characters[index] == "}" {
                depth -= 1
                if depth == 0 { return (String(characters[(open + 1)..<index]), index + 1) }
            }
        }
        return nil
    }

    private static func structureIssues(_ math: String, isAnswer: Bool) -> [String] {
        var found: [String] = []
        let characters: [Character] = Array(math)
        var index: Int = 0
        while index < characters.count {
            guard characters[index] == "\\" else { index += 1; continue }
            var end: Int = index + 1
            while end < characters.count, isLetter(characters[end]) { end += 1 }
            let name: String = String(characters[(index + 1)..<end])
            var cursor: Int = end
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            if name == "frac" || name == "dfrac" || name == "tfrac" {
                if let top: (content: String, end: Int) = group(characters, open: cursor) {
                    var next: Int = top.end
                    while next < characters.count, characters[next] == " " { next += 1 }
                    if let bottom: (content: String, end: Int) = group(characters, open: next) {
                        let numerator: String = top.content.trimmingCharacters(in: CharacterSet.whitespaces)
                        let denominator: String = bottom.content.trimmingCharacters(in: CharacterSet.whitespaces)
                        if numerator.isEmpty || denominator.isEmpty { found.append("分数の分子か分母が空です") }
                        if denominator == "1" { found.append("分母が 1 の分数があります") }
                        if denominator == "0" { found.append("分母が 0 の分数があります") }
                        if numerator == "0" { found.append("分子が 0 の分数があります") }
                        if denominator.hasPrefix("-"), Double(denominator) != nil { found.append("分母が負の数です。符号は分数の前に出します") }
                        if isAnswer, let a: Int = Int(numerator), let b: Int = Int(denominator), a != 0, b > 1, DrillRational.gcd(abs(a), b) != 1 {
                            found.append("約分できる分数が答えにあります(\\frac{\(a)}{\(b)})")
                        }
                    } else {
                        found.append("\\\(name) の分母がありません")
                    }
                } else {
                    found.append("\\\(name) の分子は波かっこで囲みます")
                }
            }
            if name == "sqrt", cursor < characters.count, characters[cursor] != "[" {
                if let inside: (content: String, end: Int) = group(characters, open: cursor) {
                    let content: String = inside.content.trimmingCharacters(in: CharacterSet.whitespaces)
                    if content.isEmpty { found.append("根号の中が空です") }
                    if content.hasPrefix("-"), Double(content) != nil { found.append("根号の中が負の数です(\\sqrt{\(content)})") }
                    if isAnswer, let value: Int = Int(content), value >= 0 {
                        if value <= 1 {
                            found.append("\\sqrt{\(value)} は \(value) と書きます")
                        } else if let parts: (root: Int, free: Int) = DrillExact.squareParts(of: value), parts.root > 1 {
                            found.append("答えの平方根が整理されていません(\\sqrt{\(value)})")
                        }
                    }
                } else {
                    found.append("\\sqrt の中は波かっこで囲みます")
                }
            }
            index = end
        }
        return found
    }
}
