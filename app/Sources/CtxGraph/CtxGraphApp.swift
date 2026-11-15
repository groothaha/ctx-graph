import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var terminals: TerminalManager?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private var testMonitor: Any?
    private var testDownView: NSView?

    /// 시험 전용 (CTXGRAPH_TEST_EVENTS=1): 다른 프로세스가 이 앱에만 보낸 마우스 이벤트는 창 정보가 비어 있어
    /// AppKit 이 버린다. 그런 이벤트를 메인 창으로 다시 만들어 넘긴다. CTXGRAPH_OFFSCREEN=1 이면 창을 화면 밖에 둔다.
    func applicationDidFinishLaunching(_ notification: Notification) {
        ListDrag.shared.install()
        let env = ProcessInfo.processInfo.environment
        guard env["CTXGRAPH_TEST_EVENTS"] != nil else { return }
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .mouseMoved]
        testMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { e in
            guard e.window == nil,
                  let w = NSApp.windows.first(where: { $0.title == "CtxGraph" && $0.isVisible }),
                  w.frame.contains(e.locationInWindow) else { return e }
            let wp = w.convertPoint(fromScreen: e.locationInWindow)
            guard let ne = NSEvent.mouseEvent(with: e.type, location: wp, modifierFlags: e.modifierFlags,
                                              timestamp: e.timestamp, windowNumber: w.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: max(e.clickCount, 1),
                                              pressure: e.pressure) else { return e }
            // 대화 줄 끌기·더블클릭 (평소엔 ListDrag 의 모니터가 창 이벤트로 처리)
            if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(e.type), ListDrag.shared.handle(ne, wp, w) {
                return nil
            }
            // 왼쪽 버튼: 창이 키 창이 아니면 첫 클릭을 버리므로, 눌린 뷰에 직접 전달 (앱을 앞으로 가져오지 않음)
            switch e.type {
            case .leftMouseDown:
                self.testDownView = w.contentView?.hitTest(wp)
                self.testDownView?.mouseDown(with: ne)
                return nil
            case .leftMouseDragged:
                self.testDownView?.mouseDragged(with: ne)
                return nil
            case .leftMouseUp:
                self.testDownView?.mouseUp(with: ne)
                self.testDownView = nil
                return nil
            default:
                return ne
            }
        }
        if env["CTXGRAPH_OFFSCREEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let w = NSApp.windows.first(where: { $0.title == "CtxGraph" })
                w?.setFrameOrigin(NSPoint(x: -4200, y: 60))
                // 데모 녹화: CTXGRAPH_WINDOW_SIZE=1160x720 (창 내용 크기, pt)
                if let s = env["CTXGRAPH_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), s.count == 2 {
                    w?.setContentSize(NSSize(width: s[0], height: s[1]))
                }
                w?.alphaValue = 0          // macOS 가 화면 가장자리로 끌어와도 안 보이게 (점검은 앱 안 스냅샷으로)
            }
        }
    }

    /// 앱을 꺼도 터미널의 Claude 는 계속 돈다 (다시 켜면 그 탭에 다시 붙음). 끝내려면 탭을 닫는다.
    func applicationWillTerminate(_ notification: Notification) {
        terminals?.detachAll()
    }
}

