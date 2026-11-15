import SwiftUI

/// 노드 = 대화, 화살표 = 맥락이 흐르는 방향. 노드 오른쪽 위 ⊕ 를 다른 노드로 끌면 그쪽으로 맥락을 보낸다.
struct GraphCanvas: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    @State private var dragOrigin: CGPoint?
    @State private var linking: LinkDrag?
    @State private var rewiring: Rewire?
    @State private var panOrigin: CGPoint?
    @State private var live: LiveDrag?
    @State private var dropTargeted = false
    @ObservedObject private var vp = CanvasViewport.shared
    @ObservedObject private var listDrag = ListDrag.shared
    @ObservedObject private var fs = FlowStatus.shared

    /// 끌고 있는 노드의 지금 자리 (손을 떼기 전까지 저장소에는 안 씀)
    struct LiveDrag: Equatable {
        let id: String
        var point: CGPoint
    }

    /// 화면에 그릴 자리는 정수 pt 로 (소수점 자리에 그리면 1배율 모니터에서 글자가 번진다)
    private func pt(_ n: GraphNode) -> CGPoint { (live?.id == n.id ? live!.point : n.point).snapped }
    /// 그래프 좌표 ↔ 판 안 좌표("canvas" 좌표계, 판 왼쪽 위가 0)
    private func toView(_ p: CGPoint) -> CGPoint {
        let o = store.worldRect.origin
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }
    private func toModel(_ p: CGPoint) -> CGPoint {
        let o = store.worldRect.origin
        return CGPoint(x: p.x + o.x, y: p.y + o.y)
    }
    /// 지금 공간에서 그릴 자리 (끄는 중인 카드, 카드, 흐린 카드 순)
    private func pt(_ id: String) -> CGPoint? {
        if let l = live, l.id == id { return l.point.snapped }
        return store.position(id)?.snapped
    }

    struct LinkDrag {
        let from: String
        var to: CGPoint
        var target: String?
    }

    /// 선택한 화살표의 한쪽 끝을 끌고 있는 중
    struct Rewire {
        enum End { case tail, head }
        let link: Link
        let end: End
        var point: CGPoint
        var target: String?
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 빈 곳: 누르면 선택 해제, 끌면 화면 이동
                // 화면 크기로 못 박는다 (안 그러면 ZStack 이 그래프 판 크기로 늘려서 터미널 칸 위까지 덮는다)
                BlueprintGrid(zoom: vp.zoom, pan: vp.pan, world: store.worldRect)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { store.selection = nil }
                    .gesture(panGesture)
                    .contextMenu { EmptyCanvasMenu() }      // 우클릭한 자리는 CanvasEventView 가 기억

                // 오른쪽 버튼으로 노드에서 끌면 연결 (그냥 오른쪽 클릭은 평소 메뉴), 스크롤·핀치는 확대·축소
                CanvasEventCatcher(
                    nodeAt: { store.nodeID(at: vp.toWorld($0)) },
                    onChanged: { from, p in
                        let w = vp.toWorld(p)
                        linking = LinkDrag(from: from, to: w, target: store.nodeID(at: w, excluding: from))
                    },
                    onEnded: { from, p in
                        if let t = store.nodeID(at: vp.toWorld(p), excluding: from) { store.link(from, t) }
                        linking = nil
                    },
                    onZoom: { f, p in vp.zoom(by: f, at: p) })
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                // 판의 왼쪽 위 = 그래프 좌표 worldRect.origin (음수일 수 있음). 화면 = 그래프 좌표 × zoom + pan
                let wr = store.worldRect
                world
                    .frame(width: wr.width, height: wr.height, alignment: .topLeading)
                    .coordinateSpace(name: "canvas")
                    .scaleEffect(vp.zoom, anchor: .topLeading)
                    .offset(x: (vp.pan.x + wr.minX * vp.zoom).rounded(), y: (vp.pan.y + wr.minY * vp.zoom).rounded())
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { ids, location in
                vp.touched()
                store.addNodes(ids, at: vp.toWorld(location))
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay(alignment: .topLeading) {
                // 대화 목록에서 끌고 오는 중: 놓일 자리에 미리보기
                if let p = listDrag.canvasPoint, let id = listDrag.ids.first {
                    DropPreview(title: store.session(id)?.title ?? store.title(id), count: listDrag.ids.count)
                        .scaleEffect(vp.zoom)
                        .position(p)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if dropTargeted || listDrag.canvasPoint != nil {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.05))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                // 선에 마우스를 올리면 다음에 흘러갈 내용 (확대와 상관없이 같은 크기로)
                PeekLayer(size: geo.size, origin: store.worldRect.origin)
            }
            .overlay(alignment: .bottomLeading) {
                ZoomControls().padding(12)
            }
            .onAppear {
                ListDrag.shared.store = store
                vp.attach(store)
                vp.resize(geo.size)
                vp.frameInWindow = geo.frame(in: .global)
                EdgePeek.shared.start()
            }
            .onChange(of: geo.size) { vp.resize(geo.size) }
            .onChange(of: geo.frame(in: .global)) { vp.frameInWindow = geo.frame(in: .global) }
        }
        .background(Ink.basin)
        .overlay {
            if store.nodes.isEmpty {
                Onboarding(dropping: dropTargeted || listDrag.canvasPoint != nil)
            }
        }
        .overlay(alignment: .top) {
            CanvasNotices(hasNodes: !store.nodes.isEmpty).padding(.top, 12)
        }
        .sheet(item: $vp.addTarget) { t in
            AddConversationSheet(at: t.point)
                .environmentObject(store)
                .environmentObject(terms)
        }
        .onChange(of: store.space) { old, new in vp.spaceChanged(from: old, to: new) }
        .onChange(of: store.nodes.isEmpty) { vp.fitIfNeeded() }
        .onChange(of: store.selection) {
            if case .node(let id) = store.selection { vp.reveal(id) }
        }
    }

    /// 빈 곳을 끌어 화면 이동 (화면 좌표로 — 움직이는 그래프 안 좌표로 재면 떨린다)
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if panOrigin == nil {
                    panOrigin = vp.pan
                    vp.touched()
                    NSCursor.closedHand.push()
                }
                guard let o = panOrigin else { return }
                vp.setPan(CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height))
            }
            .onEnded { _ in
                if panOrigin != nil { NSCursor.pop() }
                panOrigin = nil
            }
    }

    /// 그래프 좌표로 그리는 부분 (통째로 확대·이동)
    private var world: some View {
        // 연결마다 핀에서 핀으로 가는 직각 경로 (판 안 좌표). 끄는 중인 카드도 따라간다.
        let routes = Route.layout(store.visibleLinks + store.ghostLinks, at: { id in pt(id).map(toView) },
                                  cards: store.nodes.map(\.id) + store.ghosts.map(\.id))
        return ZStack(alignment: .topLeading) {
            // 다른 공간에 있는 연결 상대: 흐린 선과 점선 카드 (누르면 그 공간으로)
            ForEach(store.ghostLinks) { l in
                if let r = routes[l.id] {
                    let sel = store.selection == .edge(l.id)
                    LinkView(route: r, selected: sel, flow: store.flow(l, fs), link: l, arrival: fs.arrivals[l.id])
                        .opacity(sel ? 0.85 : 0.5)
                        .onTapGesture {
                            EdgePeek.shared.hide()
                            store.selection = .edge(l.id)
                        }
                        .contextMenu { linkMenu(l) }
                }
            }
            ForEach(store.ghosts) { g in
                GhostCard(title: store.title(g.id), space: g.space)
                    .onTapGesture { EdgePeek.shared.hide(); store.reveal(g.id) }
                    .contextMenu {
                        Button("«\(g.space)» 공간에서 보기") { store.reveal(g.id) }
                        Button("이 공간에도 놓기") {
                            store.alsoShow([g.id], in: store.space, at: g.point)
                            store.selection = .node(g.id)
                        }
                    }
                    .position(toView(g.point))
            }

            ForEach(store.visibleLinks) { l in
                if let r = routes[l.id], rewiring?.link != l {
                    LinkView(route: r, selected: store.selection == .edge(l.id), flow: store.flow(l, fs),
                             link: l, arrival: fs.arrivals[l.id])
                        .onTapGesture {
                            EdgePeek.shared.hide()
                            store.selection = .edge(l.id)
                        }
                        .contextMenu { linkMenu(l) }
                }
            }

            if let l = linking, let a = pt(l.from) {
                PreviewArrow(from: toView(a), to: toView(l.target.flatMap(pt) ?? l.to),
                             snapsFrom: true, snapsTo: l.target != nil)
            }

            if let r = rewiring, let s = pt(r.link.src), let d = pt(r.link.dst) {
                let moving = toView(r.target.flatMap(pt) ?? r.point)
                PreviewArrow(from: r.end == .tail ? moving : toView(s),
                             to: r.end == .head ? moving : toView(d),
                             snapsFrom: r.end == .head || r.target != nil,
                             snapsTo: r.end == .tail || r.target != nil)
            }

            let usual = store.usualCwd
            ForEach(store.nodes) { n in
                nodeView(n, usual: usual).position(toView(pt(n)))
            }

            // 연결마다 양끝 핀과, 밀렸을 때만 이름표 (카드 위에 그려야 핀이 보인다)
            ForEach(store.ghostLinks) { l in
                if let r = routes[l.id], let f = store.flow(l, fs) {
                    FlowMarks(route: r, flow: f, help: "", arrival: fs.arrivals[l.id])
                        .opacity(0.6)
                        .allowsHitTesting(false)
                }
            }
            ForEach(store.visibleLinks) { l in
                if let r = routes[l.id], rewiring?.link != l, let f = store.flow(l, fs) {
                    FlowMarks(route: r, flow: f,
                              help: linkHelp(l) + "\n" + f.stageText(now: Date().timeIntervalSince1970),
                              arrival: fs.arrivals[l.id])
                        .onTapGesture { store.selection = .edge(l.id) }
                }
            }

            // 선택한 연결의 양끝 손잡이 (노드 위에 그려야 잡힌다).
            // 끄는 동안에도 같은 뷰가 남아 있어야 제스처가 끊기지 않으므로, 숨기지 않고 마우스를 따라가게 한다.
            if case .edge(let id) = store.selection,
               let l = store.links.first(where: { $0.id == id }), let g = routes[l.id] {
                let r = rewiring?.link == l ? rewiring : nil
                endHandle(l, .tail, at: r?.end == .tail ? toView(r!.point) : g.start)
                endHandle(l, .head, at: r?.end == .head ? toView(r!.point) : g.end)
            }
        }
    }

    private func linkHelp(_ l: Link) -> String {
        String(localized: "«\(store.title(l.src))» → «\(store.title(l.dst))»: 맥락이 화살표 방향으로 들어가요")
    }

    @ViewBuilder
    private func linkMenu(_ l: Link) -> some View {
        Button("방향 뒤집기") { store.rewire(l, src: l.dst, dst: l.src) }
            .disabled(store.links.contains(l.reversed))
        Button(store.links.contains(l.reversed) ? "반대 방향 끊기 (한쪽만)" : "반대 방향도 추가 (양방향)") {
            store.setLinked(l.dst, l.src, !store.links.contains(l.reversed))
        }
        Divider()
        Button("이 화살표 끊기", role: .destructive) { store.unlink(l.src, l.dst) }
    }

    private func endHandle(_ l: Link, _ end: Rewire.End, at p: CGPoint) -> some View {
        EndpointHandle(isHead: end == .head)
            .position(p)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                    .onChanged { g in
                        let p = toModel(g.location)
                        let fixed = end == .tail ? l.dst : l.src
                        rewiring = Rewire(link: l, end: end, point: p,
                                          target: store.nodeID(at: p, excluding: fixed))
                    }
                    .onEnded { g in
                        let fixed = end == .tail ? l.dst : l.src
                        if let t = store.nodeID(at: toModel(g.location), excluding: fixed) {
                            store.rewire(l, src: end == .tail ? t : l.src, dst: end == .head ? t : l.dst)
                        }
                        rewiring = nil
                    })
            .help(end == .tail ? "꼬리(보내는 쪽): 다른 노드로 끌어 붙이기" : "머리(받는 쪽): 다른 노드로 끌어 붙이기")
    }

    // 제스처는 .position 앞에 붙여야 노드 크기만큼만 반응한다.
    private func nodeView(_ n: GraphNode, usual: String?) -> some View {
        let s = store.session(n.id)
        let cwd = n.cwd ?? s?.cwd
        return NodeCard(
            node: n,
            title: store.title(n.id),
            ago: Fmt.ago(s?.mtime),
            folder: cwd != nil && cwd != usual ? Fmt.shortPath(cwd) : nil,
            live: s?.liveStatus,
            busy: store.isBusy(n.id),
            selected: store.selection == .node(n.id),
            targeted: linking?.target == n.id,
            inTerminal: terms.hasTab(n.id),
            activeTerminal: terms.paneVisible && terms.activeID == n.id,
            scopeNames: store.scope(n.id)?.map(\.title),
            attention: terms.isUnread(n.id),
            incoming: store.sources(n.id).compactMap { src in
                store.flow(Link(src: src, dst: n.id), fs).map { (title: store.title(src), flow: $0) }
            },
            sends: !store.targets(n.id).isEmpty,
            onLinkChanged: { loc in
                let p = toModel(loc)
                linking = LinkDrag(from: n.id, to: p, target: store.nodeID(at: p, excluding: n.id))
            },
            onLinkEnded: { loc in
                if let t = store.nodeID(at: toModel(loc), excluding: n.id) { store.link(n.id, t) }
                linking = nil
            })
            .onTapGesture { store.selection = .node(n.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                store.selection = nil          // 터미널을 열 때는 인스펙터가 그래프를 가리지 않게
                terms.open(n.id)
            })
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        if dragOrigin == nil {
                            dragOrigin = n.point
                            store.draggingID = n.id
                            if store.selection != .node(n.id) { store.selection = .node(n.id) }
                        }
                        guard let o = dragOrigin else { return }
                        // 끄는 동안은 이 화면 안에서만 움직인다. 저장소(nodes)를 매번 바꾸면 사이드바·메뉴까지
                        // 창 전체가 다시 계산돼 끊긴다. 손을 뗄 때 한 번만 저장.
                        live = LiveDrag(id: n.id, point: store.clamp(
                            CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height)))
                    }
                    .onEnded { _ in
                        if let l = live, l.id == n.id {
                            store.move(n.id, to: l.point)
                            store.persistPosition(n.id)
                        }
                        live = nil
                        store.draggingID = nil
                        dragOrigin = nil
                    })
            .contextMenu {
                let others = store.nodes.filter { $0.id != n.id }
                Button("터미널에서 열기") { terms.open(n.id) }
                Button("이름 바꾸기…") { NameActions.rename(store, n.id) }
                Button("오른쪽에 나눠서 열기") { terms.open(n.id, split: true) }
                Menu("다른 모델로 열기") {
                    ModelButtons { terms.open(n.id, model: $0) }
                }
                Menu("이 대화의 맥락을 받는 새 대화") {
                    ModelButtons { terms.openNew(linkTo: n.id, model: $0) }
                }
                Divider()
                // 체크 표시 = 연결됨. 고를 때마다 켜고 끈다 (여러 대화에 연결 가능)
                Menu("맥락 보내기 →") {
                    ForEach(others) { m in
                        Toggle(store.title(m.id), isOn: Binding(
                            get: { store.targets(n.id).contains(m.id) },
                            set: { store.setLinked(n.id, m.id, $0) }))
                    }
                }
                .disabled(others.isEmpty)
                Menu("맥락 받아오기 ←") {
                    ForEach(others) { m in
                        Toggle(store.title(m.id), isOn: Binding(
                            get: { store.sources(n.id).contains(m.id) },
                            set: { store.setLinked(m.id, n.id, $0) }))
                    }
                }
                .disabled(others.isEmpty)
                Button("지금 요약") { store.summarize(n.id, force: true) }
                Button("Terminal 앱에서 이어하기") { store.resumeInTerminal(n.id) }
                Divider()
                MoveToSpaceMenu(title: String(localized: "작업 공간으로 옮기기"), ids: [n.id])
                let group = store.component(n.id)
                if group.count > 1 {
                    MoveToSpaceMenu(title: String(localized: "연결된 \(group.count)개 같이 옮기기"), ids: group)
                }
                AlsoShowMenu(id: n.id)
                Divider()
                Button(store.alsoIn(n.id).isEmpty ? "그래프에서 빼기" : "이 공간에서 빼기", role: .destructive) { store.removeNode(n.id) }
            }
    }
}

