import SwiftUI

// 배선도 ("B"): 맥락은 카드 가장자리의 핀에서 나와 받는 카드의 핀으로, 직각으로 꺾이는 선을 따라 간다.
// 방향은 선 위 꺾쇠(›)가 줄곧 가리키고, 전달 상태는 선의 색·점선과 받는 핀(채움 = 받음)이 보여 준다.
//   회색 실선 = 받음 · 노란 실선 = 다음 메시지 때 들어감 · 노란 점선(흐름) = 요약 중
//   회색 점선 = 요약 예약·대화 진행 중 · 빨간 점선 = 실패·갱신 안 됨 · 성긴 점 = 요약 없음

/// 카드의 어느 면에 핀이 붙는지
enum Side: String {
    case left, right, top, bottom

    var vector: CGVector {
        switch self {
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        case .top: return CGVector(dx: 0, dy: -1)
        case .bottom: return CGVector(dx: 0, dy: 1)
        }
    }
    var horizontal: Bool { self == .left || self == .right }
}

/// 연결 하나의 경로: 꺾이는 점들 (처음 = 보내는 핀, 끝 = 받는 핀)
struct Route: Equatable {
    let points: [CGPoint]

    static let corner: CGFloat = 10      // 꺾이는 곳 둥글기
    static let stub: CGFloat = 18        // 카드에서 곧게 나오는 길이 (돌아가야 할 때)
    static let spacing: CGFloat = 16     // 같은 면에 핀이 여럿이면 간격

    var start: CGPoint { points[0] }
    var end: CGPoint { points[points.count - 1] }

    /// 모서리를 둥글린 선
    var path: Path {
        var p = Path()
        p.move(to: points[0])
        if points.count > 2 {
            for i in 1..<(points.count - 1) {
                let a = points[i - 1], c = points[i], n = points[i + 1]
                let l1 = hypot(c.x - a.x, c.y - a.y), l2 = hypot(n.x - c.x, n.y - c.y)
                let r = min(Self.corner, l1 / 2, l2 / 2)
                guard r >= 0.5 else { p.addLine(to: c); continue }
                p.addLine(to: CGPoint(x: c.x - (c.x - a.x) / l1 * r, y: c.y - (c.y - a.y) / l1 * r))
                p.addQuadCurve(to: CGPoint(x: c.x + (n.x - c.x) / l2 * r, y: c.y + (n.y - c.y) / l2 * r), control: c)
            }
        }
        p.addLine(to: end)
        return p
    }

    private var segments: [(CGPoint, CGPoint)] { Array(zip(points, points.dropFirst())) }

    /// 점과 선 사이 거리 (엿보기·누르기)
    func distance(to q: CGPoint) -> CGFloat {
        segments.map { Self.distance(q, $0.0, $0.1) }.min() ?? .infinity
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 이름표 자리: 가장 긴 구간의 가운데, 그리고 그 구간 길이 (글이 들어갈 자리)
    var label: (at: CGPoint, room: CGFloat) {
        let s = segments.max { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) < hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } ?? (start, end)
        return (CGPoint(x: ((s.0.x + s.1.x) / 2).rounded(), y: ((s.0.y + s.1.y) / 2).rounded()),
                hypot(s.1.x - s.0.x, s.1.y - s.0.y))
    }

    /// 방향 꺾쇠 자리: 곧은 구간마다 64pt 쯤 간격, 꺾이는 곳·핀·이름표 근처는 비운다
    func chevrons(avoiding tag: CGPoint?, tagHalfWidth: CGFloat = 0) -> [(at: CGPoint, dir: CGVector)] {
        var out: [(CGPoint, CGVector)] = []
        let every: CGFloat = 64, skip: CGFloat = 16
        for (a, b) in segments {
            let l = hypot(b.x - a.x, b.y - a.y)
            guard l >= 2 * skip + 6 else { continue }
            let u = CGVector(dx: (b.x - a.x) / l, dy: (b.y - a.y) / l)
            let n = max(1, Int((l - 2 * skip) / every))
            for k in 0..<n {
                let s = skip + (l - 2 * skip) * (CGFloat(k) + 0.5) / CGFloat(n)
                let p = CGPoint(x: a.x + u.dx * s, y: a.y + u.dy * s)
                if let tag, abs(p.x - tag.x) < tagHalfWidth + 12, abs(p.y - tag.y) < 14 { continue }
                out.append((p, u))
            }
        }
        return out
    }

