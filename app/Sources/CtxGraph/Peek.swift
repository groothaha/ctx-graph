import AppKit
import SwiftUI

/// 마우스가 올라가 있는 화살표 (그 선만 굵게). 자주 바뀌지 않는 값만 둔다 — 선들이 이것만 본다.
@MainActor
final class EdgeHover: ObservableObject {
    static let shared = EdgeHover()
    @Published var id: String?
}

/// 화살표 엿보기: 선에 0.25초 머물면 그 선으로 다음에 흘러갈 내용(또는 마지막으로 들어간 것)을 띄운다.
/// 마우스가 움직일 때마다 그래프 칸 안에서 가장 가까운 선을 직접 찾는다 (선 뷰들은 판 전체를 덮고 겹쳐 있어서
/// SwiftUI 호버로는 맨 위 선 하나만 신호를 받는다). 마우스 위치는 여기에만 두고 그래프는 다시 그리지 않는다.
@MainActor
final class EdgePeek: ObservableObject {
    static let shared = EdgePeek()
    static let delay: UInt64 = 250_000_000

    struct Shown: Equatable {
        let link: Link
        let anchor: CGPoint          // "canvas" 좌표 (그래프 판 안, 확대 전)
    }
    @Published private(set) var shown: Shown?
    private var pending: Task<Void, Never>?
    private var last: CGPoint = .zero
    private var monitor: Any?
    private var resign: NSObjectProtocol?

    /// 그래프 칸이 나타날 때: 마우스 이동을 받기 시작 (창은 기본으로 이동 이벤트를 받지 않는다)
    func start() {
        DispatchQueue.main.async {
            for w in NSApp.windows where w.title == "CtxGraph" { w.acceptsMouseMovedEvents = true }
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                                              .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] ev in
            MainActor.assumeIsolated { self?.handle(ev) }
            return ev
        }
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfOpen() }
        }
    }

    func handle(_ ev: NSEvent) {
        if ev.type == .mouseMoved {
            guard let w = ev.window, w.title == "CtxGraph", let cv = w.contentView else { hideIfOpen(); return }
            let pc = cv.convert(ev.locationInWindow, from: nil)
            pointerMoved(CGPoint(x: pc.x, y: cv.isFlipped ? pc.y : cv.bounds.height - pc.y))
        } else {
            hideIfOpen()            // 클릭·스크롤·키 입력이면 닫는다 (선을 클릭하면 인스펙터가 열림)
        }
    }

    /// 마우스 위치(창 내용 좌표, 왼쪽 위 기준) → 그래프 칸 안에서 7pt 안의 가장 가까운 선
    func pointerMoved(_ q: CGPoint) {
        let vp = CanvasViewport.shared
        guard let store = vp.store, vp.frameInWindow.contains(q) else { hideIfOpen(); return }
        let g = vp.toWorld(CGPoint(x: q.x - vp.frameInWindow.minX, y: q.y - vp.frameInWindow.minY))
        var best: (link: Link, dist: CGFloat)?
        if store.nodeID(at: g) == nil, store.ghostID(at: g) == nil {     // 카드 위면 선이 아니라 카드
            let routes = Route.layout(store.visibleLinks + store.ghostLinks, at: { store.position($0)?.snapped },
                                      cards: store.nodes.map(\.id) + store.ghosts.map(\.id))
            for l in store.visibleLinks + store.ghostLinks {
                guard let r = routes[l.id] else { continue }
                let dist = r.distance(to: g) * vp.zoom          // 화면 pt
                if dist <= 7, dist < (best?.dist ?? .infinity) { best = (l, dist) }
            }
        }
        if let b = best {
            let o = store.worldRect.origin
            hovering(b.link, at: CGPoint(x: g.x - o.x, y: g.y - o.y))
        } else {
            hideIfOpen()
        }
    }

    private func hovering(_ l: Link, at p: CGPoint) {
        last = p
        if EdgeHover.shared.id != l.id {
            EdgeHover.shared.id = l.id
            pending?.cancel()
            pending = nil
            if shown != nil { shown = nil }
        }
        guard shown == nil, pending == nil else { return }       // 이미 떠 있으면 자리는 그대로
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            guard EdgeHover.shared.id == l.id else { return }
            self.shown = Shown(link: l, anchor: self.last)
        }
    }

    private func hideIfOpen() {
        if pending != nil || shown != nil || EdgeHover.shared.id != nil { hide() }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        if EdgeHover.shared.id != nil { EdgeHover.shared.id = nil }
        if shown != nil { shown = nil }
    }

    /// 화면 점검용 (마우스 없이)
    func show(_ l: Link, at p: CGPoint) {
        pending?.cancel()
        pending = nil
        EdgeHover.shared.id = l.id
        shown = Shown(link: l, anchor: p)
    }
}