/// 노드 카드: 제목이 주인공, 둘째 줄은 흐리게(시간·요약 버전·다른 폴더일 때만 폴더), 셋째 줄은 받는 맥락이 밀렸을 때만.
/// 작업 중이면 주황 고리, 안 읽은 알림은 파란 테두리, 선택은 강조색. ⊕ 는 마우스를 올렸을 때만.
struct NodeCard: View {
    let node: GraphNode
    let title: String
    let ago: String
    let folder: String?                // 그래프의 다른 대화들과 폴더가 다를 때만
    let live: String?                  // "busy" = Claude 가 답하는 중, 그 밖 = 열려 있음, nil = 닫힘
    let busy: Bool                     // 이 대화의 요약을 만드는 중
    let selected: Bool
    let targeted: Bool
    let inTerminal: Bool
    let activeTerminal: Bool
    let scopeNames: [String]?          // nil = 수정 제한 없음
    let attention: Bool                // 이 대화의 터미널 탭에 안 읽은 알림 (파란 테두리)
    var incoming: [(title: String, flow: Flow)] = []   // 받는 맥락마다 전달 상태
    var sends = false                  // 맥락을 보내는 쪽 (그럴 때만 자기 요약 상태가 의미 있음)
    let onLinkChanged: (CGPoint) -> Void
    let onLinkEnded: (CGPoint) -> Void
    @State private var hovering = false

