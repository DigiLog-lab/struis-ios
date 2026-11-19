import CoreGraphics
import Foundation

/// 図形の問題の図と、関数のグラフ(2026-11-19 のプロトタイプ)。
///
/// 中2「図形の合同」のように、図に書いた角度や点の位置を前提にする問題は、問題文と式だけでは出せなかった。モデルに SVG を
/// 書かせると、点の位置と角の大きさが合っているかをアプリが確かめられない。そこで、モデルには点の座標・線分・角の印・
/// 関数の式をデータで返させ、アプリが描く。受け取る前に、度数を書いた角・直角・等しい長さ・平行・等しい角の印が、
/// 座標から計算した値と合うかを確かめる(合わない図は、生徒が図を見て解いた答えと正しい答えが食い違うので受け取らない)。
///
/// - 平面の図: 座標は数学と同じ向き(y が上)。単位は自由で、アプリが画面の幅に合わせて縮める。
/// - 立体: どれかの点の `z` が 0 でなければ立体として、x を右・y を奥行き・z を上にとり、斜めから見た図(斜投影)にする。
///   角・長さの点検は立体の座標のまま行う。
/// - グラフ: `axes` があれば座標平面。`curves` の式(y = f(x)、または媒介変数 t の x(t)・y(t))を描き、`fills` で
///   2 つの式の間を塗る。
nonisolated struct TimelineFigure: Equatable, Sendable {
    nonisolated struct Point: Equatable, Sendable {
        var name: String
        var x: Double
        var y: Double
        var z: Double = 0
        /// 名前が `_` で始まる点は、線や塗りの角に使うだけの点(ヒストグラムの棒の角・箱ひげ図の端など)。点も名前も描かない。
        var isHidden: Bool { name.hasPrefix("_") }
    }

    nonisolated struct Segment: Equatable, Sendable {
        var from: String
        var to: String
        /// 補助線・見えない辺などの点線。
        var dashed: Bool
        /// 等しい長さの印(辺の真ん中の短い線の本数)。0 なら無し。
        var ticks: Int
        /// 平行の印(矢じりの数)。0 なら無し。
        var arrows: Int
        /// `to` の端に矢印を付ける(ベクトル)。
        var head: Bool = false
        /// 辺に添える文字(「6 cm」「$x$」)。
        var label: String = ""
    }

    nonisolated struct Angle: Equatable, Sendable {
        /// 角の頂点と、角を挟む 2 つの点(∠from-vertex-to)。
        var vertex: String
        var from: String
        var to: String
        /// 角に添える文字(「61°」「x」「?」)。空なら弧だけ。
        var label: String
        /// 弧の本数。2 本以上は「同じ本数の角は等しい」の印(1 本はただの印)。
        var arcs: Int
        /// 直角の印(四角)。
        var right: Bool
    }

    nonisolated struct Circle: Equatable, Sendable {
        var center: String
        var radius: Double
        var dashed: Bool = false
    }

    /// 円の一部(おうぎ形の弧など)。`center` を中心に、`from` から `to` へ反時計回り。
    nonisolated struct Arc: Equatable, Sendable {
        var center: String
        var from: String
        var to: String
        var label: String = ""
    }

    /// 薄く塗る多角形(面積を求める部分・断面など)。
    nonisolated struct Region: Equatable, Sendable {
        var points: [String]
    }

    nonisolated struct Axes: Equatable, Sendable {
        var xMin: Double
        var xMax: Double
        var yMin: Double
        var yMax: Double
        /// 目盛りの数字を出す。
        var ticks: Bool
        /// 方眼を出す。
        var grid: Bool
        /// x の目盛りを π/2 ごとにして「π/2」「π」と書く(三角関数のグラフ)。
        var piTicks: Bool = false
    }

    nonisolated struct Curve: Equatable, Sendable {
        /// y = f(x) の右辺(例: `x^2-2*x`)。空なら媒介変数の `xExpr`・`yExpr`。
        var expr: String
        var xExpr: String = ""
        var yExpr: String = ""
        /// x(媒介変数なら t)の範囲。
        var from: Double
        var to: Double
        var dashed: Bool = false
        var label: String = ""
    }

    /// `upper` と `lower`(どちらも x の式)の間を、x が `from` から `to` の範囲で塗る。
    nonisolated struct Fill: Equatable, Sendable {
        var upper: String
        var lower: String
        var from: Double
        var to: Double
    }

    var points: [Point]
    var segments: [Segment]
    var angles: [Angle]
    var circles: [Circle]
    var arcs: [Arc] = []
    var regions: [Region] = []
    var axes: Axes?
    var curves: [Curve] = []
    var fills: [Fill] = []

    /// 印を付けた角の大きさと、座標から計算した大きさのずれの許し(度)。
    static let angleTolerance: Double = 4
    /// 等しい長さの印を付けた辺の長さのずれの許し(割合)。
    static let lengthTolerance: Double = 0.04
    /// 平行の印を付けた辺の向きのずれの許し(度)。
    static let parallelTolerance: Double = 2

    init(points: [Point], segments: [Segment], angles: [Angle] = [], circles: [Circle] = []) {
        self.points = points
        self.segments = segments
        self.angles = angles
        self.circles = circles
    }

    /// カードの `figure`(モデルの返事のまま)から読む。null・空・形が違うものは nil。
    init?(_ json: LedgerJSON?) {
        guard let object = json?.objectValue else { return nil }
        func string(_ value: LedgerJSON?) -> String { value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func count(_ value: LedgerJSON?, default fallback: Int = 0) -> Int { max(0, min(3, value?.intValue ?? fallback)) }
        points = (object["points"]?.arrayValue ?? []).compactMap { row in
            guard let x = row["x"]?.doubleValue, let y = row["y"]?.doubleValue else { return nil }
            return Point(name: string(row["name"]), x: x, y: y, z: row["z"]?.doubleValue ?? 0)
        }
        segments = (object["segments"]?.arrayValue ?? []).map { row in
            Segment(from: string(row["from"]), to: string(row["to"]), dashed: row["dashed"]?.boolValue ?? false, ticks: count(row["ticks"]),
                    arrows: count(row["arrows"]), head: row["head"]?.boolValue ?? false, label: string(row["label"]))
        }
        angles = (object["angles"]?.arrayValue ?? []).map { row in
            Angle(vertex: string(row["vertex"]), from: string(row["from"]), to: string(row["to"]), label: string(row["label"]),
                  arcs: count(row["arcs"], default: 1), right: row["right"]?.boolValue ?? false)
        }
        circles = (object["circles"]?.arrayValue ?? []).compactMap { row in
            guard let radius = row["radius"]?.doubleValue else { return nil }
            return Circle(center: string(row["center"]), radius: radius, dashed: row["dashed"]?.boolValue ?? false)
        }
        arcs = (object["arcs"]?.arrayValue ?? []).map { row in
            Arc(center: string(row["center"]), from: string(row["from"]), to: string(row["to"]), label: string(row["label"]))
        }
        regions = (object["regions"]?.arrayValue ?? []).map { row in
            Region(points: (row["points"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        if let a = object["axes"]?.objectValue, let x0 = a["x_min"]?.doubleValue, let x1 = a["x_max"]?.doubleValue,
           let y0 = a["y_min"]?.doubleValue, let y1 = a["y_max"]?.doubleValue {
            axes = Axes(xMin: x0, xMax: x1, yMin: y0, yMax: y1, ticks: a["ticks"]?.boolValue ?? true, grid: a["grid"]?.boolValue ?? false,
                        piTicks: a["pi_ticks"]?.boolValue ?? false)
        }
        curves = (object["curves"]?.arrayValue ?? []).compactMap { row in
            guard let from = row["from"]?.doubleValue, let to = row["to"]?.doubleValue else { return nil }
            return Curve(expr: string(row["expr"]), xExpr: string(row["x_expr"]), yExpr: string(row["y_expr"]), from: from, to: to,
                         dashed: row["dashed"]?.boolValue ?? false, label: string(row["label"]))
        }
        fills = (object["fills"]?.arrayValue ?? []).compactMap { row in
            guard let from = row["from"]?.doubleValue, let to = row["to"]?.doubleValue else { return nil }
            return Fill(upper: string(row["upper"]), lower: string(row["lower"]), from: from, to: to)
        }
        // 点も式も無い図は描くものが無い。
        guard !points.isEmpty || !curves.isEmpty || axes != nil else { return nil }
    }

    func point(_ name: String) -> Point? { points.first { $0.name == name } }

    /// 立体か(どれかの点が高さを持つ)。
    var isSpace: Bool { axes == nil && points.contains { $0.z != 0 } }

    // MARK: 平面に写す

    /// 斜投影の奥行きの縮め方と向き(教科書の見取図と同じく、奥へ右上 35°、長さ半分)。
    static let depthScale: Double = 0.5
    static let depthAngle: Double = 35 * .pi / 180

    /// 点を描く平面の座標(y 上向き)。立体は斜投影する。
    func plane(_ p: Point) -> (x: Double, y: Double) { plane(p.x, p.y, p.z) }

    func plane(_ x: Double, _ y: Double, _ z: Double) -> (x: Double, y: Double) {
        guard isSpace else { return (x, y) }
        return (x + Self.depthScale * y * cos(Self.depthAngle), z + Self.depthScale * y * sin(Self.depthAngle))
    }

    // MARK: 式

    static func expression(_ source: String) -> TimelineExpression? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return try? TimelineExpression.parse(text)
    }

    static func value(_ expression: TimelineExpression, _ name: String, _ v: Double) -> Double? {
        guard let value = expression.evaluate([name: v, "pi": .pi]), value.isFinite else { return nil }
        return value
    }

    /// 曲線の点(平面の座標)。式が読めなければ空。値が無い所(定義されない・無限大)は nil で区切る。
    func samples(of curve: Curve, count: Int = 480) -> [(x: Double, y: Double)?] {
        guard curve.to > curve.from else { return [] }
        if let f = Self.expression(curve.expr) {
            var from = curve.from, to = curve.to
            if let axes { from = max(from, axes.xMin); to = min(to, axes.xMax) }
            guard to > from else { return [] }
            return (0...count).map { i in
                let x = from + (to - from) * Double(i) / Double(count)
                return Self.value(f, "x", x).map { (x: x, y: $0) }
            }
        }
        guard let fx = Self.expression(curve.xExpr), let fy = Self.expression(curve.yExpr) else { return [] }
        return (0...count).map { i in
            let t = curve.from + (curve.to - curve.from) * Double(i) / Double(count)
            guard let x = Self.value(fx, "t", t), let y = Self.value(fy, "t", t) else { return nil }
            return (x: x, y: y)
        }
    }

    // MARK: 受け取る前の点検

    /// 図の欠け(受け取りを断る理由)。空なら受け取ってよい。
    var defects: [String] {
        var defects: [String] = []
        let names = points.map(\.name)
        if names.contains(where: \.isEmpty) { defects.append("figure: a point has no name") }
        let duplicated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        if !duplicated.isEmpty { defects.append("figure: duplicated point names " + duplicated.sorted().joined(separator: ", ")) }
        if points.contains(where: { !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite }) { defects.append("figure: a coordinate is not a number") }
        if let axes {
            defects += axesDefects(axes)
        } else {
            guard let bounds, bounds.width > 0, bounds.height > 0 else {
                defects.append("figure: the points lie on one line or one point")
                return defects
            }
        }
        // 重なった点は名前の文字が重なって読めない(平面に写した位置で見る)。
        if let bounds {
            let diagonal = hypot(bounds.width, bounds.height)
            let shown = points.filter { !$0.isHidden }
            for (i, a) in shown.enumerated() {
                for b in shown[(i + 1)...] {
                    let pa = plane(a), pb = plane(b)
                    if hypot(pa.x - pb.x, pa.y - pb.y) < diagonal * 0.02 { defects.append("figure: points \(a.name) and \(b.name) overlap") }
                }
            }
        }
        for segment in segments {
            let missing = [segment.from, segment.to].filter { point($0) == nil }
            if !missing.isEmpty { defects.append("figure: segment \(segment.from)\(segment.to) uses unknown points " + missing.joined(separator: ", ")) }
            else if segment.from == segment.to { defects.append("figure: segment \(segment.from)\(segment.to) has no length") }
        }
        defects += lengthDefects() + parallelDefects()
        for angle in angles {
            let missing = [angle.from, angle.vertex, angle.to].filter { point($0) == nil }
            if !missing.isEmpty {
                defects.append("figure: angle \(angle.from)\(angle.vertex)\(angle.to) uses unknown points " + missing.joined(separator: ", "))
                continue
            }
            guard let measured = degrees(of: angle) else {
                defects.append("figure: angle \(angle.from)\(angle.vertex)\(angle.to) has no size")
                continue
            }
            if angle.right, abs(measured - 90) > Self.angleTolerance {
                defects.append(String(format: "figure: angle %@%@%@ is marked right but measures %.0f°", angle.from, angle.vertex, angle.to, measured))
            }
            if let labeled = Self.labeledDegrees(angle.label), abs(measured - labeled) > Self.angleTolerance {
                defects.append(String(format: "figure: angle %@%@%@ is labeled %@ but measures %.0f° from the coordinates", angle.from, angle.vertex, angle.to,
                                      angle.label, measured))
            }
        }
        defects += equalAngleDefects()
        for circle in circles {
            if point(circle.center) == nil { defects.append("figure: circle center \(circle.center) is unknown") }
            if !(circle.radius > 0) { defects.append("figure: circle around \(circle.center) has no radius") }
        }
        for arc in arcs {
            guard let c = point(arc.center), let a = point(arc.from), let b = point(arc.to) else {
                defects.append("figure: arc \(arc.from)\(arc.to) around \(arc.center) uses unknown points")
                continue
            }
            let ra = Self.distance(c, a), rb = Self.distance(c, b)
            if ra == 0 || abs(ra - rb) > max(ra, rb) * Self.lengthTolerance {
                defects.append("figure: arc \(arc.from)\(arc.to) — \(arc.from) and \(arc.to) are not on one circle around \(arc.center)")
            }
        }
        for region in regions {
            let missing = region.points.filter { point($0) == nil }
            if region.points.count < 3 || !missing.isEmpty { defects.append("figure: region \(region.points.joined()) needs 3+ known points") }
        }
        return defects
    }

    private func axesDefects(_ axes: Axes) -> [String] {
        var defects: [String] = []
        guard axes.xMax > axes.xMin, axes.yMax > axes.yMin else { return ["figure: axes need x_min < x_max and y_min < y_max"] }
        let marginX = (axes.xMax - axes.xMin) * 0.02, marginY = (axes.yMax - axes.yMin) * 0.02
        for p in points where p.x < axes.xMin - marginX || p.x > axes.xMax + marginX || p.y < axes.yMin - marginY || p.y > axes.yMax + marginY {
            defects.append("figure: point \(p.name) is outside the axes window")
        }
        for curve in curves {
            let usesFunction = Self.expression(curve.expr) != nil
            if !usesFunction, Self.expression(curve.xExpr) == nil || Self.expression(curve.yExpr) == nil {
                defects.append("figure: curve \(curve.label.isEmpty ? curve.expr : curve.label) cannot be read")
                continue
            }
            let visible = samples(of: curve).compactMap { $0 }.filter { $0.y >= axes.yMin && $0.y <= axes.yMax && $0.x >= axes.xMin && $0.x <= axes.xMax }
            if visible.count < 20 { defects.append("figure: curve \(curve.label.isEmpty ? curve.expr : curve.label) is almost outside the axes window") }
        }
        for fill in fills where Self.expression(fill.upper) == nil || Self.expression(fill.lower) == nil || !(fill.to > fill.from) {
            defects.append("figure: fill between \(fill.upper) and \(fill.lower) cannot be read")
        }
        return defects
    }

    /// 等しい長さの印: 同じ本数の印の辺は同じ長さ。
    private func lengthDefects() -> [String] {
        var defects: [String] = []
        for ticks in Set(segments.map(\.ticks)).sorted() where ticks > 0 {
            let group = segments.filter { $0.ticks == ticks }
            let lengths = group.compactMap { s -> Double? in point(s.from).flatMap { a in point(s.to).map { Self.distance(a, $0) } } }
            guard let shortest = lengths.min(), let longest = lengths.max(), lengths.count == group.count, group.count > 1 else { continue }
            if longest - shortest > longest * Self.lengthTolerance {
                defects.append(String(format: "figure: segments %@ have %d equal-length ticks but measure %@", group.map { $0.from + $0.to }.joined(separator: ", "),
                                      ticks, lengths.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
            }
        }
        return defects
    }

    /// 平行の印: 同じ数の矢じりの辺は平行。
    private func parallelDefects() -> [String] {
        var defects: [String] = []
        for arrows in Set(segments.map(\.arrows)).sorted() where arrows > 0 {
            let group = segments.filter { $0.arrows == arrows }
            let directions = group.compactMap { s -> (Double, Double, Double)? in
                guard let a = point(s.from), let b = point(s.to) else { return nil }
                return (b.x - a.x, b.y - a.y, b.z - a.z)
            }
            guard let first = directions.first, directions.count == group.count, group.count > 1 else { continue }
            for (index, d) in directions.enumerated().dropFirst() {
                let between = Self.angle(first, d)
                if min(between, 180 - between) > Self.parallelTolerance {
                    defects.append(String(format: "figure: segments %@%@ and %@%@ are marked parallel but differ by %.0f°", group[0].from, group[0].to,
                                          group[index].from, group[index].to, min(between, 180 - between)))
                }
            }
        }
        return defects
    }

    /// 等しい角の印: 同じ本数(2 本以上)の弧の角は等しい。
    private func equalAngleDefects() -> [String] {
        var defects: [String] = []
        for arcs in Set(angles.map(\.arcs)).sorted() where arcs >= 2 {
            let group = angles.filter { $0.arcs == arcs && !$0.right }
            let sizes = group.compactMap { degrees(of: $0) }
            guard let low = sizes.min(), let high = sizes.max(), sizes.count == group.count, group.count > 1 else { continue }
            if high - low > Self.angleTolerance {
                defects.append(String(format: "figure: angles %@ have %d arcs (equal) but measure %@", group.map { $0.from + $0.vertex + $0.to }.joined(separator: ", "),
                                      arcs, sizes.map { String(format: "%.0f°", $0) }.joined(separator: ", ")))
            }
        }
        return defects
    }

    static func distance(_ a: Point, _ b: Point) -> Double { sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2)) }

    /// 2 つの向きのなす角(0〜180 度)。
    static func angle(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = sqrt(a.0 * a.0 + a.1 * a.1 + a.2 * a.2), lb = sqrt(b.0 * b.0 + b.1 * b.1 + b.2 * b.2)
        guard la > 0, lb > 0 else { return 0 }
        let cosine = max(-1, min(1, (a.0 * b.0 + a.1 * b.1 + a.2 * b.2) / (la * lb)))
        return acos(cosine) * 180 / .pi
    }

    /// 座標から計算した ∠from-vertex-to の大きさ(0〜180 度。立体は立体の座標のまま)。
    func degrees(of angle: Angle) -> Double? {
        guard let v = point(angle.vertex), let a = point(angle.from), let b = point(angle.to) else { return nil }
        guard Self.distance(v, a) > 0, Self.distance(v, b) > 0 else { return nil }
        return Self.angle((a.x - v.x, a.y - v.y, a.z - v.z), (b.x - v.x, b.y - v.y, b.z - v.z))
    }

    /// 角の文字が度数(「61°」「$61^\circ$」「61」)なら、その数。文字(「x」「?」)なら nil。
    static func labeledDegrees(_ label: String) -> Double? {
        var text = label
        for token in ["$", "^\\circ", "^{\\circ}", "\\circ", "°", "度", " "] { text = text.replacingOccurrences(of: token, with: "") }
        return Double(text)
    }

    /// 画面に出す文字。`$…$` の式は読める文字に直す(図の中は 1 行の短い文字なので、組版はしない)。
    static func displayLabel(_ label: String) -> String {
        var text = label
        for (token, replacement) in [("^{\\circ}", "°"), ("^\\circ", "°"), ("\\circ", "°")] { text = text.replacingOccurrences(of: token, with: replacement) }
        // 図の文字によく出る記号は、先に文字に直す(読める文字に直す処理は `\ell` を「ell」にする)。
        for (token, replacement) in [("\\ell", "ℓ"), ("\\theta", "θ"), ("\\alpha", "α"), ("\\beta", "β"), ("\\pi", "π"), ("\\angle", "∠"),
                                     ("\\triangle", "△"), ("\\parallel", "∥"), ("\\perp", "⊥"), ("\\vec", "")] {
            text = text.replacingOccurrences(of: token, with: replacement)
        }
        if text.contains("\\") || text.contains("^") || text.contains("_") {
            text = MathPlainText.preview("\\(" + text.replacingOccurrences(of: "$", with: "") + "\\)")
        }
        text = text.replacingOccurrences(of: "$", with: "")
        if !text.contains("\\") { text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "") }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 問題文が図を前提にしているか(「右の図で」「図の」「右のグラフ」)。「図形」は図を指さず、「次の関数のグラフの周期」のように
    /// グラフという言葉を使うだけの問題も図を前提にしないので数えない(2026-11-19 の実際の出題で、三角関数の問題が断られた)。
    static func mentionsFigure(_ text: String) -> Bool {
        text.range(of: #"図(?!形)|(右|左|上|下|この|その)の?グラフ"#, options: .regularExpression) != nil
    }

    // MARK: 描く位置

    /// 描く範囲(平面の座標)。座標平面は窓そのもの。
    var bounds: CGRect? {
        if let axes, axes.xMax > axes.xMin, axes.yMax > axes.yMin {
            return CGRect(x: axes.xMin, y: axes.yMin, width: axes.xMax - axes.xMin, height: axes.yMax - axes.yMin)
        }
        var rect: CGRect?
        func add(_ x: Double, _ y: Double) {
            guard x.isFinite, y.isFinite else { return }
            let r = CGRect(x: x, y: y, width: 0, height: 0)
            rect = rect.map { $0.union(r) } ?? r
        }
        for p in points { let q = plane(p); add(q.x, q.y) }
        for c in circles {
            guard let center = point(c.center), c.radius > 0 else { continue }
            for k in 0..<16 {
                let t = Double(k) / 16 * 2 * .pi
                let q = plane(center.x + c.radius * cos(t), center.y + c.radius * sin(t), center.z)
                add(q.x, q.y)
            }
        }
        return rect
    }

    /// 横 ÷ 縦(画面の枠の形を決める)。細長すぎる図は、枠が極端にならないように抑える。
    var aspectRatio: CGFloat {
        guard let b = bounds, b.width > 0, b.height > 0 else { return 1.6 }
        return max(axes == nil ? 0.8 : 0.75, min(2.2, b.width / b.height))
    }

    /// 平面の座標から画面の座標へ。座標平面は、窓の縦横の比が枠に合わない時だけ縦と横の縮め方を変える。
    nonisolated struct Layout: Sendable {
        var originX: Double, originY: Double, scaleX: Double, scaleY: Double, minX: Double, maxY: Double
        func callAsFunction(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: originX + (x - minX) * scaleX, y: originY + (maxY - y) * scaleY)
        }
    }

    func layout(in size: CGSize, inset: CGFloat) -> Layout {
        guard let b = bounds, b.width > 0 || b.height > 0 else {
            return Layout(originX: size.width / 2, originY: size.height / 2, scaleX: 1, scaleY: 1, minX: 0, maxY: 0)
        }
        let usableW = max(1, Double(size.width - inset * 2)), usableH = max(1, Double(size.height - inset * 2))
        var sx = b.width > 0 ? usableW / b.width : .infinity, sy = b.height > 0 ? usableH / b.height : .infinity
        let uniform = min(sx, sy)
        let ratio = b.height > 0 ? b.width / b.height : 1
        if axes == nil || (ratio >= 0.75 && ratio <= 2.2) || !sx.isFinite || !sy.isFinite {
            sx = uniform
            sy = uniform
        }
        let originX = (Double(size.width) - b.width * sx) / 2, originY = (Double(size.height) - b.height * sy) / 2
        return Layout(originX: originX, originY: originY, scaleX: sx, scaleY: sy, minX: b.minX, maxY: b.maxY)
    }

    /// 点を画面に置く関数(テストと古い呼び方のため)。
    func transform(in size: CGSize, inset: CGFloat) -> (Point) -> CGPoint {
        let layout = layout(in: size, inset: inset)
        return { p in let q = plane(p); return layout(q.x, q.y) }
    }

    /// 点の名前を置く向き(単位ベクトル、画面の座標)。点から出ている線・点を通る線・印を付けた角・通る曲線と軸の向きを避け、
    /// いちばん広く空いている向きの真ん中に置く。何も出ていない点は、図の中心の反対側。
    func labelDirection(of p: Point) -> CGVector {
        var occupied: [Double] = []
        func add(_ dx: Double, _ dy: Double) {
            guard hypot(dx, dy) > 1e-9 else { return }
            occupied.append(atan2(dy, dx))
        }
        let diagonal = bounds.map { hypot($0.width, $0.height) } ?? 1
        let pp = plane(p)
        for s in segments {
            guard let a = point(s.from), let b = point(s.to) else { continue }
            let pa = plane(a), pb = plane(b)
            if s.from == p.name { add(pb.x - pp.x, pb.y - pp.y) }
            else if s.to == p.name { add(pa.x - pp.x, pa.y - pp.y) }
            else if let t = parameter(of: p, onSegmentFrom: a, to: b, tolerance: diagonal * 0.01), t > 0.001, t < 0.999 {
                // 線の途中の点(交点など): 線は両側へ出ている。
                add(pb.x - pa.x, pb.y - pa.y)
                add(pa.x - pb.x, pa.y - pb.y)
            }
        }
        for angle in angles where angle.vertex == p.name {
            guard let a = point(angle.from), let b = point(angle.to) else { continue }
            let pa = plane(a), pb = plane(b)
            let la = hypot(pa.x - pp.x, pa.y - pp.y), lb = hypot(pb.x - pp.x, pb.y - pp.y)
            guard la > 0, lb > 0 else { continue }
            // 弧と角の文字は 2 本の線の間(二等分線の向き)にある。
            add((pa.x - pp.x) / la + (pb.x - pp.x) / lb, (pa.y - pp.y) / la + (pb.y - pp.y) / lb)
        }
        if let axes {
            // 軸の上の点は軸の向きを、曲線の上の点は接線の向きを避ける。縮め方の違う座標平面では、画面の上での向きで比べる。
            let ratio = (axes.xMax - axes.xMin) / max(axes.yMax - axes.yMin, 1e-9)
            let toleranceX = (axes.xMax - axes.xMin) * 0.012, toleranceY = (axes.yMax - axes.yMin) * 0.012
            if abs(p.y) < toleranceY { add(1, 0); add(-1, 0) }
            if abs(p.x) < toleranceX { add(0, 1); add(0, -1) }
            for curve in curves {
                let samples = samples(of: curve).compactMap { $0 }
                func gap(_ q: (x: Double, y: Double)) -> Double { hypot((q.x - p.x) / max(toleranceX, 1e-9), (q.y - p.y) / max(toleranceY, 1e-9)) }
                guard let nearest = samples.indices.min(by: { gap(samples[$0]) < gap(samples[$1]) }), gap(samples[nearest]) < 1.5 else { continue }
                if nearest + 1 < samples.count { add(samples[nearest + 1].x - p.x, (samples[nearest + 1].y - p.y) * ratio) }
                if nearest > 0 { add(samples[nearest - 1].x - p.x, (samples[nearest - 1].y - p.y) * ratio) }
            }
        }
        let direction: Double
        if occupied.isEmpty {
            let planes = points.map { plane($0) }
            let cx = planes.map(\.x).reduce(0, +) / Double(max(1, planes.count)), cy = planes.map(\.y).reduce(0, +) / Double(max(1, planes.count))
            direction = hypot(pp.x - cx, pp.y - cy) > 1e-9 ? atan2(pp.y - cy, pp.x - cx) : .pi / 2
        } else if occupied.count == 1 {
            direction = occupied[0] + .pi
        } else {
            let sorted = occupied.sorted()
            var best = (gap: -1.0, middle: 0.0)
            for (index, angle) in sorted.enumerated() {
                let next = index + 1 < sorted.count ? sorted[index + 1] : sorted[0] + 2 * .pi
                let gap = next - angle
                if gap > best.gap { best = (gap, angle + gap / 2) }
            }
            direction = best.middle
        }
        // 図の向き(y 上向き)を、画面の座標(y 下向き)に直す。
        return CGVector(dx: cos(direction), dy: -sin(direction))
    }

    /// 点 p が線分 ab の上にあれば、a から b へのどこか(0〜1)。上に無ければ nil(平面に写した位置で見る)。
    func parameter(of p: Point, onSegmentFrom a: Point, to b: Point, tolerance: Double) -> Double? {
        let pp = plane(p), pa = plane(a), pb = plane(b)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return nil }
        let t = ((pp.x - pa.x) * dx + (pp.y - pa.y) * dy) / length2
        guard t >= -1e-9, t <= 1 + 1e-9 else { return nil }
        let distance = hypot(pa.x + t * dx - pp.x, pa.y + t * dy - pp.y)
        return distance <= tolerance ? t : nil
    }

    /// 線分 ab と線分 cd が交わる所(ab の上のどこか、0〜1。平面に写した位置で見る)。平行・交わらなければ nil。
    func crossing(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Double? {
        let pa = plane(a), pb = plane(b), pc = plane(c), pd = plane(d)
        let rx = pb.x - pa.x, ry = pb.y - pa.y, sx = pd.x - pc.x, sy = pd.y - pc.y
        let denominator = rx * sy - ry * sx
        guard abs(denominator) > 1e-12 else { return nil }
        let t = ((pc.x - pa.x) * sy - (pc.y - pa.y) * sx) / denominator
        let u = ((pc.x - pa.x) * ry - (pc.y - pa.y) * rx) / denominator
        guard t > 1e-6, t < 1 - 1e-6, u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        return t
    }

    /// 等しい長さ・平行の印・辺の文字を置く位置(線分の a から b へのどこか)。線分の上の点と、ほかの線と交わる所から、
    /// なるべく離れた所。
    func markPosition(of segment: Segment) -> Double {
        guard let a = point(segment.from), let b = point(segment.to) else { return 0.5 }
        let diagonal = bounds.map { hypot($0.width, $0.height) } ?? 1
        var onSegment = points.compactMap { parameter(of: $0, onSegmentFrom: a, to: b, tolerance: diagonal * 0.01) } + [0, 1]
        for other in segments where other != segment {
            guard let c = point(other.from), let d = point(other.to), let t = crossing(a, b, c, d) else { continue }
            onSegment.append(t)
        }
        let candidates: [Double] = [0.5, 0.42, 0.58, 0.35, 0.65, 0.28, 0.72]
        return candidates.max { lhs, rhs in
            let l = onSegment.map { abs($0 - lhs) }.min() ?? 1, r = onSegment.map { abs($0 - rhs) }.min() ?? 1
            // 同じくらい離れていれば、真ん中に近い方(先に並べた方)。
            return l + 0.02 < r
        } ?? 0.5
    }

    /// 目盛りの間隔(1・2・5 の 10 のべき倍で、8 本前後)。
    static func tickStep(_ span: Double) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / 8
        let power = pow(10, floor(log10(raw)))
        for factor in [1.0, 2, 5, 10] where factor * power >= raw { return factor * power }
        return 10 * power
    }
}
