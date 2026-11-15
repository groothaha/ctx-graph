import AppKit
import SwiftTerm
import SwiftUI

// MARK: - 터미널 칸: 탭 줄(또는 세로 탭) + 분할 패널

private let terminalBackground = NSColor(name: nil) { a in
    a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.105, green: 0.11, blue: 0.125, alpha: 1)
        : NSColor(srgbRed: 0.985, green: 0.983, blue: 0.976, alpha: 1)
}

/// 알림 테두리 색 (cmux 처럼 파란색)

struct TerminalPane: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            Divider()
            HStack(spacing: 0) {
                if terms.vertical && !terms.spaceTabs.isEmpty {
                    VerticalTabs()
                        .frame(width: 236)
                    Divider()
                }
                ZStack {
                    Color(nsColor: terminalBackground)
                    if terms.spaceTabs.isEmpty {
                        ContentUnavailableView {
                            Label("열린 터미널 없음", systemImage: "terminal")
                        } description: {
                            Text("«\(store.spaceName(terms.space))» 공간에 열린 탭이 없어요. 그래프에서 노드를 더블클릭하면 그 대화를 여기서 이어서 써요. 일반 셸도 열 수 있어요.")
                        } actions: {
                            HStack {
                                Button("새 대화") { terms.openNew() }
                                Button("새 셸") { terms.openShell() }
                            }
                        }
                    } else {
                        PaneTreeView(node: terms.layout)
                            .id(terms.space)          // 공간을 바꾸면 패널을 새로 짠다
                    }
                }
            }
        }
        .frame(minWidth: 520)
    }
}

/// 분할 배치를 그대로 그린다 (HSplitView/VSplitView 를 겹쳐서)
struct PaneTreeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let id):
            AnyView(PaneView(paneID: id))
        case .split(let horizontal, let kids):
            if horizontal {
                AnyView(HSplitView {
                    ForEach(kids, id: \.key) { PaneTreeView(node: $0) }
                })
            } else {
                AnyView(VSplitView {
                    ForEach(kids, id: \.key) { PaneTreeView(node: $0) }
                })
            }
        }
    }
}

struct PaneView: View {
    @EnvironmentObject var terms: TerminalManager
    let paneID: String

    var body: some View {
        let tab = terms.paneTabs[paneID].flatMap { terms.tab($0) }
        Group {
            if let tab {
                PaneContent(tab: tab, paneID: paneID)
            } else {
                EmptyPaneCard(paneID: paneID)
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { terms.focusPane(paneID) })
    }
}

struct PaneContent: View {
    @EnvironmentObject var terms: TerminalManager
    @ObservedObject var tab: TermTab
    let paneID: String

