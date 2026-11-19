import CoreGraphics
import Foundation

/// 図形の問題の図(2026-11-19 のプロトタイプ)。
///
/// 中2「図形の合同」のように、図に書いた角度や点の位置を前提にする問題は、問題文と式だけでは出せなかった。モデルに SVG を
/// 書かせると、点の位置と角の大きさが合っているかをアプリが確かめられない。そこで、モデルには点の座標・線分・角の印を
/// データで返させ、アプリが描く。受け取る前に、印を付けた角の大きさが座標から計算した大きさと合うかを確かめる
/// (合わない図は、生徒が図を見て解いた答えと正しい答えが食い違うので受け取らない)。
///
/// 座標は数学と同じ向き(y が上)。単位は自由で、アプリが画面の幅に合わせて縮める。
nonisolated struct TimelineFigure: Equatable, Sendable {
    nonisolated struct Point: Equatable, Sendable {
        var name: String
        var x: Double
        var y: Double
    }

    nonisolated struct Segment: Equatable, Sendable {
        var from: String
        var to: String
        /// 補助線などの点線。
        var dashed: Bool
        /// 等しい長さの印(辺の真ん中の短い線の本数)。0 なら無し。
        var ticks: Int
        /// 平行の印(矢じりの数)。0 なら無し。
        var arrows: Int
    }

    nonisolated struct Angle: Equatable, Sendable {
        /// 角の頂点と、角を挟む 2 つの点(∠from-vertex-to)。
        var vertex: String
        var from: String
        var to: String
        /// 角に添える文字(「61°」「x」「?」)。空なら弧だけ。
        var label: String
        /// 等しい角の印(弧の本数)。
        var arcs: Int
        /// 直角の印(四角)。
        var right: Bool
    }

    nonisolated struct Circle: Equatable, Sendable {
        var center: String
        var radius: Double
    }

    var points: [Point]
    var segments: [Segment]
    var angles: [Angle]
    var circles: [Circle]

    /// 印を付けた角の大きさと、座標から計算した大きさのずれの許し(度)。
    static let angleTolerance: Double = 4

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
        let points: [Point] = (object["points"]?.arrayValue ?? []).compactMap { row in
            guard let x = row["x"]?.doubleValue, let y = row["y"]?.doubleValue else { return nil }
            return Point(name: string(row["name"]), x: x, y: y)
        }
        guard !points.isEmpty else { return nil }
        self.points = points
        segments = (object["segments"]?.arrayValue ?? []).map { row in
            Segment(from: string(row["from"]), to: string(row["to"]), dashed: row["dashed"]?.boolValue ?? false,
                    ticks: max(0, min(3, row["ticks"]?.intValue ?? 0)), arrows: max(0, min(3, row["arrows"]?.intValue ?? 0)))
        }
        angles = (object["angles"]?.arrayValue ?? []).map { row in
            Angle(vertex: string(row["vertex"]), from: string(row["from"]), to: string(row["to"]), label: string(row["label"]),
                  arcs: max(0, min(3, row["arcs"]?.intValue ?? 1)), right: row["right"]?.boolValue ?? false)
        }
        circles = (object["circles"]?.arrayValue ?? []).compactMap { row in
            guard let radius = row["radius"]?.doubleValue else { return nil }
            return Circle(center: string(row["center"]), radius: radius)
        }
    }

    func point(_ name: String) -> Point? { points.first { $0.name == name } }

    // MARK: 受け取る前の点検

    /// 図の欠け(受け取りを断る理由)。空なら受け取ってよい。
    var defects: [String] {
        var defects: [String] = []
        let names = points.map(\.name)
        if names.contains(where: \.isEmpty) { defects.append("figure: a point has no name") }
        let duplicated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        if !duplicated.isEmpty { defects.append("figure: duplicated point names " + duplicated.sorted().joined(separator: ", ")) }
        if points.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) { defects.append("figure: a coordinate is not a number") }
        guard let bounds = bounds, bounds.width > 0, bounds.height > 0 else {
            defects.append("figure: the points lie on one line or one point")
            return defects
        }
        // 重なった点は名前の文字が重なって読めない。
        let diagonal = hypot(bounds.width, bounds.height)
        for (i, a) in points.enumerated() {
            for b in points[(i + 1)...] where hypot(a.x - b.x, a.y - b.y) < diagonal * 0.02 {
                defects.append("figure: points \(a.name) and \(b.name) overlap")
            }
        }
        for segment in segments {
            let missing = [segment.from, segment.to].filter { point($0) == nil }
            if !missing.isEmpty { defects.append("figure: segment \(segment.from)\(segment.to) uses unknown points " + missing.joined(separator: ", ")) }
            else if segment.from == segment.to { defects.append("figure: segment \(segment.from)\(segment.to) has no length") }
        }
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
        for circle in circles {
            if point(circle.center) == nil { defects.append("figure: circle center \(circle.center) is unknown") }
            if !(circle.radius > 0) { defects.append("figure: circle around \(circle.center) has no radius") }
        }
        return defects
    }

    /// 座標から計算した ∠from-vertex-to の大きさ(0〜180 度)。
    func degrees(of angle: Angle) -> Double? {
        guard let v = point(angle.vertex), let a = point(angle.from), let b = point(angle.to) else { return nil }
        let ax = a.x - v.x, ay = a.y - v.y, bx = b.x - v.x, by = b.y - v.y
        let la = hypot(ax, ay), lb = hypot(bx, by)
        guard la > 0, lb > 0 else { return nil }
        let cosine = max(-1, min(1, (ax * bx + ay * by) / (la * lb)))
        return acos(cosine) * 180 / .pi
    }

    /// 角の文字が度数(「61°」「$61^\circ$」「61」)なら、その数。文字(「x」「?」)なら nil。
    static func labeledDegrees(_ label: String) -> Double? {
        var text = label
        for token in ["$", "^\\circ", "^{\\circ}", "\\circ", "°", "度", " "] { text = text.replacingOccurrences(of: token, with: "") }
        return Double(text)
    }

    /// 画面に出す角・点の文字(LaTeX の度の記号を ° にし、`$` を外す)。
    static func displayLabel(_ label: String) -> String {
        var text = label
        for (token, replacement) in [("^{\\circ}", "°"), ("^\\circ", "°"), ("\\circ", "°"), ("$", "")] { text = text.replacingOccurrences(of: token, with: replacement) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 問題文が図を前提にしているか(「右の図で」「図の」)。「図形」は図を指さないので数えない。
    static func mentionsFigure(_ text: String) -> Bool {
        text.range(of: #"図(?!形)"#, options: .regularExpression) != nil
    }

    // MARK: 描く位置

    /// 点と円が入る範囲(図の単位)。
    var bounds: CGRect? {
        var rect: CGRect?
        func add(_ r: CGRect) { rect = rect.map { $0.union(r) } ?? r }
        for p in points where p.x.isFinite && p.y.isFinite { add(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        for c in circles {
            guard let center = point(c.center), c.radius > 0 else { continue }
            add(CGRect(x: center.x - c.radius, y: center.y - c.radius, width: c.radius * 2, height: c.radius * 2))
        }
        return rect
    }

    /// 横 ÷ 縦(画面の枠の形を決める)。細長すぎる図は、枠が極端にならないように抑える。
    var aspectRatio: CGFloat {
        guard let b = bounds, b.width > 0, b.height > 0 else { return 1.6 }
        return max(1.0, min(2.4, b.width / b.height))
    }

    /// 図の単位から画面の座標へ。`inset` は文字の分の余白。y は下向きに返す。
    func transform(in size: CGSize, inset: CGFloat) -> (Point) -> CGPoint {
        guard let b = bounds, b.width > 0 || b.height > 0 else { return { _ in CGPoint(x: size.width / 2, y: size.height / 2) } }
        let usableW = max(1, size.width - inset * 2), usableH = max(1, size.height - inset * 2)
        let scale = min(b.width > 0 ? usableW / b.width : .infinity, b.height > 0 ? usableH / b.height : .infinity)
        let offsetX = (size.width - b.width * scale) / 2, offsetY = (size.height - b.height * scale) / 2
        return { p in CGPoint(x: offsetX + (p.x - b.minX) * scale, y: offsetY + (b.maxY - p.y) * scale) }
    }

    /// 点の名前を置く向き(単位ベクトル、画面の座標)。つながっている線の反対側、線が無ければ図の中心の反対側。
    func labelDirection(of p: Point) -> CGVector {
        var dx = 0.0, dy = 0.0
        for s in segments {
            let other: String? = s.from == p.name ? s.to : (s.to == p.name ? s.from : nil)
            guard let other, let q = point(other) else { continue }
            let l = hypot(q.x - p.x, q.y - p.y)
            guard l > 0 else { continue }
            dx += (q.x - p.x) / l
            dy += (q.y - p.y) / l
        }
        // 線の真ん中を通る点(交点)は、向きが打ち消し合う。その時は図の中心の反対側に置く。
        if hypot(dx, dy) < 0.3 {
            let cx = points.map(\.x).reduce(0, +) / Double(points.count), cy = points.map(\.y).reduce(0, +) / Double(points.count)
            dx = cx - p.x
            dy = cy - p.y
            // 交点が中心にある時は、交わる線の間の空いている向き(線の向きと 90° ずれた向き)にする。
            if hypot(dx, dy) < 1e-9, let s = segments.first(where: { $0.from == p.name || $0.to == p.name }),
               let a = point(s.from), let b = point(s.to) {
                dx = -(b.y - a.y)
                dy = b.x - a.x
            }
        }
        let l = hypot(dx, dy)
        guard l > 0 else { return CGVector(dx: 0, dy: -1) }
        // 図の単位(y 上向き)の「向こう側」を、画面の座標(y 下向き)に直す。
        return CGVector(dx: -dx / l, dy: dy / l)
    }
}