    private var working: Bool { live == "busy" }
    private var showsIncoming: Bool { IncomingStatus.needed(incoming) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Ink.title)
                    .lineLimit(showsIncoming ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 18)
                HStack(spacing: 6) {
                    // 고정폭 글꼴이라 영어("12 min. ago · summary v1 · ~/shop/web")는 넘치기 쉽다: 넘치면 "요약" 을 빼고 v1 만
                    ViewThatFits(in: .horizontal) {
                        meta(compact: false).lineLimit(1)
                        meta(compact: true).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    glyphs
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.meta)
                if showsIncoming { IncomingStatus(items: incoming) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if hovering || selected || targeted {
                LinkHandle(onChanged: onLinkChanged, onEnded: onLinkEnded)
                    .padding(6)
            }
        }
        .frame(width: Layout.node.width, height: Layout.node.height)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering || targeted ? Ink.cardHover : Ink.card))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(borderColor, lineWidth: attention || selected || targeted || working ? 1.5 : 1))
        .shadow(color: attention ? Ink.attention.opacity(0.45) : .clear, radius: attention ? 7 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help(incoming.isEmpty ? "" : incoming.map { String(localized: "«\($0.title)» → 이 대화: ") + $0.flow.stageText(now: Date().timeIntervalSince1970) }
            .joined(separator: "\n"))
    }

    /// 작업 중 · 3분 전 · 요약 v2 · ~/other
    private func meta(compact: Bool) -> Text {
        var parts: [Text] = []
        if working { parts.append((Text(verbatim: "▶ ") + Text("작업 중")).foregroundColor(Ink.flowText)) }
        parts.append(Text(ago))
        if sends {
            if busy { parts.append(Text(node.version > 0 ? "v\(node.version) 갱신 중" : "요약 중").foregroundColor(Ink.flowText)) }
            else if node.summaryError != nil { parts.append(Text(node.version > 0 ? "v\(node.version) 갱신 실패" : "요약 실패").foregroundColor(Ink.fail)) }
            else if node.jobPending { parts.append(Text(node.version > 0 ? "v\(node.version) · 갱신 대기" : "요약 대기")) }
            else if node.version > 0 { parts.append(compact ? Text(verbatim: "v\(node.version)") : Text("요약 v\(node.version)")) }
            else { parts.append(Text("요약 전")) }
        }
        if let folder { parts.append(Text(folder)) }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }

    @ViewBuilder
    private var glyphs: some View {
        if let scopeNames {
            Image(systemName: "folder")
                .foregroundStyle(scopeNames.isEmpty ? Ink.fail : Ink.meta)
                .help(scopeNames.isEmpty ? String(localized: "작업 폴더를 고르지 않았어요") : String(localized: "작업 폴더: ") + scopeNames.joined(separator: ", "))
                .accessibilityLabel("작업 폴더 지정됨")
        }
        if inTerminal {
            Image(systemName: "terminal.fill")
                .foregroundStyle(activeTerminal ? Color.accentColor : Ink.meta)
                .help(activeTerminal ? "오른쪽 터미널에 열려 있음" : "앱 터미널 탭에 열려 있음")
        } else if live != nil {
            Image(systemName: "terminal")
                .help("다른 터미널에서 열려 있음")
        }
    }

    private var borderColor: Color {
        if attention { return Ink.attention }
        if targeted { return .accentColor }
        if selected { return Ink.title.opacity(0.6) }
        if working { return Ink.flow.opacity(0.55) }
        return hovering ? Ink.ringHover : Ink.ring
    }
}