@main
struct CtxGraphApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = GraphStore()
    @StateObject private var terms = TerminalManager()

    var body: some Scene {
        Window("CtxGraph", id: "graph-terminal") {
            ContentView()
                .environmentObject(store)
                .environmentObject(terms)
                .frame(minWidth: 1080, minHeight: 640)
                .onAppear {
                    terms.store = store
                    store.terminals = terms
                    delegate.terminals = terms
                    terms.restore()
                }
        }
        .defaultSize(width: 1920, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 대화") { terms.openNew() }
                    .keyboardShortcut("t")
            }
            CommandMenu("그래프") {
                Button("대화 목록 새로고침") { Task { await store.rescan() } }
                    .keyboardShortcut("r")
                Button("선택 항목 삭제") { store.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.selection == nil)
                Divider()
                // ⌘= ⌘- ⌘0 은 터미널 글자 크기라 ⌥ 를 더한다
                Button("확대") { CanvasViewport.shared.step(1) }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                Button("축소") { CanvasViewport.shared.step(-1) }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                Button("100%로") { CanvasViewport.shared.setZoom(1) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("노드 전부 보기") { CanvasViewport.shared.fit() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandMenu("작업 공간") {
                Button("새 작업 공간…") { SpaceActions.create(store) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("이름 바꾸기…") { SpaceActions.rename(store, store.space) }
                Divider()
                ForEach(Array(store.spaces.enumerated()), id: \.element.id) { i, sp in
                    let b = Button { store.switchSpace(sp.id) } label: {
                        if sp.id == store.space { Label(sp.name, systemImage: "checkmark") } else { Text(sp.name) }
                    }
                    if i < 9 { b.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command) } else { b }
                }
                Divider()
                Button("다음 공간") { store.cycleSpace(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                    .disabled(store.spaces.count < 2)
                Button("이전 공간") { store.cycleSpace(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                    .disabled(store.spaces.count < 2)
                Divider()
                Button("이 공간 지우기…") { SpaceActions.delete(store, terms, store.space) }
                    .disabled(store.space == Space.main)
            }
            CommandMenu("터미널") {
                Menu("새 대화 (모델 고르기)") {
                    ModelButtons { terms.openNew(model: $0) }
                        .environmentObject(store)
                }
                Button("새 셸") { terms.openShell() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button(terms.paneVisible ? "터미널 칸 숨기기" : "터미널 칸 보기") { terms.paneVisible.toggle() }
                    .keyboardShortcut("j")
                Button("탭 닫기") { if let id = terms.activeID { terms.close(id) } }
                    .keyboardShortcut("w")
                    .disabled(terms.activeID == nil)
                Divider()
                Button("오른쪽으로 나누기") { terms.split(horizontal: true) }
                    .keyboardShortcut("d")
                Button("아래로 나누기") { terms.split(horizontal: false) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("패널 닫기 (탭은 뒤에서 계속)") { terms.closePane() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(!terms.multiPane)
                Button("다음 패널") { terms.cyclePane(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!terms.multiPane)
                Button("이전 패널") { terms.cyclePane(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!terms.multiPane)
                Divider()
                Button("이전 탭") { cycle(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("다음 탭") { cycle(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button(terms.vertical ? "가로 탭으로" : "세로 탭으로 (폴더·브랜치·포트·알림)") { terms.vertical.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                Button("최근 알림으로 이동") { terms.jumpToUnread() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("알림 모두 읽음") { terms.markAllRead() }
                    .disabled(terms.unreadCount == 0)
                Divider()
                Button("찾기…") { terms.find() }
                    .keyboardShortcut("f")
                    .disabled(terms.activeID == nil)
                Button("다음 찾기") { terms.findNext(true) }
                    .keyboardShortcut("g")
                    .disabled(terms.activeID == nil)
                Button("이전 찾기") { terms.findNext(false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(terms.activeID == nil)
                Divider()
                Button("글자 크게") { terms.setFontSize(terms.fontSize + 1) }
                    .keyboardShortcut("=")
                Button("글자 작게") { terms.setFontSize(terms.fontSize - 1) }
                    .keyboardShortcut("-")
                Button("글자 기본 크기") { terms.setFontSize(13) }
                    .keyboardShortcut("0")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(terms)
                .onAppear { store.reloadModels() }
        }
    }

    private func cycle(_ d: Int) {
        let list = terms.spaceTabs
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == terms.activeID } ?? 0
        let n = list.count
        terms.activate(list[((i + d) % n + n) % n].id)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager

    var body: some View {
        NavigationSplitView {
            SessionSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            HSplitView {
                GraphPane()
                    .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity)
                if terms.paneVisible {
                    TerminalPane()
                        .frame(minWidth: 520, idealWidth: 720, maxWidth: .infinity)
                }
            }
        }
        // 창 제목은 'CtxGraph' 그대로 (여러 곳이 제목으로 창을 찾음), 지금 공간은 부제목으로
        .navigationSubtitle(store.spaceName(store.space))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ModelButtons { terms.openNew(model: $0) }
                } label: {
                    Label("새 대화", systemImage: "square.and.pencil")
                } primaryAction: {
                    terms.openNew()
                }
                .help("새 대화 (⌘T) — 눌러서 모델 고르기")
                Button { terms.paneVisible.toggle() } label: {
                    Label("터미널 패널", systemImage: terms.paneVisible ? "rectangle.righthalf.inset.filled" : "rectangle.split.2x1")
                }
                .help(terms.paneVisible ? "터미널 패널 숨기기 (⌘J)" : "터미널 패널 보기 (⌘J)")
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                NoticeBar(text: notice) { store.notice = nil }
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.notice)
        .onAppear { store.start() }
        .task {
            // 화면 점검용: CTXGRAPH_OPEN_SETTINGS=1 이면 시작할 때 설정 창
            if ProcessInfo.processInfo.environment["CTXGRAPH_OPEN_SETTINGS"] != nil {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // 앱 메뉴의 ⌘, 항목을 그대로 실행 (SDK 14.2 에는 openSettings 가 없음)
                if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
                   let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        }
    }
}

/// 그래프 + (선택했을 때) 인스펙터. 인스펙터는 그래프 위에 떠 있어서 그래프·터미널 폭을 빼앗지 않는다.
struct GraphPane: View {
    @EnvironmentObject var store: GraphStore

    var body: some View {
        GeometryReader { geo in
            GraphCanvas()
                .overlay(alignment: .topTrailing) {
                    if store.selection != nil {
                        InspectorPanel()
                            .frame(width: min(320, geo.size.width - 24))
                            .frame(maxHeight: geo.size.height - 24)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(Color(nsColor: .windowBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor)))
                            .overlay(alignment: .topTrailing) {
                                Button { store.selection = nil } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .padding(6)
                                .keyboardShortcut(.cancelAction)
                                .help("닫기 (esc)")
                                .accessibilityLabel("인스펙터 닫기")
                            }
                            .padding(12)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
        }
        .animation(.easeOut(duration: 0.15), value: store.selection == nil)
    }
}

struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).lineLimit(2)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("닫기")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            dismiss()
        }
    }
}