    /// 꺾쇠들을 한 Path 로 (끝이 at, 방향 dir)
    func chevronPath(avoiding tag: CGPoint?, tagHalfWidth: CGFloat = 0, size s: CGFloat = 3.6) -> Path {
        var p = Path()
        for (c, u) in chevrons(avoiding: tag, tagHalfWidth: tagHalfWidth) {
            let tip = CGPoint(x: c.x + u.dx * s * 0.8, y: c.y + u.dy * s * 0.8)
            let nx = -u.dy, ny = u.dx
            p.move(to: CGPoint(x: tip.x - u.dx * s + nx * s, y: tip.y - u.dy * s + ny * s))
            p.addLine(to: tip)
            p.addLine(to: CGPoint(x: tip.x - u.dx * s - nx * s, y: tip.y - u.dy * s - ny * s))
        }
        return p
    }
}

extension Route {
    /// 두 카드(가운데 a → b) 사이 핀을 붙일 면: 카드 사이가 더 벌어진 쪽으로
    static func sides(_ a: CGPoint, _ b: CGPoint) -> (Side, Side) {
        let dx = b.x - a.x, dy = b.y - a.y
        let gx = abs(dx) - Layout.node.width, gy = abs(dy) - Layout.node.height
        let horizontal: Bool
        if gx >= 24 && (gy < 24 || gx >= gy) { horizontal = true }
        else if gy >= 24 { horizontal = false }
        else { horizontal = abs(dx) / Layout.node.width >= abs(dy) / Layout.node.height }
        if horizontal { return dx >= 0 ? (.right, .left) : (.left, .right) }
        return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
    }