/// 지금 공간에 없는 연결 상대: 점선 테두리의 흐린 카드 (판 바탕 색이라 아래 선을 가린다)
struct GhostCard: View {
    let title: String
    let space: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.meta)
                .lineLimit(1)
            Label { Text(verbatim: "«\(space)»") } icon: { Image(systemName: "arrow.up.forward") }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.meta.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(width: Layout.node.width, height: Layout.node.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.basin))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(hovering ? Ink.meta.opacity(0.7) : Ink.ringHover, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help(String(localized: "«\(space)» 공간에 있는 대화예요. 누르면 그 공간으로 가요 (우클릭: 이 공간에도 놓기)"))
    }
}

struct LinkHandle: View {
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(hovering ? Color.white : Ink.meta)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Color.accentColor : Ink.basin))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(hovering ? Color.accentColor : Ink.ringHover))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { onChanged($0.location) }
                    .onEnded { onEnded($0.location) })
            .help("다른 대화로 끌어서 연결")
            .accessibilityLabel("연결 핸들")
    }
}

struct SummaryStatus: View {
    let node: GraphNode
    let busy: Bool

    var body: some View {
        HStack(spacing: 4) {
            if busy {
                ProgressView().controlSize(.mini)
                Text(node.version > 0 ? "v\(node.version) 갱신 중…" : "요약 중…")
            } else if node.summaryError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.fail)
                Text(node.version > 0 ? "v\(node.version) · 갱신 실패" : "요약 실패")
            } else if node.jobPending {
                Image(systemName: "clock")
                Text(node.version > 0 ? "v\(node.version) · 갱신 대기" : "요약 대기")
            } else if node.version > 0 {
                Image(systemName: "text.alignleft")
                Text("요약 v\(node.version) · \(Fmt.ago(node.summaryAt))")
            } else {
                Image(systemName: "circle.dashed")
                Text("요약 없음")
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// 끌고 있는 동안의 점선 (받는 쪽 끝은 빈 핀)
struct PreviewArrow: View {
    let from: CGPoint
    let to: CGPoint
    let snapsFrom: Bool     // 시작점이 노드면 테두리에서
    let snapsTo: Bool       // 끝점이 노드면 테두리까지

    var body: some View {
        let start = snapsFrom ? Arrow.edgePoint(from: to, to: from, gap: 2) : from
        let tip = snapsTo ? Arrow.edgePoint(from: from, to: to, gap: 0) : to
        ZStack {
            EdgeLine(a: start, b: tip)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
            Pin(filled: false, color: .accentColor).position(tip)
        }
        .allowsHitTesting(false)
    }
}

struct EndpointHandle: View {
    let isHead: Bool
    @State private var hovering = false

    var body: some View {
        Circle()
            .fill(isHead ? Color(nsColor: .windowBackgroundColor) : Color.accentColor)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5))
            .frame(width: hovering ? 16 : 13, height: hovering ? 16 : 13)
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .accessibilityLabel(isHead ? "화살표 머리" : "화살표 꼬리")
    }
}


