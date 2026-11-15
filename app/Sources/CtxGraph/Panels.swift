import SwiftUI

// MARK: 왼쪽 — 대화 목록

struct SessionSidebar: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    @State private var query = ""

    private var filtered: [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(store.sessions.prefix(400)) }
        return store.sessions.filter { s in
            [store.title(s.id), s.title, s.firstPrompt ?? "", s.lastPrompt ?? "", s.cwd ?? ""]
                .contains { $0.lowercased().contains(q) } || s.id.hasPrefix(q)
        }
    }

    /// 대화들이 가장 많이 쓰는 폴더 (줄에는 이것과 다를 때만 폴더를 보여 준다)
    private var usualCwd: String? {
        var count: [String: Int] = [:]
        for s in store.sessions.prefix(300) { if let c = s.cwd { count[c, default: 0] += 1 } }
        return count.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    var body: some View {
        let usual = usualCwd
        List {
            if query.isEmpty { SpaceSection() }
            Section {
                ForEach(filtered) { s in
                    let elsewhere = store.otherSpaceName(s.id)
                    SessionRow(session: s, title: store.title(s.id), inGraph: store.isHere(s.id), elsewhere: elsewhere,
                               folder: s.cwd != nil && s.cwd != usual ? Fmt.shortPath(s.cwd) : nil)
                        // 끌어 놓기·더블클릭은 ListDrag 가 이 표시로 줄을 찾아 처리 (List 가 첫 클릭을 가로채므로)
                        .background(RowMarker(kind: "session", id: s.id))
                        .contextMenu {
                            if let elsewhere {
                                Button("«\(elsewhere)» 공간에서 보기") { store.reveal(s.id) }
                                Button("이 공간에도 놓기") { store.alsoShow([s.id], in: store.space); store.reveal(s.id) }
                                if store.node(s.id)?.spaces.count == 1 {
                                    Button("이 공간으로 옮기기") { store.moveNodes([s.id], to: store.space) }
                                }
                            } else {
                                Button(store.isHere(s.id) ? "그래프에서 보기" : "그래프에 추가") { store.addNode(s.id) }
                            }
                            Button("그래프에 추가하고 터미널에서 열기") {
                                store.addNode(s.id)
                                terms.open(s.id)
                            }
                            let more = store.spaces.filter { $0.id != store.space && !store.isShown(s.id, in: $0.id) }
                            if !more.isEmpty {
                                Menu(store.isInGraph(s.id) ? "다른 공간에도 놓기" : "다른 공간에 추가") {
                                    ForEach(more) { sp in
                                        Button(sp.name) { store.addNodes([s.id], toSpace: sp.id) }
                                    }
                                }
                            }
                            Button("이름 바꾸기…") { NameActions.rename(store, s.id) }
                            Button("이어하기 명령 복사") { store.copyResumeCommand(s.id) }
                        }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(query.isEmpty ? "대화" : "검색 결과 \(filtered.count)개")
                    if store.scanning { ProgressView().controlSize(.mini) }
                }
                .help("끌어서 그래프에 놓거나, 더블클릭하면 그래프에 추가돼요")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "제목·내용·폴더 검색")
        .overlay {
            if store.sessions.isEmpty {
                if store.scanning {
                    ProgressView("대화 기록 읽는 중…")
                } else {
                    ContentUnavailableView("대화 기록이 없어요", systemImage: "tray")
                }
            }
        }
    }
}

/// 대화 한 줄: 제목이 주인공, 둘째 줄은 흐리게 (시간 · 턴 · 다른 폴더일 때만 폴더 · 다른 공간에 있으면 그 공간).
/// 앞의 점: 주황 = Claude 가 답하는 중, 빈 고리 = 열려 있음, 없음 = 닫힘
struct SessionRow: View {
    let session: SessionInfo
    var title: String? = nil      // 사용자가 붙인 이름이 있으면 그것 (없으면 Claude Code 의 제목)
    let inGraph: Bool             // 지금 공간 그래프에 있음
    var elsewhere: String? = nil  // 다른 공간 그래프에 있으면 그 공간 이름
    var folder: String? = nil     // 다른 대화들과 폴더가 다를 때만

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ActivityDot(status: session.liveStatus)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? session.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(([Fmt.ago(session.mtime), String(localized: "\(session.nPrompts)턴")] + [folder, elsewhere.map { "«\($0)»" }].compactMap { $0 })
                        .joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if inGraph {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("이 공간 그래프에 있음")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(elsewhere.map { "«\($0)» 공간 그래프에 있음" } ?? "")
    }
}

/// 대화 상태 점 (캔버스와 같은 말: 주황 = 활동 중)
struct ActivityDot: View {
    let status: String?

    var body: some View {
        Group {
            switch status {
            case "busy": Circle().fill(Ink.flow)
            case .some: Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.2)
            case .none: Color.clear
            }
        }
        .frame(width: 7, height: 7)
        .help(status == "busy" ? "Claude 가 답하는 중" : (status == nil ? "닫혀 있음" : "열려 있음 (대기)"))
    }
}

// MARK: 오른쪽 — 인스펙터

struct InspectorPanel: View {
    @EnvironmentObject var store: GraphStore

    var body: some View {
        switch store.selection {
        case .node(let id):
            if let n = store.node(id) { NodeInspector(node: n) }
        case .edge(let id):
            if let l = store.links.first(where: { $0.id == id }), let p = store.pair(l.src, l.dst) {
                EdgeInspector(link: l, pair: p)
            }
        case nil:
            ContentUnavailableView("선택한 항목 없음", systemImage: "cursorarrow.click",
                                   description: Text("노드나 연결선을 누르면 자세한 내용이 보여요."))
        }
    }
}

struct NodeInspector: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    let node: GraphNode
    @State private var labelDraft = ""
    @State private var labelShown = ""      // 칸에 처음 보여 준 이름 (이것과 같으면 손대지 않은 것)

    var body: some View {
        let s = store.session(node.id)
        let incoming = store.sources(node.id)
        let outgoing = store.targets(node.id)
        // 연결 후보: 지금 공간 먼저, 다른 공간 노드도 (맥락 주입은 공간과 상관없이 동작)
        let others = store.nodes.filter { $0.id != node.id } + store.allNodes.filter { !store.isHere($0.id) }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("이름", text: $labelDraft, prompt: Text(s?.title ?? String(node.id.prefix(8))))
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.trailing, 22)
                        .onSubmit { saveLabel() }
                    Text("이름을 바꾸면 그래프와 주입되는 요약 제목에 쓰여요 (Return 으로 저장)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("inspector.folder").foregroundStyle(.secondary)   // 설정 탭 이름과 키를 나눔 (영어는 단수)
                        Text(Fmt.shortPath(node.cwd ?? s?.cwd)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("마지막 활동").foregroundStyle(.secondary)
                        Text("\(Fmt.ago(s?.mtime)) · \(s?.nPrompts ?? 0)턴")
                    }
                    GridRow {
                        Text("상태").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ActivityDot(status: s?.liveStatus)
                            Text(liveText(s?.liveStatus))
                        }
                    }
                    GridRow {
                        Text("inspector.model").foregroundStyle(.secondary)   // 설정 탭 이름과 키를 나눔 (영어는 단수)
                        Menu {
                            ForEach(store.models) { m in
                                Button {
                                    if terms.hasTab(node.id) { terms.open(node.id, model: m.id) }
                                    else { store.setNodeModel(node.id, m.id == "claude" ? nil : m.id) }
                                } label: {
                                    let name = store.isReady(m) ? m.name : String(localized: "\(m.name) — 키 필요")
                                    if m.id == (node.modelID ?? "claude") { Label(name, systemImage: "checkmark") } else { Text(name) }
                                }
                                .disabled(!store.isReady(m))
                            }
                            Divider()
                            SettingsLink { Text("모델·API 키 설정…") }
                        } label: {
                            Text(store.model(node.modelID)?.name ?? String(localized: "Claude (구독 · 기본 모델)"))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("이 대화를 열 때 쓰는 모델. 열려 있으면 새 모델로 다시 열어요")
                    }
                    GridRow {
                        Text("inspector.workspace").foregroundStyle(.secondary)   // 설정 탭 이름과 키를 나눔 (영어는 단수)
                        // 체크 = 그 공간에 놓여 있음. 같은 대화를 여러 공간에 둘 수 있다 (마지막 한 곳은 못 끔)
                        Menu {
                            ForEach(store.spaces) { sp in
                                let on = node.spaces.contains(sp.id)
                                Button {
                                    store.setShown(node.id, in: sp.id, !on)
                                } label: {
                                    if on { Label(sp.name, systemImage: "checkmark") } else { Text(sp.name) }
                                }
                                .disabled(on && node.spaces.count == 1)
                            }
                            Divider()
                            MoveToSpaceMenu(title: String(localized: "작업 공간으로 옮기기"), ids: [node.id])
                        } label: {
                            Text(node.spaces.map { store.spaceName($0) }.joined(separator: ", "))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("체크한 공간마다 이 대화가 보여요 (위치는 공간마다 따로, 맥락 연결은 하나). 옮기면 열린 터미널 탭도 같이 가요")
                    }
                    GridRow {
                        Text("세션").foregroundStyle(.secondary)
                        Text(node.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 12))

                HStack {
                    Button(terms.hasTab(node.id) ? "터미널 탭으로 가기" : "터미널에서 열기") { terms.open(node.id) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("오른쪽 터미널에서 이 대화를 이어서 써요 (노드 더블클릭, ⌘↩)")
                    Menu {
                        Menu("이 대화의 맥락을 받는 새 대화") {
                            ModelButtons { terms.openNew(linkTo: node.id, model: $0) }
                        }
                        Button("Terminal 앱에서 이어하기") { store.resumeInTerminal(node.id) }
                        Button("이어하기 명령 복사") { store.copyResumeCommand(node.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("더 보기")
                }

                Divider()

                LinkList(title: String(localized: "받는 맥락"), symbol: "arrow.down.left",
                         empty: String(localized: "이 대화로 들어오는 맥락이 없어요."),
                         ids: incoming,
                         candidates: others.map(\.id).filter { !incoming.contains($0) },
                         addLabel: String(localized: "받아올 대화 고르기…"),
                         onToggle: { store.setLinked($0, node.id, $1) },
                         onRemove: { store.unlink($0, node.id) })

                LinkList(title: String(localized: "보내는 곳"), symbol: "arrow.up.right",
                         empty: String(localized: "이 대화의 맥락을 받는 곳이 없어요."),
                         ids: outgoing,
                         candidates: others.map(\.id).filter { !outgoing.contains($0) },
                         addLabel: String(localized: "보낼 대화 고르기…"),
                         onToggle: { store.setLinked(node.id, $0, $1) },
                         onRemove: { store.unlink(node.id, $0) })

                if !incoming.isEmpty {
                    InjectionPreviewSection(node: node)
                }

                // 작업 폴더는 실험 기능 (켜 둔 대화에서는 늘 보임)
                if store.experimental || node.writeLimited || node.writeStrict {
                    Divider()
                    WriteScopeSection(node: node)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("요약").font(.headline)
                        Spacer()
                        Button("지금 요약") { store.summarize(node.id, force: true) }
                            .disabled(store.isBusy(node.id))
                    }
                    SummaryStatus(node: node, busy: store.isBusy(node.id)).font(.system(size: 12))
                    if let err = node.summaryError {
                        Text(err).font(.system(size: 11)).foregroundStyle(Ink.fail).textSelection(.enabled)
                    }
                    if let delta = node.delta, !delta.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("최근 변경").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Text(delta).font(.system(size: 12)).textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                    }
                    if let summary = node.summary {
                        Text(summary)
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    } else {
                        Text("아직 요약이 없어요. 이 대화의 맥락을 다른 대화로 보내면 자동으로 만들어져요.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Button(store.alsoIn(node.id).isEmpty ? "그래프에서 빼기" : "이 공간에서 빼기", role: .destructive) { store.removeNode(node.id) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: node.id, initial: true) { labelDraft = store.title(node.id); labelShown = labelDraft }
        .onChange(of: store.title(node.id)) { _, new in      // 고치는 중이 아니면 바뀐 제목을 따라간다
            if labelDraft == labelShown { labelDraft = new; labelShown = new }
        }
        .onDisappear { saveLabel() }
    }

    /// 사용자가 고쳤을 때만 저장 (그대로 닫으면 '새 대화' 같은 임시 제목이 이름으로 굳지 않게).
    /// 비우거나 Claude Code 의 이름과 같으면 setLabel 이 이름을 지운다.
    private func saveLabel() {
        guard labelDraft != labelShown else { return }
        store.setLabel(node.id, labelDraft)
        labelShown = labelDraft
    }

    private func liveText(_ s: String?) -> String {
        switch s {
        case "busy": return String(localized: "작업 중")
        case .some: return String(localized: "열려 있음 (대기)")
        case .none: return String(localized: "닫혀 있음")
        }
    }
}

/// 이 대화의 작업 폴더 (정리용): 파일을 만들고 고치는 곳을 설정의 '폴더' 목록에서 고른다
struct WriteScopeSection: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    let node: GraphNode

    var body: some View {
        let chosen = store.nodePlaces[node.id] ?? []
        let cwd = node.cwd ?? store.session(node.id)?.cwd
        VStack(alignment: .leading, spacing: 8) {
            Label("작업 폴더", systemImage: node.writeLimited ? "folder.fill" : "folder").font(.headline)
            Picker("작업 폴더", selection: Binding(get: { node.writeLimited },
                                               set: { store.setWriteLimited(node.id, $0) })) {
                Text("정하지 않음").tag(false)
                Text("고른 폴더에 모으기").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if node.writeLimited {
                if store.places.isEmpty {
                    Text("폴더 목록이 비어 있어요. 아래에서 추가하세요.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(store.places) { p in
                    Toggle(isOn: Binding(get: { chosen.contains(p.id) },
                                         set: { store.setPlace(node.id, p.id, $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title).font(.system(size: 12))
                            Text(Fmt.shortPath(p.path) + (p.exists ? "" : String(localized: " (없음)")))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(p.exists ? Color.secondary : Ink.fail)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                HStack(spacing: 10) {
                    Button("폴더 추가…") { addFolders(near: cwd) }
                    if let cwd, !store.places.contains(where: { $0.path == cwd }) {
                        Button("이 대화 폴더 추가") {
                            if let id = store.addPlace(cwd) { store.setPlace(node.id, id, true) }
                        }
                        .help(Fmt.shortPath(cwd))
                    }
                    Spacer(minLength: 0)
                    SettingsLink { Text("목록 관리") }.buttonStyle(.link)
                }
                .controlSize(.small)
                if chosen.isEmpty {
                    Label("폴더를 하나 이상 골라 주세요. 지금은 이 대화가 파일을 만들 곳이 없어요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Ink.fail)
                }
                Text("이 대화가 만들고 고치는 파일을 고른 폴더 안으로 모아요. Claude 에게 폴더를 알려 주고, 편집 도구로 밖에 파일을 만들려 하면 폴더 안에 다시 만들게 해요. 다른 곳은 읽기만 하고, 설치·캐시·임시 파일은 평소처럼 돼요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.experimental || node.writeStrict {
                Toggle(isOn: Binding(get: { node.writeStrict }, set: { store.setWriteStrict(node.id, $0) })) {
                    Text("셸 명령도 엄격하게 막기").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .help("앱 터미널에서 Claude 를 운영체제 샌드박스로 감싸 셸 명령으로도 폴더 밖에 못 쓰게 해요. 패키지 설치처럼 밖에 쓰는 명령도 막혀요. 다시 열어야 적용")
                }
            }
            if terms.scopeStale(node.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("열려 있는 터미널은 이전 설정으로 실행 중이에요. 셸 명령 막기를 적용하려면 다시 열어야 해요 (대화는 이어져요).",
                          systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("지금 다시 열기") { terms.reopenForScope(node.id) }
                        .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func addFolders(near dir: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "추가")
        panel.message = String(localized: "이 대화의 파일을 모아 둘 폴더를 고르세요")
        if let dir { panel.directoryURL = URL(fileURLWithPath: dir) }
        guard panel.runModal() == .OK else { return }
        for u in panel.urls {
            if let id = store.addPlace(u.path) { store.setPlace(node.id, id, true) }
        }
    }
}

/// 노드 인스펙터의 '받는 맥락' / '보내는 곳' 목록
struct LinkList: View {
    @EnvironmentObject var store: GraphStore
    let title: String
    let symbol: String
    let empty: String
    let ids: [String]
    let candidates: [String]
    let addLabel: String
    let onToggle: (String, Bool) -> Void
    let onRemove: (String) -> Void
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            if ids.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(ids, id: \.self) { m in
                HStack(spacing: 6) {
                    Button(store.title(m)) { store.reveal(m) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                    if let sp = store.otherSpaceName(m) {
                        Text(sp)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .help("다른 작업 공간 «\(sp)» 의 대화 — 누르면 그 공간으로 가요")
                    }
                    Spacer(minLength: 4)
                    Button { onRemove(m) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("이 방향 연결 끊기")
                    .accessibilityLabel("이 방향 연결 끊기")
                }
                .font(.system(size: 12))
            }
            Button(addLabel) { picking = true }
                .disabled(candidates.isEmpty && ids.isEmpty)
                .popover(isPresented: $picking, arrowEdge: .leading) {
                    LinkPicker(title: title, selected: Set(ids), all: (ids + candidates), onToggle: onToggle)
                        .environmentObject(store)
                }
        }
    }
}

/// 여러 대화를 한 번에 체크해서 연결
struct LinkPicker: View {
    @EnvironmentObject var store: GraphStore
    let title: String
    let selected: Set<String>
    let all: [String]
    let onToggle: (String, Bool) -> Void
    @State private var query = ""

    var body: some View {
        let q = query.lowercased()
        let shown = all.filter { q.isEmpty || store.title($0).lowercased().contains(q) }
            .sorted { (store.isHere($0) ? 0 : 1, store.title($0)) < (store.isHere($1) ? 0 : 1, store.title($1)) }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextField("검색", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(shown, id: \.self) { m in
                    Toggle(isOn: Binding(get: { selected.contains(m) }, set: { onToggle(m, $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.title(m)).lineLimit(1)
                            Text((store.otherSpaceName(m).map { String(localized: "«\($0)» 공간 · ") } ?? "") + Fmt.shortPath(store.node(m)?.cwd))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 160, maxHeight: 320)
            Text("체크한 대화가 바로 연결돼요").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct EdgeInspector: View {
    @EnvironmentObject var store: GraphStore
    let link: Link
    let pair: EdgePair

    var body: some View {
        let a = store.title(pair.a), b = store.title(pair.b)
        let dir = pair.direction(from: pair.a)
        VStack(alignment: .leading, spacing: 14) {
            Text("맥락 흐름").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                endpoint(link.src)
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 2)
                    .accessibilityLabel("맥락이 아래로 흐름")
                endpoint(link.dst)
            }
            Text("화살표 양끝의 동그라미를 끌어 다른 노드에 붙이면 보내는 쪽·받는 쪽을 바꿀 수 있어요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("방향", selection: Binding(
                get: { dir },
                set: { store.setDirection(from: pair.a, to: pair.b, $0) })) {
                Text("\(Fmt.oneLine(a, 18)) → \(Fmt.oneLine(b, 18))").tag(FlowDirection.forward)
                Text("\(Fmt.oneLine(b, 18)) → \(Fmt.oneLine(a, 18))").tag(FlowDirection.backward)
                Text("양방향 (서로 공유)").tag(FlowDirection.both)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(explain(dir, a, b))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 어디까지 전달됐는지 (① 보내는 쪽 대화 ② 요약 ③ 받는 쪽)
            VStack(alignment: .leading, spacing: 8) {
                Text("전달 상태").font(.system(size: 12, weight: .semibold))
                FlowSteps(link: link)
                if store.links.contains(link.reversed) { FlowSteps(link: link.reversed) }
            }
            HStack {
                Button("이 화살표 끊기", role: .destructive) { store.unlink(link.src, link.dst) }
                if pair.both {
                    Button("양쪽 다 끊기", role: .destructive) { store.unlink(pair) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func explain(_ d: FlowDirection, _ a: String, _ b: String) -> String {
        let tail = String(localized: "메시지를 보낼 때마다 최신 요약이 들어가요 (처음엔 전체, 그 뒤엔 바뀐 부분만).")
        switch d {
        case .forward: return String(localized: "«\(b)» 에서 «\(a)» 의 맥락을 받아요. \(tail)")
        case .backward: return String(localized: "«\(a)» 에서 «\(b)» 의 맥락을 받아요. \(tail)")
        case .both: return String(localized: "두 대화가 서로의 맥락을 받아요. \(tail)")
        }
    }

    private func endpoint(_ id: String) -> some View {
        Button(store.title(id)) { store.reveal(id) }
            .buttonStyle(.link)
            .lineLimit(2)
    }
}

/// 대화 이름 바꾸기 (카드·사이드바·터미널 탭 메뉴가 같이 씀)
@MainActor
enum NameActions {
    static func rename(_ store: GraphStore, _ id: String) {
        let auto = store.session(id)?.title
        let alert = NSAlert()
        alert.messageText = String(localized: "대화 이름")
        alert.informativeText = String(localized: "그래프·대화 목록·터미널 탭, 그리고 다른 대화로 보내는 요약의 제목에 쓰여요. 비우면 Claude Code 가 붙인 이름으로 돌아가요.")
            + (auto.map { "\n\n" + String(localized: "Claude Code 의 이름: \($0)") } ?? "")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let shown = store.title(id)
        field.stringValue = shown
        field.placeholderString = auto
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "바꾸기"))
        alert.addButton(withTitle: String(localized: "취소"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != shown else { return }        // 그대로면 저장 안 함 ('새 대화' 같은 임시 제목이 굳지 않게)
        store.setLabel(id, t)
    }
}