    /// 핀 p0(면 so) → 핀 p3(면 si). 다른 카드 밑으로 지나가지 않는 첫 길:
    /// 가운데에서 한 번 꺾는 길 → 꺾는 자리를 카드 사이로 옮긴 길 → 나가서 카드 바깥의 빈 줄을 따라 돌아 들어오는 길.
    /// (카드 밑을 지나면 엉뚱한 카드에서 나오는 선처럼 보인다)
    static func between(_ p0: CGPoint, _ so: Side, _ p3: CGPoint, _ si: Side, avoiding obstacles: [CGRect] = []) -> Route {
        // 세로 연결은 x·y 를 바꿔 가로 연결처럼 푼다
        let flip = !so.horizontal
        let t = { (p: CGPoint) in flip ? CGPoint(x: p.y, y: p.x) : p }
        let boxes = obstacles.map { r in
            (flip ? CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width) : r).insetBy(dx: -10, dy: -10)
        }
        let s: CGFloat = (so == .right || so == .bottom) ? 1 : -1
        return Route(points: horizontal(t(p0), t(p3), s, boxes).map(t))
    }

    /// 가로로 나가는 핀 a → 가로로 들어오는 핀 b (s = 나가는 방향 +1 오른쪽 / -1 왼쪽)
    private static func horizontal(_ a: CGPoint, _ b: CGPoint, _ s: CGFloat, _ boxes: [CGRect]) -> [CGPoint] {
        func clear(_ pts: [CGPoint]) -> Bool {
            for (p, q) in zip(pts, pts.dropFirst()) {
                let r = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
                    .insetBy(dx: -0.5, dy: -0.5)
                if boxes.contains(where: { $0.intersects(r) }) { return false }
            }
            return true
        }
        var fallback: [CGPoint]?
        if (b.x - a.x) * s >= 2 * stub {
            if abs(b.y - a.y) < 1 {
                let straight = [a, CGPoint(x: b.x, y: a.y)]
                if clear(straight) { return straight }
                fallback = straight
            } else {
                let lo = min(a.x + s * stub, b.x - s * stub), hi = max(a.x + s * stub, b.x - s * stub)
                let mid = ((a.x + b.x) / 2).rounded()
                var xs: [CGFloat] = [mid]
                for r in boxes {
                    xs.append((r.minX - 1).rounded())
                    xs.append((r.maxX + 1).rounded())
                }
                xs = xs.filter { x in x >= lo && x <= hi }
                xs.sort { p, q in abs(p - mid) < abs(q - mid) }
                for x in xs {
                    let pts = [a, CGPoint(x: x, y: a.y), CGPoint(x: x, y: b.y), b]
                    if clear(pts) { return pts }
                }
                fallback = [a, CGPoint(x: mid, y: a.y), CGPoint(x: mid, y: b.y), b]
            }
        }
        // 나가서(stub) 카드 위·아래의 빈 줄을 따라가다 들어온다
        let x1 = a.x + s * stub, x2 = b.x - s * stub
        let ymid = ((a.y + b.y) / 2).rounded()
        func lane(_ y: CGFloat) -> [CGPoint] {
            [a, CGPoint(x: x1, y: a.y), CGPoint(x: x1, y: y), CGPoint(x: x2, y: y), CGPoint(x: x2, y: b.y), b]
        }
        var ys: [CGFloat] = [ymid]
        for r in boxes {
            ys.append((r.minY - 1).rounded())
            ys.append((r.maxY + 1).rounded())
        }
        ys.sort { p, q in abs(p - ymid) < abs(q - ymid) }
        for y in ys where clear(lane(y)) { return lane(y) }
        return fallback ?? lane(ymid)
    }

    /// 그릴 연결 전부의 경로 (Link.id → Route). 같은 면에 핀이 여럿 붙으면 맞은편 순서대로 나란히 놓는다.
    /// cards = 판 위의 카드·흐린 카드 (선이 그 밑으로 지나가지 않게 피한다)
    static func layout(_ links: [Link], at pos: (String) -> CGPoint?, cards: [String] = []) -> [String: Route] {
        var frames: [String: CGRect] = [:]
        for id in cards { if let c = pos(id) { frames[id] = Layout.frame(at: c) } }
        struct Attach { let link: String; let out: Bool; let other: CGPoint }
        var ends: [String: (so: Side, si: Side)] = [:]
        var groups: [String: (center: CGPoint, side: Side, list: [Attach])] = [:]
        for l in links {
            guard let a = pos(l.src), let b = pos(l.dst) else { continue }
            let (so, si) = sides(a, b)
            ends[l.id] = (so, si)
            groups["\(l.src)|\(so.rawValue)", default: (a, so, [])].list.append(Attach(link: l.id, out: true, other: b))
            groups["\(l.dst)|\(si.rawValue)", default: (b, si, [])].list.append(Attach(link: l.id, out: false, other: a))
        }
        var p0: [String: CGPoint] = [:], p3: [String: CGPoint] = [:]
        let w = Layout.node.width / 2, h = Layout.node.height / 2
        for (_, g) in groups {
            let list = g.list.sorted { x, y in
                let kx = g.side.horizontal ? x.other.y : x.other.x, ky = g.side.horizontal ? y.other.y : y.other.x
                return kx != ky ? kx < ky : (x.link, x.out ? 0 : 1) < (y.link, y.out ? 0 : 1)
            }
            let n = list.count
            let span = (g.side.horizontal ? Layout.node.height : Layout.node.width) - 20
            let gap = n > 1 ? min(spacing, span / CGFloat(n - 1)) : 0
            for (k, at) in list.enumerated() {
                let off = (CGFloat(k) - CGFloat(n - 1) / 2) * gap
                let v = g.side.vector
                let p = g.side.horizontal
                    ? CGPoint(x: g.center.x + v.dx * w, y: (g.center.y + off).rounded())
                    : CGPoint(x: (g.center.x + off).rounded(), y: g.center.y + v.dy * h)
                if at.out { p0[at.link] = p } else { p3[at.link] = p }
            }
        }
        // 거의 일직선(24pt 안쪽으로 어긋남)인데 한쪽 면에 핀이 하나뿐이면, 그 핀을 옮겨 곧은 선으로 (작은 S 자 꺾임 없애기)
        var count: [String: Int] = [:]
        for l in links { if let e = ends[l.id] { count["\(l.src)|\(e.so.rawValue)"] = groups["\(l.src)|\(e.so.rawValue)"]?.list.count; count["\(l.dst)|\(e.si.rawValue)"] = groups["\(l.dst)|\(e.si.rawValue)"]?.list.count } }
        var out: [String: Route] = [:]
        for l in links {
            guard let e = ends[l.id], var a = p0[l.id], var b = p3[l.id] else { continue }
            let off = e.so.horizontal ? b.y - a.y : b.x - a.x
            if off != 0, abs(off) < 24 {
                let span = (e.so.horizontal ? Layout.node.height : Layout.node.width) / 2 - 10
                if count["\(l.src)|\(e.so.rawValue)"] == 1, let c = pos(l.src) {
                    if e.so.horizontal { a.y = min(max(b.y, c.y - span), c.y + span) } else { a.x = min(max(b.x, c.x - span), c.x + span) }
                } else if count["\(l.dst)|\(e.si.rawValue)"] == 1, let c = pos(l.dst) {
                    if e.si.horizontal { b.y = min(max(a.y, c.y - span), c.y + span) } else { b.x = min(max(a.x, c.x - span), c.x + span) }
                }
            }
            out[l.id] = between(a, e.so, b, e.si, avoiding: frames.filter { $0.key != l.src && $0.key != l.dst }.map(\.value))
        }
        return out
    }
}