/// 화살촉. tip 은 대상 노드 테두리 위의 점.
struct Arrow: Shape {
    var tip: CGPoint
    var from: CGPoint
    static let length: CGFloat = 13
    static let halfWidth: CGFloat = 6.5

    func path(in rect: CGRect) -> Path {
        let (ux, uy) = Arrow.unit(from: from, to: tip)
        let base = CGPoint(x: tip.x - ux * Arrow.length, y: tip.y - uy * Arrow.length)
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: base.x - uy * Arrow.halfWidth, y: base.y + ux * Arrow.halfWidth))
        p.addLine(to: CGPoint(x: base.x + uy * Arrow.halfWidth, y: base.y - ux * Arrow.halfWidth))
        p.closeSubpath()
        return p
    }

    static func unit(from: CGPoint, to: CGPoint) -> (CGFloat, CGFloat) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(hypot(dx, dy), 0.001)
        return (dx / len, dy / len)
    }

    /// from 중심에서 to 중심으로 가는 선이 to 노드 테두리와 만나는 점
    static func edgePoint(from: CGPoint, to: CGPoint, gap: CGFloat = 0) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let hw = Layout.node.width / 2 + gap, hh = Layout.node.height / 2 + gap
        let t = min(abs(dx) > 0.001 ? hw / abs(dx) : .infinity, abs(dy) > 0.001 ? hh / abs(dy) : .infinity)
        guard t.isFinite, t < 1 else { return to }
        return CGPoint(x: to.x - dx * t, y: to.y - dy * t)
    }

    static func tip(from: CGPoint, to: CGPoint) -> CGPoint { edgePoint(from: from, to: to, gap: 3) }

    static func base(tip: CGPoint, from: CGPoint) -> CGPoint {
        let (ux, uy) = unit(from: from, to: tip)
        return CGPoint(x: tip.x - ux * (length - 1), y: tip.y - uy * (length - 1))
    }
}