/// 엿보기 카드를 화면 좌표에 놓는 층. 카드는 확대와 상관없이 같은 크기, 이어진 두 카드는 되도록 가리지 않는다.
struct PeekLayer: View {
    @EnvironmentObject var store: GraphStore
    @ObservedObject private var peek = EdgePeek.shared
    @ObservedObject private var vp = CanvasViewport.shared
    @ObservedObject private var fs = FlowStatus.shared
    let size: CGSize
    let origin: CGPoint                  // 그래프 판 왼쪽 위의 그래프 좌표 (worldRect.origin)
    @State private var height: CGFloat = 150

    private static let width: CGFloat = 320

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let s = peek.shown, let info = PeekInfo(s.link, store: store, fs: fs) {
                let at = vp.toScreen(CGPoint(x: s.anchor.x + origin.x, y: s.anchor.y + origin.y))
                let spot = place(at: at, link: s.link)
                PeekCard(info: info)
                    .background(GeometryReader { g in Color.clear.preference(key: PeekHeight.self, value: g.size.height) })
                    .offset(x: spot.x, y: spot.y)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(Motion.reduced ? nil : .easeOut(duration: 0.12), value: peek.shown)
        .onPreferenceChange(PeekHeight.self) { if abs($0 - height) > 0.5 { height = $0 } }
        // 화면을 옮기거나 확대하면 닫는다 (커서가 선에서 벗어난다)
        .onChange(of: vp.zoom) { peek.hide() }
        .onChange(of: vp.pan) { peek.hide() }
        .onChange(of: store.space) { peek.hide() }
    }

    /// 커서 둘레 여섯 자리 중 카드를 가장 덜 가리는 곳. 이 선의 두 카드는 열 배로 피하고, 커서는 덮지 않는다.
    private func place(at p: CGPoint, link: Link) -> CGPoint {
        let w = Self.width, h = height, g: CGFloat = 16, m: CGFloat = 8
        let fit = { (x: CGFloat, y: CGFloat) in
            CGPoint(x: min(max(m, x), max(m, size.width - w - m)), y: min(max(m, y), max(m, size.height - h - m)))
        }
        let spots = [fit(p.x + g, p.y + g), fit(p.x + g, p.y - h - g), fit(p.x - w - g, p.y + g),
                     fit(p.x - w - g, p.y - h - g), fit(p.x - w / 2, p.y + g), fit(p.x - w / 2, p.y - h - g)]
        let cards: [(CGRect, Bool)] = store.nodes.map { n in
            let o = vp.toScreen(CGPoint(x: n.frame.minX, y: n.frame.minY))
            let r = CGRect(x: o.x, y: o.y, width: n.frame.width * vp.zoom, height: n.frame.height * vp.zoom).insetBy(dx: -6, dy: -6)
            return (r, n.id == link.src || n.id == link.dst)
        }
        func cost(_ s: CGPoint) -> CGFloat {
            let box = CGRect(x: s.x, y: s.y, width: w, height: h)
            var c: CGFloat = cards.reduce(0) { sum, card in
                let i = box.intersection(card.0)
                return i.isNull ? sum : sum + i.width * i.height * (card.1 ? 10 : 1)
            }
            if box.insetBy(dx: -6, dy: -6).contains(p) { c += 1e9 }
            return c
        }
        return spots.min { cost($0) < cost($1) } ?? spots[0]
    }
}

