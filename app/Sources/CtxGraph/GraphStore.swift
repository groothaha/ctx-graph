import AppKit
import SwiftUI

@MainActor
final class GraphStore: ObservableObject {
    /// 지금 작업 공간의 노드 (그래프에 그리는 것). 다른 공간까지 전부는 allNodes.
    @Published private(set) var nodes: [GraphNode] = []
    @Published private(set) var allNodes: [GraphNode] = []
    /// 사용자가 붙인 대화 이름 (labels — 그래프에 없는 대화도). 비어 있으면 Claude Code 의 이름을 쓴다
    @Published private(set) var labels: [String: String] = [:]
    /// 지금 공간에 없는 연결 상대 (흐린 카드). 자리는 이 공간 카드 옆으로 계산한다 (저장 안 함)
    struct Ghost: Identifiable, Equatable { let id: String; let point: CGPoint; let space: String }
    @Published private(set) var ghosts: [Ghost] = []
    /// 한쪽 끝만 지금 공간에 있는 화살표 (흐린 카드와 이어짐)
    @Published private(set) var ghostLinks: [Link] = []
    private var hereIndex: [String: Int] = [:]
    /// 공간 → (대화 → 위치). 같은 대화가 여러 공간에 놓일 수 있다 (reloadGraph 가 채움)
    private(set) var placed: [String: [String: CGPoint]] = [:]
    /// 모든 연결 (다른 공간과 이어진 것도 — 맥락 주입은 공간과 상관없이 동작)
    @Published private(set) var links: [Link] = []
    /// 양끝이 다 지금 공간에 있는 연결 (그래프에 그리는 것)
    @Published private(set) var visibleLinks: [Link] = []
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var space: String = Space.main
    @Published private(set) var pairs: [EdgePair] = []
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var scanning = false
    @Published private(set) var launching: Set<String> = []
    @Published var selection: Selection?
    @Published var notice: String?
    /// Claude Code 훅 설치 상태 (ctxgraph.py hooks-status)
    @Published private(set) var hooks: HookStatus?
    @Published private(set) var hookBusy = false
    /// 고장 알림 (ctxgraph.py 가 settings.health_* 에 씀): Claude Code 의 기록·훅 형식이 바뀌었을 때
    @Published private(set) var health: [String] = []
    /// 백엔드를 돌릴 python3 가 있는지 (없으면 첫 실행 안내가 개발자 도구 설치를 권함)
    @Published private(set) var pythonOK = PythonRuntime.path != nil
    /// 백엔드를 실행했는데 알아들을 수 없는 답이 왔을 때 (스크립트 오류 등)
    @Published private(set) var backendError: String?
    /// graph.sqlite 가 더 새 CtxGraph 의 형식이면 그 번호 (그동안 읽기만 함)
    @Published private(set) var newerData: Int?
    /// 실험 기능(작업 폴더·셸 샌드박스)을 보일지
    var experimental: Bool { settings["experimental"] == "1" }
    /// 앱 터미널에서 Claude 를 권한 확인 없이 (--dangerously-skip-permissions). 기본은 꺼짐 — 설정 → 터미널
    var skipPermissions: Bool { settings["skip_permissions"] == "1" }
    @Published private(set) var models: [ModelProfile] = []
    @Published private(set) var settings: [String: String] = [:]
    @Published private(set) var keyStatus: [String: Bool] = [:]
    @Published private(set) var places: [Place] = []
    @Published private(set) var nodePlaces: [String: Set<Int>] = [:]

    /// 끌고 있는 노드 — 2초 폴링이 위치를 덮어쓰지 않게.
    var draggingID: String?
    weak var terminals: TerminalManager?

    private var db: SQLiteDB?
    /// graph.sqlite-wal 감시: 훅이 맥락을 넣으면(쓰기) 2초 폴링을 기다리지 않고 곧바로 다시 읽는다
    private var walWatch: DispatchSourceFileSystemObject?
    private var walReloadPending = false
    private var sessionIndex: [String: SessionInfo] = [:]
    private var started = false

    // MARK: 시작·새로고침