struct EdgeLine: Shape {
    var a: CGPoint
    var b: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        return p
    }
}

/// 오른쪽 버튼 드래그·스크롤·핀치를 잡는 투명한 NSView (화면 좌표 = 그래프 칸 왼쪽 위 기준).
/// SwiftUI 의 DragGesture 는 왼쪽 버튼만 받고, macOS 14 SwiftUI 에는 스크롤 휠 이벤트가 없기 때문.
/// 노드 위에서 오른쪽 버튼을 누르면 일단 붙잡아 두고, 끌면 연결 미리보기, 그냥 떼면 원래 이벤트를 다시 보내
/// 평소 오른쪽 클릭 메뉴가 뜨게 한다. 스크롤·핀치는 마우스 있는 곳을 중심으로 확대·축소.
struct CanvasEventCatcher: NSViewRepresentable {
    var nodeAt: (CGPoint) -> String?
    var onChanged: (String, CGPoint) -> Void
    var onEnded: (String, CGPoint) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CanvasEventView {
        let v = CanvasEventView()
        ListDrag.shared.canvas = v
        return v
    }

    func updateNSView(_ v: CanvasEventView, context: Context) {
        ListDrag.shared.canvas = v
        v.nodeAt = nodeAt
        v.onChanged = onChanged
        v.onEnded = onEnded
        v.onZoom = onZoom
    }
}