/// 선 모양 (전달 상태마다)
enum Trace {
    struct Style {
        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
        let moving: Bool
    }

    static func style(_ f: Flow?) -> Style {
        switch f?.stage {
        case .ready?: return Style(color: Ink.flow, width: 2, dash: [], moving: false)
        case .summarizing?: return Style(color: Ink.flow, width: 1.5, dash: [4, 4], moving: true)
        case .scheduled?, .sourceActive?: return Style(color: Ink.pipe, width: 1.5, dash: [2, 4], moving: false)
        case .failed?, .stale?: return Style(color: Ink.fail, width: 1.5, dash: [3, 3], moving: false)
        case .noSummary?: return Style(color: Ink.pipe, width: 1.5, dash: [1, 4], moving: false)
        case .delivered?, nil: return Style(color: Ink.pipe, width: 1.5, dash: [], moving: false)
        }
    }

    /// 이름표 글자 색
    static func tagColor(_ f: Flow) -> Color {
        switch f.stage {
        case .ready, .summarizing: return Ink.flowText
        case .failed, .stale: return Ink.fail
        default: return Ink.meta
        }
    }
}

/// 연결 하나의 선 (카드 아래). 핀·이름표는 FlowMarks 가 카드 위에 그린다.
struct LinkView: View {
    let route: Route
    let selected: Bool
    let flow: Flow?
    var link: Link? = nil
    var arrival: FlowStatus.Arrival? = nil
    @ObservedObject private var hover = EdgeHover.shared

    var body: some View {
        Group {
            if let a = arrival, !Motion.reduced {
                TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
                    lines(phase: 0, sweep: ctx.date.timeIntervalSince1970 - a.at)
                }
            } else if Trace.style(flow).moving && !Motion.reduced {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    lines(phase: CGFloat((ctx.date.timeIntervalSince1970 * 20).truncatingRemainder(dividingBy: 8)))
                }
            } else {
                lines(phase: 0)
            }
        }
        .contentShape(route.path.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)))
        // 마우스 올림(엿보기)은 선마다 받지 않고 EdgePeek 이 판 전체에서 가장 가까운 선을 찾는다
    }

    private func lines(phase: CGFloat, sweep: Double? = nil) -> some View {
        let st = Trace.style(flow)
        let hovered = link != nil && hover.id == link?.id
        let path = route.path
        let tag = flow.map { !$0.done } == true ? route.label : nil
        // 물결: 선 길이의 22% 짜리 밝은 줄기가 보내는 핀에서 받는 핀까지 (부드럽게 빨라졌다 느려짐)
        let k = sweep.map { min(max($0 / FlowStatus.sweep, 0), 1) }
        let e = k.map { $0 < 0.5 ? 2 * $0 * $0 : 1 - pow(-2 * $0 + 2, 2) / 2 }
        return ZStack {
            if selected {
                path.stroke(Ink.title.opacity(0.16), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            path.stroke(st.color, style: StrokeStyle(lineWidth: st.width + (hovered ? 1 : 0), lineCap: .butt,
                                                     lineJoin: .round, dash: st.dash, dashPhase: -phase))
            route.chevronPath(avoiding: tag?.at, tagHalfWidth: 40)
                .stroke(st.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .square, lineJoin: .miter))
            if let k, let e, k < 1 {
                path.trimmedPath(from: max(0, e - 0.22), to: e)
                    .stroke(Ink.flowBright, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// 선 끝의 핀 (네모): 보내는 핀은 늘 채움, 받는 핀은 받았으면 채움·아니면 빈 네모
struct Pin: View {
    let filled: Bool
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(filled ? color : Ink.basin)
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous).strokeBorder(color, lineWidth: filled ? 0 : 1.5))
            .frame(width: 8, height: 8)
            .background(RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Ink.basin).frame(width: 12, height: 12))
    }
}

/// 선 위의 표시들 (카드 위에 그림): 양끝 핀과, 밀렸을 때만 이름표. 다 받았으면 채워진 핀뿐 — 잘 되고 있으면 조용하게.
struct FlowMarks: View {
    let route: Route
    let flow: Flow
    let help: String
    var arrival: FlowStatus.Arrival? = nil   // 방금 맥락이 들어갔으면

    var body: some View {
        if let a = arrival, !Motion.reduced {
            TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in marks(ctx.date.timeIntervalSince1970, arrival: a) }
        } else if flow.stage == .scheduled {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in marks(ctx.date.timeIntervalSince1970) }
        } else {
            marks(Date().timeIntervalSince1970)
        }
    }

    /// 판 전체를 덮는 투명한 층 안에 핀·글을 제자리에 놓는다 (TimelineView 안에서도 같은 좌표가 되게)
    private func marks(_ now: Double, arrival: FlowStatus.Arrival? = nil) -> some View {
        ZStack(alignment: .topLeading) { content(now, arrival: arrival) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(_ now: Double, arrival: FlowStatus.Arrival? = nil) -> some View {
        let st = Trace.style(flow)
        // 방금 들어간 맥락: 물결이 받는 핀에 닿는 순간(sweep)부터 핀이 채워진다
        let since = arrival.map { now - $0.at - FlowStatus.sweep }
        Pin(filled: true, color: st.color).position(route.start).allowsHitTesting(false)
        if let since, since >= 0, since < 0.9 * FlowStatus.slow {
            let k = since / (0.9 * FlowStatus.slow), grow = 12 + 40 * (1 - (1 - k) * (1 - k))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Ink.flow.opacity(0.85 * (1 - k)), lineWidth: 2)
                .frame(width: grow, height: grow)
                .position(route.end)
                .allowsHitTesting(false)
        }
        Pin(filled: since.map { $0 >= 0 } ?? flow.done, color: since != nil ? Ink.flow : st.color)
            .scaleEffect(since.map { s in
                let d = 0.25 * FlowStatus.slow
                return s >= 0 && s < d ? 1 + 0.35 * sin(.pi * s / d) : 1
            } ?? 1)
            .position(route.end)
            .allowsHitTesting(false)
        if !flow.done {
            let label = route.label
            let full = flow.stageText(now: now, short: true)
            let color = Trace.tagColor(flow)
            Text(Flow.badgeWidth(full) * 1.05 <= label.room - 24 ? full : flow.tiny(now: now))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Ink.basin))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
                .fixedSize()
                .help(help)
                .position(label.at)
        }
    }
}