    func start() {
        guard !started else { return }
        started = true
        Paths.installBundledScripts()
        Task { await boot() }
        // 훅·요약 작업이 바꾼 상태를 따라간다 (스토어는 앱과 수명이 같다)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                watchDatabase()
                reloadGraph()
            }
        }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await rescan()
            }
        }
    }

    /// 백엔드로 DB 를 만들거나 올리고(init) 연다. python3 가 없으면 열지 않는다 — 첫 실행 안내가 알려 주고,
    /// 개발자 도구를 설치한 뒤 '다시 확인'(recheckRuntime)하면 여기부터 다시 한다.
    private func openDatabase() async -> Bool {
        pythonOK = PythonRuntime.path != nil
        guard pythonOK else { return false }
        let r = await Python.run(["init"])
        if r.status != 0 && r.status != Python.newerData {
            notice = String(localized: "백엔드를 시작하지 못했어요: \(Fmt.oneLine(r.output, 200))")
        }
        do {
            db = try SQLiteDB(path: Paths.db)
        } catch {
            notice = String(localized: "그래프 파일을 열 수 없어요: \(error.localizedDescription)")
            return false
        }
        if let db, db.userVersion > Schema.version {
            db.readOnly = true                    // 모르는 형식에는 쓰지 않는다
            newerData = db.userVersion
        }
        return true
    }

    /// WAL 파일에 쓰기가 생기면 0.15초 뒤 한 번 다시 읽는다 (몰려 와도 한 번). 파일이 지워지면 폴링이 다시 건다.
    private func watchDatabase() {
        guard walWatch == nil, db != nil else { return }
        let fd = open(Paths.db + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !src.data.isDisjoint(with: [.delete, .rename]) {
                    src.cancel()
                    self.walWatch = nil
                    return
                }
                guard !self.walReloadPending else { return }
                self.walReloadPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        self.walReloadPending = false
                        self.reloadGraph()
                    }
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        walWatch = src
    }

    /// python3 를 다시 찾고, 아직 시작 못 했으면 이어서 시작
    func recheckRuntime() async {
        PythonRuntime.refresh()
        pythonOK = PythonRuntime.path != nil
        if db == nil { await boot() } else { await refreshHooks(); await rescan() }
    }

    private func boot() async {
        guard await openDatabase() else { await refreshHooks(); return }
        Task { await refreshHooks() }
        reloadHealth()
        reloadSessions()
        reloadModels()
        let saved = settings["current_space"] ?? Space.main
        reloadGraph()
        if spaces.contains(where: { $0.id == saved }) { space = saved }
        applySpace()
        terminals?.enter(space)
        // 화면 점검용: CTXGRAPH_SELECT=<세션 ID 앞부분> 이면 시작할 때 그 노드를 선택
        let env = ProcessInfo.processInfo.environment
        if let pre = env["CTXGRAPH_SELECT"], let n = nodes.first(where: { $0.id.hasPrefix(pre) }) {
            selection = .node(n.id)
        }
        if let pre = env["CTXGRAPH_SELECT_EDGE"]?.split(separator: ",").map(String.init), pre.count == 2,
           let l = links.first(where: { $0.src.hasPrefix(pre[0]) && $0.dst.hasPrefix(pre[1]) }) {
            selection = .edge(l.id)
        }
        for pre in (env["CTXGRAPH_OPEN"] ?? "").split(separator: ",").map(String.init) where !pre.isEmpty {
            if let n = nodes.first(where: { $0.id.hasPrefix(pre) }) { terminals?.open(n.id) }
        }
        if let dir = env["CTXGRAPH_NEW"] { terminals?.openNew(cwd: dir, model: env["CTXGRAPH_NEW_MODEL"]) }

        await rescan()
    }

    func rescan() async {
        guard !scanning else { return }
        if pythonOK && newerData == nil {        // 백엔드를 못 돌리면 DB 에 있는 것만 다시 읽는다
            scanning = true
            let r = await Python.run(["scan"])
            scanning = false
            if r.status != 0 && r.status != Python.newerData {
                notice = String(localized: "대화 목록을 읽지 못했어요: \(Fmt.oneLine(r.output, 200))")
            }
        }
        reloadSessions()
        reloadGraph()
        reloadHealth()
    }

    func reloadHealth() {
        guard let db else { return }
        var h: [String] = []
        db.query("SELECT value FROM settings WHERE key LIKE 'health_%' AND value <> '' ORDER BY key") { r in
            if let v = r.text(0) { h.append(v) }
        }
        if h != health { health = h }
    }

    // MARK: 미리보기·사용량 (ctxgraph.py preview / usage)

    struct InjectionPreview: Decodable, Equatable {
        struct Item: Decodable, Equatable {
            let src: String
            let title: String
            let version: Int
            let received: Int?
            let mode: String          // full | delta | same | none
        }
        let text: String?
        let chars: Int
        let budget: Int
        let items: [Item]
        let gone: [String]
    }

    func preview(_ id: String) async -> InjectionPreview? {
        let r = await Python.run(["preview", id])
        return try? JSONDecoder().decode(InjectionPreview.self, from: Data(r.output.utf8))
    }

    struct Usage: Decodable, Equatable {
        let today: Int
        let week: Int
        let month: Int
        let failed_week: Int
        let by_model: [String: Int]
        let last_at: Double?
    }

    func usage() async -> Usage? {
        let r = await Python.run(["usage"])
        return try? JSONDecoder().decode(Usage.self, from: Data(r.output.utf8))
    }

    func reloadSessions() {
        guard let db else { return }
        var list: [SessionInfo] = []
        var seen = Set<String>()
        db.query("""
            SELECT session_id, path, cwd, agent_name, ai_title, first_prompt, last_prompt, n_prompts, mtime, live_status
            FROM sessions ORDER BY mtime DESC
            """) { r in
            guard let id = r.text(0), seen.insert(id).inserted else { return }
            list.append(SessionInfo(id: id, path: r.text(1) ?? "", cwd: r.text(2), agentName: r.text(3),
                                    aiTitle: r.text(4), firstPrompt: r.text(5), lastPrompt: r.text(6),
                                    nPrompts: r.int(7), mtime: r.double(8) ?? 0, liveStatus: r.text(9)))
        }
        sessionIndex = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if list != sessions { sessions = list }
    }

    func reloadGraph() {
        guard let db else { return }
        let now = Date().timeIntervalSince1970
        var ns: [GraphNode] = []
        db.query("""
            SELECT session_id, transcript_path, cwd, label, x, y, summary, delta, summary_version,
                   summary_at, summary_error, job_started_at, summarizing_at, model_id, write_limited, write_strict,
                   COALESCE(space, 'main'), summary_src_size, summary_src_at
            FROM nodes ORDER BY added_at
            """) { r in
            guard let id = r.text(0) else { return }
            let summarizingAt = r.double(12)
            ns.append(GraphNode(
                id: id, transcriptPath: r.text(1) ?? "", cwd: r.text(2), label: r.text(3),
                x: r.double(4) ?? 300, y: r.double(5) ?? 200, summary: r.text(6), delta: r.text(7),
                version: r.int(8), summaryAt: r.double(9), summaryError: r.text(10),
                jobPending: r.double(11) != nil,
                summarizing: summarizingAt.map { now - $0 < 600 } ?? false,
                modelID: r.text(13), writeLimited: r.int(14) != 0, writeStrict: r.int(15) != 0,
                spaces: [r.text(16) ?? Space.main], srcSize: r.int(17), srcAt: r.double(18)))
        }
        var sp: [Space] = []
        db.query("SELECT id, name, sort FROM spaces ORDER BY sort, created_at") { r in
            if let id = r.text(0) { sp.append(Space(id: id, name: r.text(1) ?? id, sort: r.int(2))) }
        }
        if sp.isEmpty { sp = [Space(id: Space.main, name: String(localized: "기본"), sort: 0)] }
        // 공간별 위치 (v2). 같은 대화가 여러 공간에 놓일 수 있다. 위치가 하나도 없는 노드(v1 DB 등)는 nodes 의 space·x·y 로.
        let known = Set(ns.map(\.id)), spaceIDs = Set(sp.map(\.id))
        var pl: [String: [String: CGPoint]] = [:]
        var order: [String: [String]] = [:]
        db.query("SELECT session_id, space, x, y FROM placements ORDER BY added_at") { r in
            guard let id = r.text(0), known.contains(id), var s = r.text(1) else { return }
            if !spaceIDs.contains(s) { s = Space.main }            // 지워진 공간 → 기본
            guard pl[s]?[id] == nil else { return }
            pl[s, default: [:]][id] = CGPoint(x: r.double(2) ?? 300, y: r.double(3) ?? 200)
            order[id, default: []].append(s)
        }
        for i in ns.indices {
            if let o = order[ns[i].id] {
                ns[i].spaces = o
                let p = pl[o[0]]![ns[i].id]!
                ns[i].x = p.x
                ns[i].y = p.y
            } else {
                let s = spaceIDs.contains(ns[i].spaces[0]) ? ns[i].spaces[0] : Space.main
                ns[i].spaces = [s]
                pl[s, default: [:]][ns[i].id] = ns[i].point
            }
        }
        if let d = draggingID, let local = nodes.first(where: { $0.id == d }) {
            pl[space, default: [:]][d] = local.point
        }
        // 대화 이름 (v3). 그 전 DB 면 노드에 붙어 있던 이름
        var lb: [String: String] = [:]
        if db.userVersion >= 3 {
            db.query("SELECT session_id, label FROM labels") { r in
                if let id = r.text(0), let l = r.text(1), !l.isEmpty { lb[id] = l }
            }
        } else {
            for n in ns { if let l = n.label, !l.isEmpty { lb[n.id] = l } }
        }
        for i in ns.indices { ns[i].label = lb[ns[i].id] }
        if lb != labels { labels = lb }
        placed = pl
        var ls: [Link] = []
        db.query("SELECT src, dst FROM links ORDER BY created_at") { r in
            if let s = r.text(0), let d = r.text(1) { ls.append(Link(src: s, dst: d)) }
        }
        var ps: [EdgePair] = []
        var index: [String: Int] = [:]
        for l in ls {
            let key = EdgePair.key(l.src, l.dst)
            if index[key] == nil {
                index[key] = ps.count
                let (a, b) = l.src < l.dst ? (l.src, l.dst) : (l.dst, l.src)
                ps.append(EdgePair(a: a, b: b, ab: false, ba: false))
            }
            if l.src < l.dst { ps[index[key]!].ab = true } else { ps[index[key]!].ba = true }
        }
        reloadPlaces()
        if sp != spaces { spaces = sp }
        if ns != allNodes { allNodes = ns }
        if ls != links { links = ls }
        if ps != pairs { pairs = ps }
        FlowStatus.shared.reload(db, nodes: ns, links: ls)        // 맥락 전달 상태 (시간차 표시)
        if !sp.contains(where: { $0.id == space }) {        // 다른 곳에서 지운 공간 → 기본
            space = Space.main
            terminals?.enter(space)
        }
        applySpace()
    }

    /// 지금 공간의 노드·연결만 골라 그린다
    private func applySpace() {
        let at = placed[space] ?? [:]
        let vs = allNodes.compactMap { n -> GraphNode? in
            guard let p = at[n.id] else { return nil }
            var m = n
            m.x = p.x
            m.y = p.y
            return m
        }
        let here = Set(vs.map(\.id))
        let vl = links.filter { here.contains($0.src) && here.contains($0.dst) }
        if vs != nodes { nodes = vs }
        hereIndex = Dictionary(uniqueKeysWithValues: vs.enumerated().map { ($1.id, $0) })
        if vl != visibleLinks { visibleLinks = vl }
        let (gs, gl) = layoutGhosts(vs, here)
        if gs != ghosts { ghosts = gs }
        if gl != ghostLinks { ghostLinks = gl }
        if case .edge(let id) = selection, !vl.contains(where: { $0.id == id }), !gl.contains(where: { $0.id == id }) { selection = nil }
        switch selection {
        case .node(let id) where !here.contains(id): selection = nil
        default: break
        }
    }

    /// 흐린 카드 자리: 연결된 이 공간 카드들의 가운데에서, 맥락을 보내는 쪽이면 위로 받는 쪽이면 아래로 한 줄.
    /// 카드·다른 흐린 카드와 겹치면 옆·다음 줄로. 같은 그래프면 늘 같은 자리.
    private func layoutGhosts(_ vs: [GraphNode], _ here: Set<String>) -> ([Ghost], [Link]) {
        let cross = links.filter { here.contains($0.src) != here.contains($0.dst) }
        guard !cross.isEmpty else { return ([], []) }
        let pos = Dictionary(uniqueKeysWithValues: vs.map { ($0.id, $0.point) })
        var peers: [String: (here: [CGPoint], sends: Bool)] = [:]
        for l in cross {
            let sends = !here.contains(l.src)
            let (g, h) = sends ? (l.src, l.dst) : (l.dst, l.src)
            guard let p = pos[h] else { continue }
            peers[g, default: ([], false)].here.append(p)
            if sends { peers[g]!.sends = true }
        }
        let anchors = peers.mapValues { v in
            CGPoint(x: v.here.map(\.x).reduce(0, +) / CGFloat(v.here.count),
                    y: v.here.map(\.y).reduce(0, +) / CGFloat(v.here.count))
        }
        var taken = vs.map { $0.frame.insetBy(dx: -14, dy: -14) }
        var out: [Ghost] = []
        for g in peers.keys.sorted(by: { (anchors[$0]!.x, anchors[$0]!.y, $0) < (anchors[$1]!.x, anchors[$1]!.y, $1) }) {
            let a = anchors[g]!, dir: CGFloat = peers[g]!.sends ? -1 : 1
            var spot: CGPoint?
            search: for d in [dir, -dir] {
                for row in 1...3 {
                    for col in [0, 1, -1, 2, -2] {
                        let p = CGPoint(x: (a.x + CGFloat(col) * 280).rounded(), y: (a.y + d * CGFloat(row) * 150).rounded())
                        if !taken.contains(where: { $0.intersects(Layout.frame(at: p)) }) { spot = p; break search }
                    }
                }
            }
            let p = spot ?? CGPoint(x: a.x.rounded(), y: (a.y + dir * 150).rounded())
            taken.append(Layout.frame(at: p).insetBy(dx: -14, dy: -14))
            out.append(Ghost(id: g, point: p, space: spaceName(node(g)?.spaces.first)))
        }
        return (out, cross)
    }

    /// 지금 공간에서 이 대화를 그릴 자리 (카드, 없으면 흐린 카드)
    func position(_ id: String) -> CGPoint? {
        if let i = hereIndex[id], nodes.indices.contains(i), nodes[i].id == id { return nodes[i].point }
        return ghosts.first { $0.id == id }?.point
    }

    func ghostID(at p: CGPoint) -> String? {
        ghosts.last { Layout.frame(at: $0.point).contains(p) }?.id
    }

    // MARK: 작업 공간

    func spaceName(_ id: String?) -> String { spaces.first { $0.id == (id ?? Space.main) }?.name ?? String(localized: "기본") }
    func nodeCount(in sp: String) -> Int { placed[sp]?.count ?? 0 }
    /// 이 노드가 지금 공간엔 없고 다른 공간에만 있으면 그 (첫) 공간 이름
    func otherSpaceName(_ id: String) -> String? {
        guard let n = node(id), !isHere(id) else { return nil }
        return spaceName(n.spaces.first)
    }
    /// 지금 공간 말고 이 대화가 놓인 공간들의 이름
    func alsoIn(_ id: String) -> [String] {
        (node(id)?.spaces ?? []).filter { $0 != space }.map { spaceName($0) }
    }

    func switchSpace(_ id: String) {
        guard id != space, spaces.contains(where: { $0.id == id }) else { return }
        selection = nil
        space = id
        db?.query("INSERT OR REPLACE INTO settings(key, value) VALUES('current_space', ?)", [id])
        settings["current_space"] = id
        applySpace()
        terminals?.enter(id)
    }

    /// ⌘1…9: n 번째 공간으로
    func switchSpace(index: Int) {
        guard spaces.indices.contains(index) else { NSSound.beep(); return }
        switchSpace(spaces[index].id)
    }

    func cycleSpace(_ d: Int) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == space }) else { return }
        switchSpace(spaces[((i + d) % spaces.count + spaces.count) % spaces.count].id)
    }

    @discardableResult
    func createSpace(_ name: String, switchTo: Bool = true) -> String {
        let id = "s-" + String(UUID().uuidString.lowercased().prefix(8))
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sort = (spaces.map(\.sort).max() ?? 0) + 1
        db?.query("INSERT INTO spaces(id, name, sort, created_at) VALUES(?,?,?,?)",
                  [id, t.isEmpty ? String(localized: "공간 \(spaces.count + 1)") : t, sort, Date().timeIntervalSince1970])
        reloadGraph()
        if switchTo { switchSpace(id) }
        return id
    }

    func renameSpace(_ id: String, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        db?.query("UPDATE spaces SET name=? WHERE id=?", [t, id])
        reloadGraph()
    }

    /// 순서 바꾸기 (⌘1…9 번호도 따라감)
    func moveSpace(_ id: String, by d: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard spaces.indices.contains(j) else { return }
        var order = spaces
        order.swapAt(i, j)
        for (k, s) in order.enumerated() { db?.query("UPDATE spaces SET sort=? WHERE id=?", [k, s.id]) }
        reloadGraph()
    }

    /// 공간을 지운다: 그 안의 대화·터미널은 into 공간으로 옮긴다 (아무것도 끄지 않음). 기본 공간은 못 지움.
    func deleteSpace(_ id: String, into target: String = Space.main) {
        guard id != Space.main, id != target, spaces.contains(where: { $0.id == id }) else { return }
        let ids = allNodes.map(\.id).filter { placed[id]?[$0] != nil }
        if !ids.isEmpty { moveNodes(ids, from: id, to: target, moveTabs: false) }
        if space == id { switchSpace(target) }          // 먼저 옮겨 가고 (떠나는 배치는 mergeSpace 가 버림)
        terminals?.mergeSpace(id, into: target)         // 그 공간 탭은 target 의 뒤에 있는 탭으로
        db?.query("DELETE FROM spaces WHERE id=?", [id])
        reloadGraph()
    }

    /// 대화들을 다른 공간으로 옮긴다 (from 공간에서 빠짐). from 이 없으면 지금 공간, 지금 공간에 없는 대화는 그 첫 공간에서.
    /// 열린 터미널 탭도 같이 그 공간으로 간다 (프로세스는 그대로).
    func moveNodes(_ ids: [String], from: String? = nil, to target: String, at drop: CGPoint? = nil, moveTabs: Bool = true) {
        let moved = place(ids, from: from, to: target, at: drop, keep: false)
        if moveTabs {
            terminals?.moveTabs(moved.filter { m in terminals?.tab(m.id)?.space == m.from }.map(\.id), to: target)
        }
        reloadGraph()
    }

    /// 대화들을 다른 공간에도 놓는다 (원래 공간에도 그대로). 위치는 공간마다 따로, 맥락 연결은 하나.
    func alsoShow(_ ids: [String], in target: String, at drop: CGPoint? = nil) {
        place(ids, from: nil, to: target, at: drop, keep: true)
        reloadGraph()
    }

    /// 옮기기·다른 공간에도 놓기 공통. target 에 이미 노드가 있으면 겹치지 않게 아래쪽에 놓는다 (서로의 배치는 유지).
    @discardableResult
    private func place(_ ids: [String], from: String?, to target: String, at drop: CGPoint?, keep: Bool) -> [(id: String, from: String)] {
        var moving: [(id: String, from: String, p: CGPoint)] = []
        var done: [(id: String, from: String)] = []
        for id in ids {
            guard let n = node(id) else { continue }
            let src = from ?? (isHere(id) ? space : n.spaces[0])
            guard src != target, let p = placed[src]?[id] else { continue }
            if placed[target]?[id] != nil {                       // 이미 거기 있음: 옮기기면 원래 자리만 뺀다
                if !keep { db?.query("DELETE FROM placements WHERE session_id=? AND space=?", [id, src]) }
                done.append((id, src))
            } else {
                moving.append((id, src, p))
            }
        }
        guard !moving.isEmpty else { return done }
        let movingIDs = Set(moving.map(\.id))
        let there = (placed[target] ?? [:]).filter { !movingIDs.contains($0.key) }.values.map { Layout.frame(at: $0) }
        let minY = moving.map(\.p.y).min()!
        var dx = 0.0, dy = 0.0
        if let drop {
            dx = drop.x - moving[0].p.x
            dy = drop.y - moving[0].p.y
        } else if let bottom = there.map(\.midY).max() {
            // 겹치면 그 공간 노드들 아래로
            let frames = moving.map { Layout.frame(at: $0.p) }
            if there.contains(where: { t in frames.contains { $0.insetBy(dx: -20, dy: -20).intersects(t) } }) {
                dy = bottom + 170 - minY
            }
        }
        let now = Date().timeIntervalSince1970
        for m in moving {
            db?.query("INSERT OR REPLACE INTO placements(session_id, space, x, y, added_at) VALUES(?,?,?,?,?)",
                      [m.id, target, Double(m.p.x + dx), Double(m.p.y + dy), now])
            if !keep { db?.query("DELETE FROM placements WHERE session_id=? AND space=?", [m.id, m.from]) }
            done.append((m.id, m.from))
        }
        return done
    }

    /// 인스펙터의 공간 체크: 켜면 그 공간에도 놓고, 끄면 그 공간에서 뺀다 (마지막 한 곳은 못 끔)
    func setShown(_ id: String, in sp: String, _ on: Bool) {
        guard let n = node(id) else { return }
        if on {
            guard placed[sp]?[id] == nil else { return }
            alsoShow([id], in: sp)
            let k = spaces.firstIndex { $0.id == sp }.map { $0 < 9 ? " (⌘\($0 + 1))" : "" } ?? ""
            notice = String(localized: "«\(spaceName(sp))» 공간에도 놓았어요\(k)")
        } else {
            guard n.spaces.count > 1, placed[sp]?[id] != nil else { return }
            db?.query("DELETE FROM placements WHERE session_id=? AND space=?", [id, sp])
            if sp == space, selection == .node(id) { selection = nil }
            reloadGraph()
            notice = String(localized: "«\(spaceName(sp))» 공간에서 뺐어요")
        }
    }

    /// 이 노드와 (지금 공간 안에서) 선으로 이어진 노드 전부
    func component(_ id: String) -> [String] {
        let here = Set(nodes.map(\.id))
        var seen: Set<String> = [id], queue = [id]
        while let cur = queue.popLast() {
            for o in neighbors(cur) where here.contains(o) && seen.insert(o).inserted { queue.append(o) }
        }
        return nodes.map(\.id).filter { seen.contains($0) }
    }

    /// 다른 공간에 있는 노드면 그 공간으로 가서 선택
    func reveal(_ id: String) {
        guard let n = node(id) else { return }
        if !isHere(id) { switchSpace(n.spaces[0]) }
        selection = .node(id)
    }

    // MARK: 모델·설정·키

    func reloadModels() {
        guard let db else { return }
        var ms: [ModelProfile] = []
        db.query("SELECT id, name, provider, model, small_model, base_url, sort FROM models ORDER BY sort, name") { r in
            guard let id = r.text(0), let p = ModelProfile.Provider(rawValue: r.text(2) ?? "") else { return }
            ms.append(ModelProfile(id: id, name: r.text(1) ?? id, provider: p, model: r.text(3),
                                   smallModel: r.text(4), baseURL: r.text(5), sort: r.int(6)))
        }
        var st: [String: String] = [:]
        db.query("SELECT key, value FROM settings") { r in
            if let k = r.text(0) { st[k] = r.text(1) ?? "" }
        }
        let ks = Keys.load().mapValues { !$0.isEmpty }
        if ms != models { models = ms }
        if st != settings { settings = st }
        if ks != keyStatus { keyStatus = ks }
    }

    func model(_ id: String?) -> ModelProfile? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    var defaultModelID: String { settings["default_model"].flatMap { model($0)?.id } ?? "claude" }
    var summaryModelID: String { settings["summary_model"].flatMap { model($0)?.id } ?? "claude-haiku" }

    /// 이 모델을 쓸 준비가 됐는지 (API 키 방식이면 키가 있어야)
    func isReady(_ m: ModelProfile) -> Bool {
        guard let k = m.provider.keyName else { return true }
        if m.provider == .custom, (m.baseURL ?? settings["custom_base_url"] ?? "").isEmpty { return false }
        return keyStatus[k] == true && !(m.model ?? "").isEmpty
    }

    func setSetting(_ key: String, _ value: String) {
        db?.query("INSERT OR REPLACE INTO settings(key, value) VALUES(?,?)", [key, value])
        reloadModels()
    }

    func saveModel(_ m: ModelProfile) {
        db?.query("""
            INSERT OR REPLACE INTO models(id, name, provider, model, small_model, base_url, sort) VALUES(?,?,?,?,?,?,?)
            """, [m.id, m.name, m.provider.rawValue, m.model.flatMap { $0.isEmpty ? nil : $0 },
                  m.smallModel.flatMap { $0.isEmpty ? nil : $0 }, m.baseURL.flatMap { $0.isEmpty ? nil : $0 }, m.sort])
        reloadModels()
    }

    func deleteModel(_ id: String) {
        guard !ModelProfile.builtinIDs.contains(id) else { return }
        db?.query("DELETE FROM models WHERE id=?", [id])
        db?.query("UPDATE nodes SET model_id=NULL WHERE model_id=?", [id])
        for key in ["summary_model", "default_model"] where settings[key] == id {
            setSetting(key, key == "summary_model" ? "claude-haiku" : "claude")
        }
        reloadModels()
        reloadGraph()
    }

    func setKey(_ name: String, _ value: String) {
        var k = Keys.load()
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { k.removeValue(forKey: name) } else { k[name] = v }
        if Keys.save(k) { notice = v.isEmpty ? String(localized: "키를 지웠어요") : String(localized: "키를 저장했어요") }
        else { notice = String(localized: "키를 저장하지 못했어요") }
        reloadModels()
    }

    func importOrc(withKey: Bool) async {
        let r = await Python.run(["import-orc"] + (withKey ? ["--key"] : []))
        notice = Fmt.oneLine(r.output, 160)
        reloadModels()
    }

    func testModel(_ id: String) async -> String {
        let r = await Python.run(["test-model", id])
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setNodeModel(_ id: String, _ modelID: String?) {
        db?.query("UPDATE nodes SET model_id=? WHERE session_id=?", [modelID, id])
        reloadGraph()
    }

    // MARK: 조회

    /// 어느 공간이든
    func node(_ id: String) -> GraphNode? { allNodes.first { $0.id == id } }
    func session(_ id: String) -> SessionInfo? { sessionIndex[id] }
    /// 어느 공간이든 그래프에 있음
    func isInGraph(_ id: String) -> Bool { allNodes.contains { $0.id == id } }
    /// 지금 공간에 있음
    func isHere(_ id: String) -> Bool { placed[space]?[id] != nil }
    /// 그 공간에 놓여 있음
    func isShown(_ id: String, in sp: String) -> Bool { placed[sp]?[id] != nil }

    func title(_ id: String) -> String {
        if let l = labels[id] { return l }
        if let s = sessionIndex[id] { return s.title }
        return node(id) != nil ? String(localized: "새 대화") : String(id.prefix(8))
    }

    /// id 로 맥락이 들어오는 대화들
    func sources(_ id: String) -> [String] { links.filter { $0.dst == id }.map(\.src) }
    /// id 의 맥락을 받는 대화들
    func targets(_ id: String) -> [String] { links.filter { $0.src == id }.map(\.dst) }
    /// 어느 방향으로든 연결된 대화들
    func neighbors(_ id: String) -> [String] {
        var seen = Set<String>()
        return links.compactMap { l in
            let o = l.src == id ? l.dst : (l.dst == id ? l.src : nil)
            guard let o, seen.insert(o).inserted else { return nil }
            return o
        }
    }
    func pair(_ x: String, _ y: String) -> EdgePair? { pairs.first { $0.id == EdgePair.key(x, y) } }

    func isBusy(_ id: String) -> Bool { launching.contains(id) || (node(id)?.summarizing ?? false) }

    func nodeID(at p: CGPoint, excluding: String? = nil) -> String? {
        nodes.last { $0.id != excluding && $0.frame.contains(p) }?.id
    }

    // MARK: 편집

    /// 그래프 판: 기본 판과 지금 공간 노드들을 감싸고 사방으로 margin 만큼 더 (음수 좌표도 됨).
    /// 노드를 바깥으로 옮기면 판도 따라 넓어지므로 사실상 끝이 없다.
    var worldRect: CGRect {
        (nodes.map(\.frame) + ghosts.map { Layout.frame(at: $0.point) })
            .reduce(CGRect(origin: .zero, size: Layout.canvas)) { $0.union($1) }
            .insetBy(dx: -Layout.margin, dy: -Layout.margin)
    }

    /// 노드 중심이 그래프 판 안에 있게
    func clamp(_ p: CGPoint) -> CGPoint {
        let w = worldRect.insetBy(dx: Layout.node.width / 2 + 8, dy: Layout.node.height / 2 + 8)
        return CGPoint(x: min(max(p.x, w.minX), w.maxX), y: min(max(p.y, w.minY), w.maxY)).snapped
    }

    /// 지금 공간 노드들이 가장 많이 쓰는 폴더 (카드에는 이것과 다를 때만 폴더를 보여 준다)
    var usualCwd: String? {
        var count: [String: Int] = [:]
        for n in nodes { if let c = n.cwd ?? sessionIndex[n.id]?.cwd { count[c, default: 0] += 1 } }
        return count.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// p 에 카드를 놓으면 다른 카드와 겹칠 때 가장 가까운 빈 자리 (24pt 간격으로 바깥으로 찾아 나감)
    func freeNear(_ p: CGPoint, excluding id: String? = nil) -> CGPoint {
        let others = nodes.filter { $0.id != id }.map { $0.frame.insetBy(dx: -12, dy: -12) }
        func ok(_ q: CGPoint) -> Bool {
            let r = CGRect(x: q.x - Layout.node.width / 2, y: q.y - Layout.node.height / 2,
                           width: Layout.node.width, height: Layout.node.height)
            return !others.contains { $0.intersects(r) }
        }
        if ok(p) { return p }
        for ring in 1...40 {
            let d = CGFloat(ring) * 24
            var cands: [CGPoint] = []
            for i in -ring...ring {
                let t = CGFloat(i) * 24
                cands += [CGPoint(x: p.x + t, y: p.y - d), CGPoint(x: p.x + t, y: p.y + d),
                          CGPoint(x: p.x - d, y: p.y + t), CGPoint(x: p.x + d, y: p.y + t)]
            }
            if let best = cands.filter(ok).min(by: { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }) {
                return clamp(best)
            }
        }
        return p
    }

    // MARK: Claude Code 훅

    struct HookStatus: Decodable, Equatable {
        let installed: Bool
        let partial: Bool
        let stale: Bool          // 훅이 다른 경로의 스크립트를 가리킴 (앱을 옮겼을 때)
        let claude: String?      // claude 명령 경로 (없으면 nil)
        let claude_version: String?
        let settings: String
        let skill: String        // none | managed | custom
        let error: String?
        var ok: Bool { installed && !stale }
    }

    func refreshHooks() async {
        guard pythonOK else {
            hooks = nil
            backendError = nil
            return
        }
        let r = await Python.run(["hooks-status"])
        let h = try? JSONDecoder().decode(HookStatus.self, from: Data(r.output.utf8))
        if h != hooks { hooks = h }
        let err = h == nil ? String(localized: "백엔드를 실행하지 못했어요: \(Fmt.oneLine(r.output, 200))") : nil
        if err != backendError { backendError = err }
    }

    func setHooks(_ on: Bool) async {
        hookBusy = true
        let r = await Python.run([on ? "install-hooks" : "uninstall-hooks"])
        notice = Fmt.oneLine(r.output.trimmingCharacters(in: .whitespacesAndNewlines), 220)
        await refreshHooks()
        hookBusy = false
    }

    func move(_ id: String, to p: CGPoint) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        let c = clamp(p)
        nodes[i].x = c.x
        nodes[i].y = c.y
    }

    func persistPosition(_ id: String) {
        guard let n = nodes.first(where: { $0.id == id }) else { return }
        db?.query("INSERT INTO placements(session_id, space, x, y, added_at) VALUES(?,?,?,?,?)"
                  + " ON CONFLICT(session_id, space) DO UPDATE SET x=excluded.x, y=excluded.y",
                  [id, space, n.x, n.y, Date().timeIntervalSince1970])
        placed[space]?[id] = n.point
    }

    func addNodes(_ ids: [String], at p: CGPoint) {
        for (k, id) in ids.enumerated() {
            addNode(id, at: CGPoint(x: p.x + Double(k) * 28, y: p.y + Double(k) * 28))
        }
    }

    /// 그래프에 추가. 이미 있으면: 끌어다 놓은 거면 놓은 자리로 옮기고(다른 공간에만 있으면 이 공간에도 놓고), 아니면 그 노드를 보여 준다.
    func addNode(_ id: String, at p: CGPoint? = nil) {
        if node(id) != nil {
            if let p {
                if !isHere(id) { alsoShow([id], in: space) }
                move(id, to: freeNear(clamp(p), excluding: id))
                persistPosition(id)
                selection = .node(id)
            } else {
                reveal(id)
            }
            return
        }
        guard let s = sessionIndex[id] else { return }
        insertNode(id, path: s.path, cwd: s.cwd, in: space, at: p ?? freeSpot())
        reloadGraph()
        if let p { move(id, to: freeNear(clamp(p), excluding: id)); persistPosition(id) }
        selection = .node(id)
    }

    /// 앱에서 새로 시작한 대화: 기록 파일이 생기기 전이라도 노드를 먼저 만든다
    /// (연결된 새 대화면 첫 메시지부터 맥락이 들어가야 하므로).
    func addPendingNode(_ id: String, cwd: String, near: String?, at point: CGPoint? = nil) {
        var spot = point.map { freeNear(clamp($0)) } ?? freeSpot()
        if point == nil, let near, let n = position(near) {
            spot = freeNear(clamp(CGPoint(x: n.x + 300, y: n.y)))
        }
        insertNode(id, path: Paths.transcript(id: id, cwd: cwd), cwd: cwd, in: space, at: spot)
        reloadGraph()
    }

    /// 새 노드 + 그 공간의 위치 (위치를 먼저 써서, 중간에 다시 읽어도 엉뚱한 공간에 안 보이게)
    private func insertNode(_ id: String, path: String, cwd: String?, in sp: String, at p: CGPoint) {
        let now = Date().timeIntervalSince1970
        db?.query("INSERT OR IGNORE INTO placements(session_id, space, x, y, added_at) VALUES(?,?,?,?,?)",
                  [id, sp, Double(p.x), Double(p.y), now])
        db?.query("INSERT OR IGNORE INTO nodes(session_id, transcript_path, cwd, added_at) VALUES(?,?,?,?)",
                  [id, path, cwd, now])
    }

    private func freeSpot(in sp: String? = nil) -> CGPoint {
        let there = (placed[sp ?? space] ?? [:]).values.map { Layout.frame(at: $0) }
        for row in 0..<12 {
            for col in 0..<6 {
                let p = CGPoint(x: 200 + Double(col) * 300, y: 130 + Double(row) * 160)
                let r = CGRect(x: p.x - Layout.node.width / 2 - 20, y: p.y - Layout.node.height / 2 - 20,
                               width: Layout.node.width + 40, height: Layout.node.height + 40)
                if !there.contains(where: { $0.intersects(r) }) { return p }
            }
        }
        return CGPoint(x: 400, y: 300)
    }

    /// 사이드바의 공간 줄에 대화를 끌어 놓음: 없으면 그 공간에 추가, 다른 공간에 있으면 그 공간에도 놓는다
    func addNodes(_ ids: [String], toSpace sp: String) {
        var added = 0
        for id in ids where placed[sp]?[id] == nil {
            if isInGraph(id) {
                alsoShow([id], in: sp)
            } else if let s = sessionIndex[id] {
                insertNode(id, path: s.path, cwd: s.cwd, in: sp, at: freeSpot(in: sp))
                reloadGraph()
            } else { continue }
            added += 1
        }
        reloadGraph()
        notice = added > 0 ? String(localized: "«\(spaceName(sp))» 공간에 넣었어요")
                           : String(localized: "이미 «\(spaceName(sp))» 공간에 있어요")
    }

    // MARK: 터미널 알림 (훅·ctxgraph notify 가 term_events 에 넣음)

    struct TermEventRow { let id: Int; let tab: String; let kind: String; let message: String?; let at: Double }

    func termEvents(after id: Int) -> [TermEventRow] {
        var out: [TermEventRow] = []
        db?.query("SELECT id, tab, kind, message, at FROM term_events WHERE id > ? ORDER BY id LIMIT 200", [id]) { r in
            if let t = r.text(1), let k = r.text(2) {
                out.append(TermEventRow(id: r.int(0), tab: t, kind: k, message: r.text(3), at: r.double(4) ?? 0))
            }
        }
        return out
    }

    func maxTermEventID() -> Int {
        var m = 0
        db?.query("SELECT COALESCE(MAX(id), 0) FROM term_events") { r in m = r.int(0) }
        return m
    }

    // MARK: 수정 범위 (파일 위치 목록)

    func reloadPlaces() {
        guard let db else { return }
        var ps: [Place] = []
        db.query("SELECT id, name, path FROM places ORDER BY sort, id") { r in
            if let p = r.text(2) { ps.append(Place(id: r.int(0), name: r.text(1) ?? "", path: p)) }
        }
        var np: [String: Set<Int>] = [:]
        db.query("SELECT session_id, place_id FROM node_places") { r in
            if let s = r.text(0) { np[s, default: []].insert(r.int(1)) }
        }
        if ps != places { places = ps }
        if np != nodePlaces { nodePlaces = np }
    }

    /// 목록에 폴더 추가 (이미 있으면 그 항목). 반환: 위치 id
    @discardableResult
    func addPlace(_ path: String) -> Int? {
        let p = (path as NSString).standardizingPath
        let sort = (places.map(\.id).max() ?? 0) + 1
        db?.query("INSERT OR IGNORE INTO places(name, path, sort, created_at) VALUES(?,?,?,?)",
                  [(p as NSString).lastPathComponent, p, sort, Date().timeIntervalSince1970])
        var id: Int?
        db?.query("SELECT id FROM places WHERE path=?", [p]) { r in id = r.int(0) }
        reloadPlaces()
        return id
    }

    func renamePlace(_ id: Int, _ name: String) {
        db?.query("UPDATE places SET name=? WHERE id=?", [name.trimmingCharacters(in: .whitespaces), id])
        reloadPlaces()
    }

    func removePlace(_ id: Int) {
        db?.query("DELETE FROM node_places WHERE place_id=?", [id])
        db?.query("DELETE FROM places WHERE id=?", [id])
        reloadPlaces()
    }

    /// 이 위치를 고른 대화 수
    func placeUsage(_ id: Int) -> Int { nodePlaces.values.filter { $0.contains(id) }.count }

    func setWriteLimited(_ sid: String, _ on: Bool) {
        db?.query("UPDATE nodes SET write_limited=? WHERE session_id=?", [on ? 1 : 0, sid])
        reloadGraph()
    }

    func setWriteStrict(_ sid: String, _ on: Bool) {
        db?.query("UPDATE nodes SET write_strict=? WHERE session_id=?", [on ? 1 : 0, sid])
        reloadGraph()
    }

    func setPlace(_ sid: String, _ placeID: Int, _ on: Bool) {
        if on {
            db?.query("INSERT OR IGNORE INTO node_places(session_id, place_id) VALUES(?,?)", [sid, placeID])
        } else {
            db?.query("DELETE FROM node_places WHERE session_id=? AND place_id=?", [sid, placeID])
        }
        reloadPlaces()
    }

    /// 이 대화가 고칠 수 있는 위치 (제한이 없으면 nil)
    func scope(_ sid: String) -> [Place]? {
        guard node(sid)?.writeLimited == true else { return nil }
        let ids = nodePlaces[sid] ?? []
        return places.filter { ids.contains($0.id) }
    }

    /// ctxgraph.py sandbox_key 와 같은 규칙: none | p:정렬된 위치 id (엄격 모드일 때만).
    /// 실행 중인 터미널에 적용된 값과 다르면 다시 열어야 셸 명령에 적용된다.
    func sandboxKey(_ sid: String) -> String {
        guard node(sid)?.writeStrict == true, let sc = scope(sid) else { return "none" }
        return "p:" + sc.map(\.id).sorted().map(String.init).joined(separator: ",")
    }

    /// 그래프에서 빼기. 다른 공간에도 놓여 있으면 지금 공간에서만 뺀다 (연결·요약은 그대로).
    func removeNode(_ id: String) {
        let others = alsoIn(id)
        if isHere(id), !others.isEmpty {
            db?.query("DELETE FROM placements WHERE session_id=? AND space=?", [id, space])
            if selection == .node(id) { selection = nil }
            reloadGraph()
            notice = String(localized: "이 공간에서만 뺐어요 — \(others.map { "«\($0)»" }.joined(separator: ", ")) 공간에는 그대로 있어요")
            return
        }
        db?.query("DELETE FROM placements WHERE session_id=?", [id])
        db?.query("DELETE FROM links WHERE src=? OR dst=?", [id, id])
        db?.query("DELETE FROM node_places WHERE session_id=?", [id])
        db?.query("DELETE FROM injections WHERE target=? OR source=?", [id, id])
        db?.query("DELETE FROM nodes WHERE session_id=?", [id])
        if selection == .node(id) { selection = nil }
        reloadGraph()
    }

    /// src → dst: src 의 맥락을 dst 에 넣는다. 반대 방향이 이미 있으면 양방향이 된다.
    func link(_ src: String, _ dst: String, select: Bool = true) {
        guard src != dst else { return }
        db?.query("INSERT OR IGNORE INTO links(src, dst, created_at) VALUES(?,?,?)",
                  [src, dst, Date().timeIntervalSince1970])
        reloadGraph()
        if select { selection = .edge(Link(src: src, dst: dst).id) }
        ensureSummary(src)
    }

    /// 화살표 끝을 다른 노드로 옮긴다 (꼬리 = 맥락을 보내는 쪽, 머리 = 받는 쪽)
    func rewire(_ l: Link, src: String, dst: String) {
        guard src != dst, src != l.src || dst != l.dst else { return }
        db?.query("DELETE FROM links WHERE src=? AND dst=?", [l.src, l.dst])
        db?.query("INSERT OR IGNORE INTO links(src, dst, created_at) VALUES(?,?,?)",
                  [src, dst, Date().timeIntervalSince1970])
        reloadGraph()
        selection = .edge(Link(src: src, dst: dst).id)
        ensureSummary(src)
    }

    /// 두 노드 사이 방향을 통째로 정한다 (from 기준).
    func setDirection(from: String, to: String, _ dir: FlowDirection) {
        let now = Date().timeIntervalSince1970
        db?.query("DELETE FROM links WHERE (src=? AND dst=?) OR (src=? AND dst=?)", [from, to, to, from])
        if dir != .backward {
            db?.query("INSERT INTO links(src, dst, created_at) VALUES(?,?,?)", [from, to, now])
            ensureSummary(from)
        }
        if dir != .forward {
            db?.query("INSERT INTO links(src, dst, created_at) VALUES(?,?,?)", [to, from, now])
            ensureSummary(to)
        }
        reloadGraph()
    }

    /// 체크 목록·메뉴용: 켜면 연결, 끄면 그 방향만 끊기
    func setLinked(_ src: String, _ dst: String, _ on: Bool) {
        if on { link(src, dst, select: false) } else { unlink(src, dst) }
    }

    func unlink(_ src: String, _ dst: String) {
        db?.query("DELETE FROM links WHERE src=? AND dst=?", [src, dst])
        reloadGraph()
    }

    func unlink(_ p: EdgePair) {
        db?.query("DELETE FROM links WHERE (src=? AND dst=?) OR (src=? AND dst=?)", [p.a, p.b, p.b, p.a])
        if selection == .edge(p.id) { selection = nil }
        reloadGraph()
    }

    /// 맥락을 보내는 쪽은 요약이 있어야 한다. 기록이 아직 없는 새 대화는 첫 턴 뒤 Stop 훅이 요약.
    private func ensureSummary(_ id: String) {
        guard session(id) != nil, let n = node(id), n.version == 0, !isBusy(id) else { return }
        summarize(id, force: false)
    }

    /// 대화 이름 붙이기 (그래프에 없는 대화도). 비우거나 Claude Code 의 이름과 같으면 지운다 → Claude Code 의 이름을 따라감
    func setLabel(_ id: String, _ label: String) {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == sessionIndex[id]?.title {
            db?.query("DELETE FROM labels WHERE session_id=?", [id])
        } else {
            db?.query("INSERT OR REPLACE INTO labels(session_id, label, set_at) VALUES(?,?,?)",
                      [id, t, Date().timeIntervalSince1970])
        }
        reloadGraph()
    }

    func deleteSelection() {
        switch selection {
        case .node(let id): removeNode(id)
        case .edge(let id):
            if let l = links.first(where: { $0.id == id }) { unlink(l.src, l.dst) }
            selection = nil
        case nil: break
        }
    }

    func summarize(_ id: String, force: Bool) {
        guard !launching.contains(id) else { return }
        launching.insert(id)
        Task {
            let r = await Python.run(["summarize", id] + (force ? ["--force"] : []))
            launching.remove(id)
            if r.status != 0 {
                notice = String(localized: "요약하지 못했어요: \(Fmt.oneLine(r.output, 200))")
            }
            reloadGraph()
        }
    }

    // MARK: 터미널

    func resumeCommand(_ id: String) -> String {
        let cwd = node(id)?.cwd ?? sessionIndex[id]?.cwd ?? Paths.home
        return "cd \(Fmt.shellQuote(cwd)) && claude\(skipPermissions ? " --dangerously-skip-permissions" : "") --resume \(id)"
    }

    func copyResumeCommand(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resumeCommand(id), forType: .string)
        notice = String(localized: "이어하기 명령을 복사했어요")
    }

    func resumeInTerminal(_ id: String) {
        let cmd = resumeCommand(id)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if err != nil {
            copyResumeCommand(id)
            notice = String(localized: "터미널을 열지 못해 이어하기 명령을 복사했어요")
        }
    }
}