final class CanvasEventView: NSView {
    var nodeAt: ((CGPoint) -> String?)?
    var onChanged: ((String, CGPoint) -> Void)?
    var onEnded: ((String, CGPoint) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    private var monitor: Any?
    private var down: NSEvent?
    private var from: String?
    private var start: CGPoint = .zero
    private var dragging = false
    private var replaying: NSEvent?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        let types: NSEvent.EventTypeMask = [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .scrollWheel, .magnify, .leftMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] e in
            guard let self else { return e }
            return self.handle(e)
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    /// 이 이벤트가 그래프 칸 위에서 일어났는지 — 터미널·사이드바·인스펙터의 스크롤 목록·입력칸 위면 건드리지 않는다
    func isOverCanvas(_ wp: NSPoint, _ p: CGPoint) -> Bool {
        guard bounds.contains(p), let hit = window?.contentView?.hitTest(wp) else { return false }
        var v: NSView? = hit
        while let cur = v {
            if cur is NSScrollView || cur is NSText || cur is NSTextField || cur is NSScroller { return false }
            v = cur.superview
        }
        return true
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let window else { return e }
        // 창 정보 없이 들어온 이벤트(합성 이벤트 등)는 화면 좌표로 우리 창 안인지 본다
        let wp: NSPoint
        if e.window === window {
            wp = e.locationInWindow
        } else if e.window == nil, window.frame.contains(e.locationInWindow) {
            wp = window.convertPoint(fromScreen: e.locationInWindow)
        } else {
            return e
        }
        if let r = replaying, r === e { replaying = nil; return e }
        let p = convert(wp, from: nil)
        switch e.type {
        case .scrollWheel:
            guard isOverCanvas(wp, p) else { return e }
            // 손을 뗀 뒤 관성으로 이어지는 스크롤은 무시 (배율이 혼자 계속 바뀌지 않게)
            if !e.momentumPhase.isEmpty { return nil }
            // 기기 기준 방향: 휠을 밀거나 두 손가락을 위로 올리면 확대 (자연스러운 스크롤 설정과 상관없이)
            var dy = e.scrollingDeltaY
            if e.isDirectionInvertedFromDevice { dy = -dy }
            guard dy != 0 else { return nil }
            let f: CGFloat = e.hasPreciseScrollingDeltas
                ? exp(max(min(dy, 60), -60) * 0.005)          // 트랙패드: 픽셀 단위로 잘게
                : pow(1.1, max(min(dy, 8), -8))               // 마우스 휠: 한 칸에 10%
            onZoom?(f, p)
            return nil
        case .magnify:
            guard isOverCanvas(wp, p) else { return e }
            onZoom?(1 + e.magnification, p)
            return nil
        case .leftMouseDown:
            // ⌃클릭도 메뉴: 빈 곳이면 자리를 기억만 하고 그대로 보낸다
            if e.modifierFlags.contains(.control), isOverCanvas(wp, p), nodeAt?(p) == nil {
                CanvasViewport.shared.menuPoint = p
            }
            return e
        case .rightMouseDown:
            guard isOverCanvas(wp, p) else { return e }
            guard let id = nodeAt?(p) else {
                CanvasViewport.shared.menuPoint = p      // 빈 곳: 메뉴('여기에 대화 추가')가 쓸 자리
                return e
            }
            down = e
            from = id
            start = p
            dragging = false
            return nil
        case .rightMouseDragged:
            guard down != nil, let from else { return e }
            if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true }
            if dragging { onChanged?(from, p) }
            return nil
        case .rightMouseUp:
            guard let d = down, let from else { return e }
            down = nil
            self.from = nil
            if dragging {
                dragging = false
                onEnded?(from, p)
                return nil
            }
            replaying = d                       // 끌지 않았으면 원래 오른쪽 클릭으로 (메뉴)
            DispatchQueue.main.async { [weak self] in self?.window?.sendEvent(d) }
            return nil
        default:
            return e
        }
    }
}