    var body: some View {
        let focused = terms.focusedPane == paneID
        TabBody(tab: tab)
            .id(tab.id)
            .overlay {
                // 알림이 온 패널은 파란 테두리, 여러 패널일 때 지금 패널은 얇은 강조색 테두리
                if tab.unread {
                    Rectangle().strokeBorder(Ink.attention, lineWidth: 3)
                        .shadow(color: Ink.attention.opacity(0.6), radius: 6)
                        .allowsHitTesting(false)
                } else if focused && terms.multiPane {
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .opacity(terms.multiPane && !focused ? 0.94 : 1)
    }
}

/// 빈 패널: 새로 열거나 뒤에 있던 탭을 여기에
struct EmptyPaneCard: View {
    @EnvironmentObject var terms: TerminalManager
    let paneID: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed").font(.system(size: 24)).foregroundStyle(.secondary)
            Text("빈 패널").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 8) {
                Button("새 셸") { terms.focusPane(paneID); terms.openShell() }
                Button("새 대화") { terms.focusPane(paneID); terms.openNew() }
            }
            let hidden = terms.hiddenTabs
            if !hidden.isEmpty {
                Menu("뒤에 있는 탭 보기") {
                    ForEach(hidden) { t in
                        Button(terms.title(t.id)) { terms.show(t.id, in: paneID) }
                    }
                }
                .fixedSize()
            }
            if terms.multiPane {
                Button("패널 닫기") { terms.closePane(paneID) }.buttonStyle(.link)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 탭의 터미널 NSView 를 그대로 끼워 넣는다. 탭을 바꿔도 각 터미널(프로세스·스크롤백)은 살아 있다.
/// 분할 배치가 바뀌면 SwiftUI 가 새 상자를 만든 뒤 옛 상자를 한 번 더 갱신하고 없애는데, 옛 상자가 뷰를 도로
/// 가져가면 뷰가 함께 사라진다(빈 화면). 그래서 가장 최근에 만든 상자만 뷰의 주인이고, 주인만 뷰를 끼운다.
struct TerminalHost: NSViewRepresentable {
    let view: CtxTerminalView

    final class Coordinator {
        let token = UUID()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        view.hostToken = context.coordinator.token      // 새 상자가 주인
        mount(in: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        if view.hostToken == nil { view.hostToken = context.coordinator.token }
        if view.hostToken == context.coordinator.token, view.superview !== box { mount(in: box) }
    }

    static func dismantleNSView(_ box: NSView, coordinator: Coordinator) {
        for case let v as CtxTerminalView in box.subviews where v.hostToken == coordinator.token {
            v.hostToken = nil
        }
    }

    private func mount(in box: NSView) {
        box.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }
}

// MARK: - 탭 줄

struct TabStrip: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    @State private var showNotes = false

    var body: some View {
        HStack(spacing: 0) {
            if terms.vertical {
                Text("탭 \(terms.spaceTabs.count)개")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(terms.spaceTabs) { tab in
                            TabChip(tab: tab, title: terms.title(tab.id),
                                    focused: tab.id == terms.activeID,
                                    visible: terms.pane(of: tab.id) != nil,
                                    badge: tab.isShell || tab.modelID == "claude" ? nil : store.model(tab.modelID)?.short)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            Divider().frame(height: 18)
            HStack(spacing: 2) {
                Button { showNotes.toggle() } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: terms.unreadCount > 0 ? "bell.badge.fill" : "bell")
                            .foregroundStyle(terms.unreadCount > 0 ? Ink.attention : Color.secondary)
                            .frame(width: 26, height: 24)
                        if terms.unreadCount > 0 {
                            Text("\(terms.unreadCount)")
                                .font(.system(size: 9, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3.5)
                                .background(Capsule().fill(Ink.attention))
                                .offset(x: 2, y: -1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("알림 (⇧⌘U: 최근 알림으로 이동)")
                .accessibilityLabel("알림 \(terms.unreadCount)개")
                .popover(isPresented: $showNotes, arrowEdge: .bottom) { NotesPanel(dismiss: { showNotes = false }) }

                StripButton(symbol: "rectangle.split.2x1", help: String(localized: "오른쪽으로 나누기 (⌘D) · 아래로는 ⇧⌘D")) {
                    terms.split(horizontal: true)
                }
                StripButton(symbol: terms.vertical ? "sidebar.left" : "sidebar.squares.left",
                            help: terms.vertical ? String(localized: "가로 탭으로 (⌥⌘B)") : String(localized: "세로 탭: 폴더·브랜치·포트·알림 보기 (⌥⌘B)")) {
                    terms.vertical.toggle()
                }
                Menu {
                    Button("새 셸 · \(Fmt.shortPath(terms.currentDir(terms.activeID) ?? terms.defaultCwd))") {
                        terms.openShell()
                    }
                    Divider()
                    Section("새 대화 · \(Fmt.shortPath(terms.defaultCwd))") {
                        ModelButtons { terms.openNew(model: $0) }
                    }
                    if case .node(let id) = store.selection {
                        Menu("«\(Fmt.oneLine(store.title(id), 24))» 의 맥락을 받는 새 대화") {
                            ModelButtons { terms.openNew(linkTo: id, model: $0) }
                        }
                    }
                    Divider()
                    SettingsLink { Text("모델·API 키 설정…") }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .help("새 셸·새 대화")
                .accessibilityLabel("새 터미널")
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StripButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 상태 점 (사이드바·캔버스와 같은 말): 파랑 = 안 읽은 알림, 주황 = Claude 가 답하는 중,
/// 빈 고리 = 열려 있음(대기), 흐린 점 = 꺼짐, 회색 = 준비 중, 빨강 = 시작 못 함
struct TabDot: View {
    @EnvironmentObject var store: GraphStore
    @ObservedObject var tab: TermTab

    var body: some View {
        Group {
            if tab.unread {
                Circle().fill(Ink.attention).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Ink.attention.opacity(0.35), lineWidth: 3))
            } else {
                switch tab.state {
                case .running where !tab.isShell && store.session(tab.id)?.liveStatus == "busy":
                    Circle().fill(Ink.flow).frame(width: 7, height: 7)
                case .running:
                    Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.2).frame(width: 7, height: 7)
                case .exited, .dormant:
                    Circle().fill(Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                case .failed:
                    Circle().fill(Ink.fail).frame(width: 7, height: 7)
                default:
                    Circle().fill(Ink.pipe).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 8, height: 8)
    }
}

struct TabChip: View {
    @EnvironmentObject var terms: TerminalManager
    @ObservedObject var tab: TermTab
    let title: String
    let focused: Bool
    let visible: Bool
    let badge: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            TabDot(tab: tab)
            if tab.isShell {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 12, weight: focused ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
            if let badge {
                ModelBadge(text: badge)
            }
            Button { terms.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(focused || hovering ? 1 : 0)
            .help("탭 닫기")
            .accessibilityLabel("탭 닫기")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(alignment: .bottom) {
            if visible && terms.multiPane {
                Capsule().fill(focused ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { terms.show(tab.id) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(id: tab.id) }
        .help(tab.lastNote.map { String(localized: "최근 알림: ") + $0 } ?? title)
    }

    private var fill: Color {
        if tab.unread { return Ink.attention.opacity(0.16) }
        if focused { return Color.primary.opacity(0.09) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}

/// 탭 오른쪽 클릭 메뉴 (가로 탭·세로 탭 공통)
struct TabMenu: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    let id: String

    var body: some View {
        let tab = terms.tab(id)
        Button("이름 바꾸기…") { terms.rename(id) }
        if terms.pane(of: id) != terms.focusedPane {
            Button("오른쪽에 나눠서 보기") { terms.split(horizontal: true, tab: id) }
            Button("아래에 나눠서 보기") { terms.split(horizontal: false, tab: id) }
        }
        Button("이 폴더에서 새 셸") { terms.openShell(cwd: terms.currentDir(id)) }
        Divider()
        Button("Finder 에서 보기") { terms.revealInFinder(id) }
        Button("경로 복사") { terms.copyPath(id) }
        if tab?.isShell == false, store.isInGraph(id) {
            Button("그래프에서 선택") { store.reveal(id) }
        }
        if tab?.unread == true {
            Button("읽음으로 표시") { terms.markRead(id) }
        }
        Divider()
        if let s = tab?.state, s == .dormant || (s != .running && s != .checking && s != .launching) {
            Button("다시 열기") { terms.restart(id) }
        }
        Button("탭 닫기") { terms.close(id) }
    }
}

// MARK: - 세로 탭 (cmux 처럼 폴더·브랜치·포트·최근 알림)

struct VerticalTabs: View {
    @EnvironmentObject var terms: TerminalManager

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(terms.spaceTabs) { tab in
                        VTabRow(tab: tab)
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 10) {
                Button { terms.openShell() } label: { Label("셸", systemImage: "plus") }
                Button { terms.openNew() } label: { Label("대화", systemImage: "plus") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct VTabRow: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    @ObservedObject var tab: TermTab
    @State private var hovering = false

    var body: some View {
        let focused = terms.activeID == tab.id
        let visible = terms.pane(of: tab.id) != nil
        let inf = terms.info[tab.id]
        HStack(alignment: .top, spacing: 8) {
            TabDot(tab: tab).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if tab.isShell {
                        Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(terms.title(tab.id))
                        .font(.system(size: 12, weight: focused ? .semibold : .medium))
                        .lineLimit(1)
                    if !tab.isShell, tab.modelID != "claude", let s = store.model(tab.modelID)?.short {
                        ModelBadge(text: s)
                    }
                    Spacer(minLength: 0)
                    if hovering {
                        Button { terms.close(tab.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("탭 닫기")
                        .accessibilityLabel("탭 닫기")
                    }
                }
                HStack(spacing: 4) {
                    Text(Fmt.shortPath(terms.currentDir(tab.id)))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let b = inf?.branch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(b).lineLimit(1)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                if let ports = inf?.ports, !ports.isEmpty {
                    Text(ports.prefix(6).map { ":\($0)" }.joined(separator: " "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .systemTeal))
                        .lineLimit(1)
                        .help("이 탭에서 열린 포트")
                }
                if let note = tab.lastNote {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(tab.unread ? Ink.attention : Color.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(
            tab.unread ? Ink.attention.opacity(0.14)
                : focused ? Color.primary.opacity(0.10)
                : visible ? Color.primary.opacity(0.045)
                : hovering ? Color.primary.opacity(0.04) : .clear))
        .overlay(alignment: .leading) {
            if tab.unread {
                Capsule().fill(Ink.attention).frame(width: 3).padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { terms.show(tab.id) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(id: tab.id) }
    }
}

// MARK: - 알림 목록

struct NotesPanel: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("알림").font(.headline)
                Spacer()
                Button("모두 읽음") { terms.markAllRead() }
                    .disabled(terms.unreadCount == 0)
                    .controlSize(.small)
            }
            .padding(12)
            Divider()
            if terms.notes.isEmpty {
                Text("아직 알림이 없어요. Claude 가 응답을 마치거나 입력을 기다리면 여기 쌓이고, 그 탭에 파란 테두리가 생겨요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(terms.notes) { n in
                            Button {
                                terms.show(n.tab)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(n.read ? Color.clear : Ink.attention)
                                        .overlay(Circle().strokeBorder(n.read ? Color.secondary.opacity(0.4) : .clear))
                                        .frame(width: 7, height: 7)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(n.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                            Text(kindLabel(n.kind)).font(.system(size: 10)).foregroundStyle(.secondary)
                                            if let sp = terms.tab(n.tab)?.space, sp != terms.space {
                                                Text(store.spaceName(sp))
                                                    .font(.system(size: 10))
                                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                                                    .help("다른 작업 공간의 탭 — 누르면 그 공간으로 가요")
                                            }
                                            Spacer()
                                            Text(Fmt.ago(n.at.timeIntervalSince1970))
                                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                        }
                                        Text(n.message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 27)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("앱이 뒤에 있을 때 macOS 알림", isOn: Binding(
                    get: { store.settings["sys_notify"] != "0" }, set: { terms.setSysNotify($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Text("셸에서 `ctxgraph notify 메시지` 로 직접 알릴 수 있어요 (예: 긴 작업 끝에 붙이기).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(width: 360)
    }

    private func kindLabel(_ k: String) -> String {
        switch k {
        case "input": return String(localized: "입력 대기")
        case "done": return String(localized: "응답 끝")
        default: return String(localized: "알림")
        }
    }
}

// MARK: - 탭 내용

struct TabBody: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    @ObservedObject var tab: TermTab

    var body: some View {
        VStack(spacing: 0) {
            ContextBar(id: tab.id)
            switch tab.state {
            case .checking:
                Spacer()
                ProgressView(tab.isShell ? "여는 중…" : "다른 터미널에서 열려 있는지 확인하는 중…").controlSize(.small)
                Spacer()
            case .moving:
                Spacer()
                ProgressView("다른 터미널의 대화를 닫고 여기로 옮기는 중…").controlSize(.small)
                Spacer()
            case .launching:
                Spacer()
                ProgressView("\(store.model(tab.modelID)?.name ?? tab.modelID) 로 여는 중…").controlSize(.small)
                Spacer()
            case .failed(let msg):
                FailedCard(id: tab.id, message: msg)
            case .elsewhere(_, let tty, let busy):
                ElsewhereCard(id: tab.id, tty: tty, busy: busy)
            case .dormant:
                DormantCard(id: tab.id, shell: tab.isShell)
            case .running, .exited:
                if let v = tab.view {
                    TerminalHost(view: v)
                        .overlay(alignment: .bottom) {
                            if case .exited(let code) = tab.state { ExitedBar(id: tab.id, code: code, shell: tab.isShell) }
                        }
                }
            }
        }
    }
}

/// 모델 목록 버튼 (키가 없는 API 모델은 비활성 + 이유)
struct ModelButtons: View {
    @EnvironmentObject var store: GraphStore
    let action: (String) -> Void

    var body: some View {
        ForEach(store.models) { m in
            Button(store.isReady(m) ? m.name : String(localized: "\(m.name) — 키 필요")) { action(m.id) }
                .disabled(!store.isReady(m))
        }
    }
}

struct ModelBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color.accentColor)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .lineLimit(1)
            .fixedSize()
    }
}

struct FailedCard: View {
    @EnvironmentObject var terms: TerminalManager
    let id: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("이 모델로 열 수 없어요")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                SettingsLink { Text("설정 열기") }
                    .keyboardShortcut(.defaultAction)
                Button("다시 시도") { terms.retry(id) }
                Button("Claude (구독) 로 열기") { terms.open(id, model: "claude") }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 탭 위의 한 줄: 폴더·브랜치·포트, (대화면) 모델·작업 폴더·주고받는 맥락
struct ContextBar: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    let id: String

    var body: some View {
        let t = terms.tab(id)
        let inf = terms.info[id]
        let shell = t?.isShell == true
        let incoming = shell ? [] : store.sources(id)
        let outgoing = shell ? [] : store.targets(id)
        HStack(spacing: 6) {
            if shell {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("셸").foregroundStyle(.secondary).fixedSize()
                Text("·").foregroundStyle(.tertiary)
            } else if let m = store.model(t?.modelID) {
                Text(m.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text("·").foregroundStyle(.tertiary)
            }
            Text(Fmt.shortPath(terms.currentDir(id) ?? store.node(id)?.cwd ?? store.session(id)?.cwd))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            if let b = inf?.branch {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(b).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            if let ports = inf?.ports, !ports.isEmpty {
                Text(ports.prefix(4).map { ":\($0)" }.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .systemTeal))
                    .fixedSize()
                    .help("이 탭에서 열린 포트")
            }
            if !shell, let sc = store.scope(id) {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "folder.fill").foregroundStyle(sc.isEmpty ? Ink.fail : Color.secondary)
                Text(sc.isEmpty ? String(localized: "작업 폴더 없음") : sc.map(\.title).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("이 대화의 파일은 이 폴더 안에 모아요")
            }
            if terms.scopeStale(id) {
                Button("엄격 모드 적용하려면 다시 열기") { terms.reopenForScope(id) }
                    .buttonStyle(.link)
                    .fixedSize()
                    .help("셸 명령 막기 설정을 바꾼 뒤예요. 다시 열면 적용돼요 (대화는 이어져요)")
            }
            if !incoming.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "arrow.down.left").foregroundStyle(Color.accentColor)
                IncomingFlows(target: id, sources: incoming)
            }
            if !outgoing.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                Text(String(localized: "보냄: ") + outgoing.map { store.title($0) }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .onTapGesture { if !shell, store.isInGraph(id) { store.reveal(id) } }
    }
}

struct ElsewhereCard: View {
    @EnvironmentObject var terms: TerminalManager
    let id: String
    let tty: String?
    let busy: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("이 대화는 다른 터미널에서 열려 있어요")
                .font(.system(size: 15, weight: .semibold))
            Text(busy
                 ? "지금 작업 중이라 옮길 수 없어요. 작업이 끝나면 다시 확인해 주세요."
                 : "여기로 옮기면 그쪽 Claude 를 닫고 같은 대화를 여기서 이어서 열어요. 대화 기록은 그대로예요.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("여기로 옮기기") { terms.moveHere(id) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                Button("그 창 보기") { terms.showElsewhere(id) }
                    .disabled(tty == nil)
                Button("다시 확인") { terms.recheck(id) }
            }
            if let tty {
                Text(tty).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 복원한 탭인데 프로세스가 꺼져 있을 때 (컴퓨터를 다시 켰거나, 앱이 꺼진 동안 끝남)
struct DormantCard: View {
    @EnvironmentObject var terms: TerminalManager
    let id: String
    var shell = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(shell ? "이 셸은 지금 꺼져 있어요" : "이 대화는 지금 꺼져 있어요")
                .font(.system(size: 15, weight: .semibold))
            Text(shell
                 ? "컴퓨터를 다시 켰거나 셸이 종료됐어요. 다시 열면 마지막 폴더에서 새 셸을 시작해요."
                 : "컴퓨터를 다시 켰거나 앱이 꺼져 있는 동안 Claude 가 종료됐어요. 이어서 열면 같은 대화를 다시 시작해요.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack(spacing: 10) {
                Button(shell ? "다시 열기" : "이어서 열기") { terms.restart(id) }
                    .keyboardShortcut(.defaultAction)
                Button("탭 닫기") { terms.close(id) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExitedBar: View {
    @EnvironmentObject var terms: TerminalManager
    let id: String
    let code: Int32?
    var shell = false

    var body: some View {
        HStack(spacing: 10) {
            Text((shell ? String(localized: "셸이 종료됐어요") : String(localized: "대화가 종료됐어요")) + (code.map { $0 != 0 ? String(localized: " (코드 \($0))") : "" } ?? ""))
                .font(.system(size: 12))
            Button("다시 열기") { terms.restart(id) }
            Button("탭 닫기") { terms.close(id) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.bottom, 14)
    }
}