private struct PeekHeight: PreferenceKey {
    static var defaultValue: CGFloat = 150
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 엿보기 카드에 쓸 내용 (ctxgraph.py 의 plan_injection 과 같은 규칙으로, 앱에서 바로 계산)
struct PeekInfo {
    let from: String
    let to: String
    let state: String
    let quiet: Bool                  // 새로 갈 게 없음 → 흐린 글
    let lines: [String]
    let foot: String

    @MainActor
    init?(_ l: Link, store: GraphStore, fs: FlowStatus) {
        guard let src = store.node(l.src), let f = store.flow(l, fs) else { return nil }
        from = Fmt.oneLine(store.title(l.src), 24)
        to = Fmt.oneLine(store.title(l.dst), 24)
        let now = Date().timeIntervalSince1970
        let v = src.version
        let got = fs.received[l.id]
        if v == 0 {
            state = f.stageText(now: now)
            quiet = true
            lines = []
            foot = String(localized: "요약이 생기면 다음 메시지부터 들어가요")
        } else if got?.version != v {
            // 다음 메시지에 들어갈 것: 한 버전 차이면 바뀐 부분만, 아니면 전체
            if let r = got, r.version == v - 1, let d = src.delta, !d.isEmpty {
                state = String(localized: "다음 메시지에 들어가요 · 바뀐 부분만 (v\(v - 1) → v\(v))")
                lines = Self.firstLines(d)
            } else {
                state = String(localized: "다음 메시지에 들어가요 · 전체 요약 (v\(v))")
                lines = Self.firstLines(src.summary ?? "")
            }
            quiet = false
            foot = String(localized: "요약 v\(v) · \(Fmt.ago(src.srcAt ?? src.summaryAt)) 대화까지")
        } else {
            state = f.done ? String(localized: "✓ 최신 내용까지 전달됨 (v\(v))")
                           : String(localized: "받은 v\(v) · \(f.stageText(now: now, short: true))")
            quiet = true
            lines = Self.firstLines(src.summary ?? "")
            foot = String(localized: "\(Fmt.ago(got?.at)) 들어감")
        }
    }

    /// 요약의 앞 세 줄 (제목줄·빈 줄 빼고, 목록 기호 떼고)
    static func firstLines(_ text: String, _ n: Int = 3) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<") }
            .prefix(n)
            .map { line in
                var s = Substring(line)
                while let c = s.first, "-*•·0123456789.) ".contains(c) { s = s.dropFirst() }
                return Fmt.oneLine(s.replacingOccurrences(of: "**", with: ""), 90)
            }
            .filter { !$0.isEmpty }
    }
}

struct PeekCard: View {
    let info: PeekInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("«\(info.from)»")
                Text("→").foregroundStyle(Ink.flow)
                Text("«\(info.to)»")
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            Text(info.state)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(info.quiet ? Ink.meta : Ink.flowText)
                .padding(.top, 2)
            if !info.lines.isEmpty {
                rule
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(info.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(info.quiet ? Ink.pipe : Ink.flow).frame(width: 4, height: 4).offset(y: -2)
                            Text(line).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(info.quiet ? Ink.meta : Color.primary)
                .padding(.top, 8)
            }
            rule
            HStack {
                Text(info.foot)
                Spacer(minLength: 8)
                Text("클릭하면 자세히")
            }
            .font(.system(size: 11))
            .foregroundStyle(Ink.meta)
            .lineLimit(1)
            .padding(.top, 7)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.ringHover))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle().fill(Ink.ring).frame(height: 1).padding(.top, 8)
    }
}