/// 배선도 격자: 24pt 가는 선, 120pt 마다 조금 진한 선. 화면 좌표로 그리고 그래프 판 안쪽에만.
struct BlueprintGrid: View {
    let zoom: CGFloat
    let pan: CGPoint
    let world: CGRect          // 그래프 좌표의 판

    var body: some View {
        Canvas { ctx, size in
            var step: CGFloat = 24
            while step * zoom < 12 { step *= 2 }          // 많이 줄이면 선을 듬성듬성
            let major = step * 5
            let box = CGRect(x: pan.x + world.minX * zoom, y: pan.y + world.minY * zoom,
                             width: world.width * zoom, height: world.height * zoom)
            let area = box.intersection(CGRect(origin: .zero, size: size))
            guard !area.isNull, !area.isEmpty else { return }
            // 격자는 그래프 좌표에 붙어 있어야 끌 때 같이 움직인다 (그래프 좌표 0 이 선 하나)
            var minor = Path(), heavy = Path()
            let x0 = ((area.minX - pan.x) / zoom / step).rounded(.up) * step
            var gx = x0
            while pan.x + gx * zoom < area.maxX {
                let x = (pan.x + gx * zoom).rounded() + 0.5
                let isMajor = abs(gx.truncatingRemainder(dividingBy: major)) < 0.5
                var p = isMajor ? heavy : minor
                p.move(to: CGPoint(x: x, y: area.minY)); p.addLine(to: CGPoint(x: x, y: area.maxY))
                if isMajor { heavy = p } else { minor = p }
                gx += step
            }
            let y0 = ((area.minY - pan.y) / zoom / step).rounded(.up) * step
            var gy = y0
            while pan.y + gy * zoom < area.maxY {
                let y = (pan.y + gy * zoom).rounded() + 0.5
                let isMajor = abs(gy.truncatingRemainder(dividingBy: major)) < 0.5
                var p = isMajor ? heavy : minor
                p.move(to: CGPoint(x: area.minX, y: y)); p.addLine(to: CGPoint(x: area.maxX, y: y))
                if isMajor { heavy = p } else { minor = p }
                gy += step
            }
            ctx.stroke(minor, with: .color(Ink.gridMinor), lineWidth: 1)
            ctx.stroke(heavy, with: .color(Ink.gridMajor), lineWidth: 1)
        }
    }
}
