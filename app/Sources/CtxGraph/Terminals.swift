import AppKit
import SwiftTerm
typealias Color = SwiftUI.Color
import SwiftUI
import UserNotifications

/// 앱 안의 터미널 탭. Claude 대화(세션 ID 가 탭 ID) 또는 일반 셸("sh-…").
/// 각 탭의 프로세스는 ctxpty.py 보관자 안에서 돌아서 앱을 꺼도 살아 있다.
@MainActor
final class TermTab: ObservableObject, Identifiable {
    enum Kind: String { case claude, shell }
    enum State: Equatable {
        case checking
        case elsewhere(pid: Int32, tty: String?, busy: Bool)   // 다른 터미널(Terminal.app 등)에서 열려 있음
        case moving                                            // 그쪽을 닫고 여기로 옮기는 중
        case launching                                         // 모델 설정을 읽는 중
        case failed(String)                                    // 모델 키가 없는 등 시작 못 함
        case running
        case exited(Int32?)
        case dormant                                           // 복원한 탭인데 프로세스가 꺼져 있음 (재부팅 등)
    }

    let id: String
    let kind: Kind
    let cwd: String
    let isNew: Bool
    let modelID: String
    var space: String                       // 작업 공간 (옮기면 바뀜)
    @Published var state: State = .checking
    /// 이 Claude 를 띄울 때 적용한 샌드박스 (ctxgraph sandbox_key: none | p:1,2). 지금 설정과 다르면 다시 열어야 적용
    @Published var scope: String?
    @Published var customTitle: String?     // 사용자가 붙인 탭 이름
    @Published var osTitle: String?         // 셸이 OSC 로 알려 준 제목
    @Published var unread = false           // 안 본 알림 (파란 테두리)
    @Published var lastNote: String?        // 마지막 알림 내용 (세로 탭에 표시)
    var view: CtxTerminalView?

    var isShell: Bool { kind == .shell }

    init(id: String, kind: Kind = .claude, cwd: String, isNew: Bool = false, modelID: String = "claude",
         space: String = Space.main) {
        self.id = id
        self.kind = kind
        self.cwd = cwd
        self.isNew = isNew
        self.modelID = modelID
        self.space = space
    }
}

/// 탭마다 주기적으로 읽는 정보 (cmux 의 세로 탭처럼): 지금 폴더, git 브랜치, 열린 포트, 하위 프로세스 수
struct TabInfo: Equatable {
    var cwd: String?
    var branch: String?
    var ports: [Int]
    var procs: Int
}

/// 알림 목록 한 줄 (Claude 응답 끝·입력 대기·ctxgraph notify·OSC 777)
struct TermNote: Identifiable, Equatable {
    let id: Int
    let tab: String
    let kind: String          // done | input | notify
    let title: String
    let message: String
    let at: Date
    var read: Bool
}

/// 터미널 칸의 분할 배치. leaf = 패널 하나(패널 ID), split = 나란히(true: 왼|오, false: 위/아래)
indirect enum PaneNode: Codable, Equatable {
    case leaf(String)
    case split(Bool, [PaneNode])

    var key: String {
        switch self {
        case .leaf(let id): return id
        case .split(let h, let kids): return (h ? "h(" : "v(") + kids.map(\.key).joined(separator: ",") + ")"
        }
    }

    var leaves: [String] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let kids): return kids.flatMap(\.leaves)
        }
    }

    func splitting(_ target: String, new: String, horizontal: Bool) -> PaneNode {
        switch self {
        case .leaf(let id):
            return id == target ? .split(horizontal, [.leaf(id), .leaf(new)]) : self
        case .split(let h, let kids):
            if h == horizontal, let i = kids.firstIndex(of: .leaf(target)) {
                var k = kids
                k.insert(.leaf(new), at: i + 1)
                return .split(h, k)
            }
            return .split(h, kids.map { $0.splitting(target, new: new, horizontal: horizontal) })
        }
    }

    func removing(_ target: String) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let h, let kids):
            let k = kids.compactMap { $0.removing(target) }
            if k.isEmpty { return nil }
            return k.count == 1 ? k[0] : .split(h, k)
        }
    }
}

func dbg(_ s: String) {
    if ProcessInfo.processInfo.environment["CTXGRAPH_DEBUG"] != nil { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

/// SwiftTerm 터미널 뷰 + 포커스 추적(어느 패널을 쓰는 중인지), OSC 777 알림, 파일 끌어 놓기(경로 입력)
final class CtxTerminalView: LocalProcessTerminalView {
    /// 이 뷰를 끼우고 있는 TerminalHost (가장 최근 것만 주인)
    var hostToken: UUID?
    var onFocus: (() -> Void)?
    var onNotify: ((String, String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func notify(source: Terminal, title: String, body: String) {
        guard !replaying else { return }               // 다시 그린 기록 속의 지난 알림
        DispatchQueue.main.async { [weak self] in self?.onNotify?(title, body) }
    }

    // MARK: 다시 붙을 때 조용히
    /// 다시 붙으면 보관자가 최근 화면 기록(최대 4MB)을 한꺼번에 다시 보낸다. 그 안의 벨(BEL)·알림(OSC 777)은
    /// 지난 일이라 울리지 않는다: 붙은 뒤 기록이 몰려오는 동안(첫 데이터는 5초까지 기다리고, 그 뒤 0.6초 넘게
    /// 끊기면 끝, 길어야 15초)은 조용히. 평소에도 벨은 앱 전체에서 1초에 한 번만.
    private var replayStart: Date?
    private var gotData = false
    private var lastData = Date.distantPast
    private static var lastBell = Date.distantPast
    private static let muteForTests = ProcessInfo.processInfo.environment["CTXGRAPH_MUTE_BELL"] != nil

    func beginReplay() {
        replayStart = Date()
        gotData = false
        lastData = Date()
    }

    private var replaying: Bool {
        guard let s = replayStart else { return false }
        let now = Date()
        let gap = now.timeIntervalSince(lastData)
        if now.timeIntervalSince(s) > 15 || gap > (gotData ? 0.6 : 5) {
            replayStart = nil
            return false
        }
        return true
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        _ = replaying                                  // 끊겼으면 여기서 다시 그리기가 끝난 것으로
        gotData = true
        lastData = Date()
        super.dataReceived(slice: slice)
    }

    override func bell(source: Terminal) {
        let quiet = replaying
        let now = Date()
        let tooSoon = now.timeIntervalSince(Self.lastBell) < 1
        if Self.muteForTests {
            FileHandle.standardError.write(Data("bell \(quiet ? "replay" : tooSoon ? "rate" : "play")\n".utf8))
        }
        guard !quiet, !tooSoon else { return }
        Self.lastBell = now
        if !Self.muteForTests { super.bell(source: source) }
    }

    private func fileURLs(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        send(txt: urls.map { Self.escape($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// Terminal.app 처럼 공백·특수문자 앞에 \ 를 붙인다
    static func escape(_ p: String) -> String {
        let special = Set(" \t'\"\\()[]{}&;|<>*?$`!#~,=")
        return String(p.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }
}

/// 터미널 글꼴. D2Coding(앱에 들어 있음, SIL OFL 1.1)은 영문 한 칸 = 0.5em, 한글 = 1em 이라 한글이 정확히 두 칸을 채운다.
/// SF Mono 는 한글이 없어 대체 글꼴(Apple SD Gothic Neo)로 그려지는데, 두 칸(1.2em)보다 좁아 글자 사이가 벌어진다.
/// 기본: 한국어 화면이면 D2Coding, 아니면 SF Mono.
enum TermFont: String, CaseIterable, Identifiable {
    case d2coding, system
    var id: String { rawValue }

    static func current(_ settings: [String: String]) -> TermFont {
        TermFont(rawValue: settings["term_face"] ?? "") ?? (AppLang.code == "ko" && bundled ? .d2coding : .system)
    }

    func font(_ size: CGFloat) -> NSFont {
        if self == .d2coding, Self.bundled, let f = NSFont(name: "D2Coding", size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 앱의 Resources/Fonts 에 든 글꼴을 이 프로세스에 등록 (한 번)
    static let bundled: Bool = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        var ok = false
        for f in files where f.pathExtension.lowercased() == "ttf" {
            if CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) { ok = true }
        }
        return ok && NSFont(name: "D2Coding", size: 13) != nil
    }()
}

/// 앱 터미널 탭·분할 패널·알림. 앱을 다시 켜면 탭 목록과 분할 배치(tabs.json)를 복원해 다시 붙는다.
/// 프로세스를 끝내는 건 탭을 닫을 때뿐.
@MainActor
final class TerminalManager: NSObject, ObservableObject {
    @Published private(set) var tabs: [TermTab] = [] { didSet { save() } }
    @Published var paneVisible = false { didSet { save() } }    // 탭이 없으면 그래프가 넓게. 노드를 열면 나타난다
    @Published private(set) var layout: PaneNode = .leaf("p1") { didSet { save() } }
    @Published private(set) var paneTabs: [String: String] = [:] { didSet { save() } }   // 패널 ID → 탭 ID
    @Published private(set) var focusedPane = "p1" { didSet { save() } }
    @Published var vertical = false { didSet { save() } }       // 세로 탭 (폴더·브랜치·포트·알림 표시)
    @Published private(set) var info: [String: TabInfo] = [:]
    @Published private(set) var notes: [TermNote] = []
    @Published private(set) var fontSize: CGFloat = 13
    /// 지금 작업 공간. layout·paneTabs·focusedPane·paneVisible 은 이 공간 것이고, 다른 공간 것은 stash 에.
    /// 다른 공간의 탭도 tabs 에 그대로 있고 계속 돈다 (알림도 받음).
    @Published private(set) var space = Space.main
    private var stash: [String: SpaceLayout] = [:]

    weak var store: GraphStore?
    private var restoring = false
    private var restored = false
    private var quitting = false
    private var killing: [String: Task<Void, Never>] = [:]
    private var lastEventID = 0
    private var localNoteID = -1
    /// 새 터미널 뷰의 처음 크기 = 마지막으로 보인 터미널 크기 (다시 붙을 때 화면을 같은 크기로 다시 그리게)
    private var viewSize = CGSize(width: 800, height: 600)

    /// 새 대화·셸의 기본 폴더: 가장 최근에 쓴 대화의 폴더 (없으면 홈)
    var defaultCwd: String {
        let fm = FileManager.default
        return store?.sessions.lazy.compactMap(\.cwd).first { fm.fileExists(atPath: $0) } ?? Paths.home
    }

    // MARK: 조회

    /// 지금 쓰는 패널의 탭
    var activeID: String? { paneTabs[focusedPane] }
    var active: TermTab? { activeID.flatMap(tab) }
    func hasTab(_ id: String) -> Bool { tabs.contains { $0.id == id } }
    func tab(_ id: String) -> TermTab? { tabs.first { $0.id == id } }
    func pane(of id: String) -> String? { paneTabs.first { $0.value == id }?.key }
    /// 지금 공간의 탭 (탭 줄·세로 탭에 보이는 것)
    var spaceTabs: [TermTab] { tabs.filter { $0.space == space } }
    func tabs(in sp: String) -> [TermTab] { tabs.filter { $0.space == sp } }
    var runningCount: Int { spaceTabs.filter { $0.state == .running }.count }
    func runningCount(in sp: String) -> Int { tabs(in: sp).filter { $0.state == .running }.count }
    /// 모든 공간의 안 읽은 알림 (종 아이콘)
    var unreadCount: Int { tabs.filter(\.unread).count }
    func unreadCount(in sp: String) -> Int { tabs(in: sp).filter(\.unread).count }
    var multiPane: Bool { layout.leaves.count > 1 }
    /// 지금 공간에서 어느 패널에도 안 보이는 탭 (뒤에서 도는 탭)
    var hiddenTabs: [TermTab] { spaceTabs.filter { pane(of: $0.id) == nil } }

    func title(_ id: String) -> String {
        guard let t = tab(id) else { return store?.title(id) ?? String(id.prefix(8)) }
        if let c = t.customTitle, !c.isEmpty { return c }
        if t.isShell {
            if let o = t.osTitle, !o.isEmpty { return o }
            let dir = info[id]?.cwd ?? t.cwd
            return dir == Paths.home ? "~" : (dir as NSString).lastPathComponent
        }
        return store?.title(id) ?? String(id.prefix(8))
    }

    /// 이 탭이 지금 있는 폴더 (셸은 cd 를 따라감)
    func currentDir(_ id: String?) -> String? {
        guard let id, let t = tab(id) else { return nil }
        return info[id]?.cwd ?? t.cwd
    }

    /// 엄격 모드(셸 명령도 막기)를 바꿨는데 실행 중인 Claude 는 이전 설정으로 떠 있음 → 다시 열어야 적용.
    func scopeStale(_ id: String) -> Bool {
        guard let t = tab(id), !t.isShell, t.state == .running, let store else { return false }
        let applied = (t.scope == nil || t.scope == "all") ? "none" : t.scope!
        return applied != store.sandboxKey(id)
    }

    /// 범위 적용을 위해 다시 열기 (작업 중이면 확인)
    func reopenForScope(_ id: String) {
        if store?.session(id)?.liveStatus == "busy" {
            let alert = NSAlert()
            alert.messageText = String(localized: "작업 중인 대화를 다시 열까요?")
            alert.informativeText = String(localized: "Claude 가 아직 작업 중이에요. 다시 열면 지금 작업이 중단돼요. 대화 기록은 그대로 이어져요.")
            alert.addButton(withTitle: String(localized: "다시 열기"))
            alert.addButton(withTitle: String(localized: "취소"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        restart(id)
    }

    // MARK: 패널

    /// 탭을 보여 준다: 이미 어느 패널에 있으면 그 패널로, 아니면 지금 패널(또는 지정한 패널)에.
    func show(_ id: String, in target: String? = nil) {
        guard let t = tab(id) else { return }
        if t.space != space { goToSpace(t.space) }       // 다른 공간의 탭 (알림 누름 등) → 그 공간으로
        paneVisible = true
        let dest = target ?? focusedPane
        if let p = pane(of: id) {
            if target == nil || p == dest {
                focusedPane = p
            } else {
                // 다른 패널로 옮김: 원래 패널엔 대상 패널에 있던 탭이 간다 (맞바꾸기)
                let other = paneTabs[dest]
                paneTabs[p] = other
                paneTabs[dest] = id
                focusedPane = dest
            }
        } else {
            paneTabs[dest] = id
            focusedPane = dest
        }
        markSeen(id)
        focusActive()
    }

    func activate(_ id: String) { show(id) }

    func focusPane(_ p: String) {
        guard layout.leaves.contains(p) else { return }
        if focusedPane != p { focusedPane = p }
        markSeen(paneTabs[p])
    }

    /// 터미널을 클릭해 입력하기 시작하면 그 패널이 지금 패널
    private func focusedTerminal(_ id: String) {
        if let p = pane(of: id), p != focusedPane { focusedPane = p }
        markSeen(id)
    }

    func cyclePane(_ d: Int) {
        let ls = layout.leaves
        guard ls.count > 1, let i = ls.firstIndex(of: focusedPane) else { return }
        focusPane(ls[((i + d) % ls.count + ls.count) % ls.count])
        focusActive()
    }

    /// 지금 패널을 나눈다 (⌘D 오른쪽, ⇧⌘D 아래). 새 패널엔 그 탭을 보이거나, 없으면 같은 폴더에서 새 셸.
    func split(horizontal: Bool, tab id: String? = nil) {
        paneVisible = true
        if !layout.leaves.contains(focusedPane) { focusedPane = layout.leaves.first ?? "p1" }
        let new = "p" + String(UUID().uuidString.prefix(6)).lowercased()
        let dir = currentDir(activeID)
        layout = layout.splitting(focusedPane, new: new, horizontal: horizontal)
        focusedPane = new
        if let id, hasTab(id) {
            show(id, in: new)
        } else {
            openShell(cwd: dir)
        }
    }

    /// 패널만 닫는다 (탭은 뒤에서 계속 돎)
    func closePane(_ p: String? = nil) {
        let p = p ?? focusedPane
        let ls = layout.leaves
        guard ls.count > 1, let next = layout.removing(p) else { return }
        let i = ls.firstIndex(of: p) ?? 0
        paneTabs[p] = nil
        layout = next
        let nl = layout.leaves
        focusedPane = nl[min(i, nl.count - 1)]
        markSeen(activeID)
        focusActive()
    }

    // MARK: 작업 공간

    /// 그래프와 같이 바꾼다 (공간의 주인은 GraphStore)
    private func goToSpace(_ sp: String) {
        if let store { store.switchSpace(sp) } else { enter(sp) }
    }

    private static func newPaneID() -> String { "p" + String(UUID().uuidString.prefix(6)).lowercased() }

    /// 이 공간의 분할 배치로 바꾼다. 떠나는 공간의 탭은 화면에서만 빠지고 계속 돈다.
    func enter(_ sp: String) {
        guard sp != space else { return }
        guard restored else { space = sp; return }
        restoring = true                 // 바꾸는 동안 저장 한 번만
        stash[space] = SpaceLayout(layout: layout, paneTabs: paneTabs, focused: focusedPane, pane: paneVisible)
        space = sp
        let mine = Set(spaceTabs.map(\.id))
        let s = stash.removeValue(forKey: sp)
        let l = s?.layout ?? .leaf(Self.newPaneID())
        layout = l
        paneTabs = (s?.paneTabs ?? [:]).filter { l.leaves.contains($0.key) && mine.contains($0.value) }
        focusedPane = s.flatMap { l.leaves.contains($0.focused) ? $0.focused : nil } ?? l.leaves[0]
        if activeID == nil, let first = hiddenTabs.first { paneTabs[focusedPane] = first.id }
        paneVisible = !mine.isEmpty && (s?.pane ?? true)
        restoring = false
        save()
        markSeen(activeID)
        focusActive()
    }

    /// 대화를 다른 공간으로 옮길 때 그 터미널 탭도 같이 (프로세스는 그대로)
    func moveTabs(_ ids: [String], to target: String) {
        var moved = false
        for id in ids {
            guard let t = tab(id), t.space != target else { continue }
            if t.space == space {
                vacate(id)
            } else if var st = stash[t.space] {
                st.paneTabs = st.paneTabs.filter { $0.value != id }
                stash[t.space] = st
            }
            t.space = target
            moved = true
        }
        guard moved else { return }
        if spaceTabs.isEmpty { paneVisible = false }
        if activeID == nil, let first = hiddenTabs.first { paneTabs[focusedPane] = first.id }
        objectWillChange.send()
        save()
    }

    /// 공간을 지울 때: 그 공간의 탭을 전부 target 으로 (뒤에 있는 탭이 됨)
    func mergeSpace(_ sp: String, into target: String) {
        for t in tabs where t.space == sp { t.space = target }
        stash[sp] = nil
        if target == space, activeID == nil, let first = hiddenTabs.first {
            paneTabs[focusedPane] = first.id
            paneVisible = true
        }
        objectWillChange.send()
        save()
    }

    /// 이 탭을 보이던 패널(지금 공간)을 비운다: 뒤에 있던 탭을 대신 보이거나, 다른 패널이 있으면 패널을 닫는다
    private func vacate(_ id: String, near index: Int? = nil) {
        guard let p = pane(of: id) else { return }
        paneTabs[p] = nil
        let list = spaceTabs.filter { $0.id != id }
        let hidden = { (t: TermTab) in self.pane(of: t.id) == nil }
        let i = min(index ?? list.count, list.count)
        // 닫은 탭 자리 근처(오른쪽 먼저)의 뒤에 있던 탭
        if let next = list[i...].first(where: hidden) ?? list[..<i].last(where: hidden) {
            paneTabs[p] = next.id
        } else if multiPane {
            closePane(p)
        }
    }

    // MARK: 알림

    private func markSeen(_ id: String?) {
        guard let id, let t = tab(id) else { return }
        if t.unread {
            t.unread = false
            objectWillChange.send()
            save()
        }
        if notes.contains(where: { $0.tab == id && !$0.read }) {
            notes = notes.map { var n = $0; if n.tab == id { n.read = true }; return n }
        }
    }

    func isUnread(_ id: String) -> Bool { tab(id)?.unread == true }

    func markRead(_ id: String) { markSeen(id) }

    func markAllRead() {
        for t in tabs where t.unread { t.unread = false }
        notes = notes.map { var n = $0; n.read = true; return n }
        objectWillChange.send()
        save()
    }

    /// ⇧⌘U: 가장 최근에 알림이 온 안 읽은 탭으로
    func jumpToUnread() {
        if let n = notes.first(where: { !$0.read && hasTab($0.tab) }) {
            show(n.tab)
        } else if let t = tabs.first(where: \.unread) {
            show(t.id)
        } else {
            NSSound.beep()
        }
    }

    private var sysNotify: Bool { store?.settings["sys_notify"] != "0" }

    func setSysNotify(_ on: Bool) { store?.setSetting("sys_notify", on ? "1" : "0") }

    /// Claude 응답 끝(done)·입력 대기(input)·notify. 지금 보고 있는 탭이면 읽은 것으로, 아니면 파란 테두리 + (앱이 뒤에 있으면) macOS 알림.
    private func handleEvent(id eventID: Int?, tab id: String, kind: String, message: String, at: Date, quiet: Bool) {
        guard let t = tab(id) else { return }
        let seen = NSApp.isActive && paneVisible && activeID == id && NSApp.keyWindow != nil
        let title = title(id)
        let nid: Int
        if let eventID { nid = eventID } else { localNoteID -= 1; nid = localNoteID }
        t.lastNote = message
        notes.insert(TermNote(id: nid, tab: id, kind: kind, title: title, message: message, at: at, read: seen), at: 0)
        if notes.count > 100 { notes.removeLast(notes.count - 100) }
        if !seen {
            t.unread = true
            if !quiet && !NSApp.isActive && sysNotify { postSystemNotification(tab: id, title: title, kind: kind, body: message) }
        }
        objectWillChange.send()
        save()
    }

    private func postSystemNotification(tab id: String, title: String, kind: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.subtitle = kind == "input" ? String(localized: "입력을 기다려요") : (kind == "done" ? String(localized: "응답을 마쳤어요") : String(localized: "알림"))
            c.body = body
            c.sound = .default
            c.userInfo = ["tab": id]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    private func pollEvents(quiet: Bool) {
        guard let rows = store?.termEvents(after: lastEventID), !rows.isEmpty else { return }
        for r in rows {
            lastEventID = max(lastEventID, r.id)
            handleEvent(id: r.id, tab: r.tab, kind: r.kind, message: r.message ?? "", at: Date(timeIntervalSince1970: r.at), quiet: quiet)
        }
        save()
    }

    private func refreshInfo() async {
        guard paneVisible, tabs.contains(where: { $0.state == .running }) else { return }
        let rows = await PtyHost.info()
        var next: [String: TabInfo] = [:]
        for r in rows {
            guard let sid = r["session"] as? String else { continue }
            next[sid] = TabInfo(cwd: r["cwd"] as? String, branch: r["branch"] as? String,
                                ports: (r["ports"] as? [Int]) ?? [], procs: (r["procs"] as? Int) ?? 0)
        }
        if next != info { info = next }
    }

    private func startLoops() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                self.pollEvents(quiet: false)
                self.snapIfRequested()
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshInfo()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSeen(self?.activeID) }
        }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    /// 시험 전용 (CTXGRAPH_TEST_EVENTS): dataDir/snap-request 에 적힌 경로로 창을 PNG 로 (창이 화면 밖이어도)
    private func snapIfRequested() {
        guard ProcessInfo.processInfo.environment["CTXGRAPH_TEST_EVENTS"] != nil else { return }
        let act = Paths.dataDir + "/test-actions"
        if let spec = try? String(contentsOfFile: act, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: act)
            runTestActions(spec.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let req = Paths.dataDir + "/snap-request"
        guard let out = try? String(contentsOfFile: req, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: req)
        snapTo(out)
    }

    private func snapTo(_ out: String, title: String = "CtxGraph", scale fixed: CGFloat? = nil, async: Bool = false) {
        // 레이어째 그린다 (SwiftTerm 배경은 layer.backgroundColor 라 cacheDisplay 로는 하얗게 나옴)
        guard let w = NSApp.windows.first(where: { $0.title == title }),
              let v = w.contentView?.superview ?? w.contentView, let layer = v.layer else { return }
        let scale = fixed ?? w.backingScaleFactor, size = v.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped || v.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let url = URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
        let write = { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url) }
        // 녹화: PNG 만들기는 뒤에서 (화면 스레드가 막히면 애니메이션·갱신이 멈춘 채로 찍힌다)
        if async { DispatchQueue.global(qos: .utility).async { _ = write() } } else { _ = write() }
    }

    // MARK: 글자 크기·찾기

    func setFontSize(_ s: CGFloat) {
        let v = min(max(s, 9), 28)
        fontSize = v
        store?.setSetting("term_font", String(Int(v)))      // (이름과 달리 글자 크기)
        for t in tabs { t.view?.font = face.font(v) }
    }

    /// 터미널 글꼴 (설정 → 터미널)
    var face: TermFont { TermFont.current(store?.settings ?? [:]) }

    func setFace(_ f: TermFont) {
        store?.setSetting("term_face", f.rawValue)
        for t in tabs { t.view?.font = f.font(fontSize) }
        objectWillChange.send()
    }

    func find() {
        guard let tv = active?.view else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        tv.performFindPanelAction(item)
    }

    func findNext(_ forward: Bool) {
        guard let tv = active?.view else { return }
        let item = NSMenuItem()
        item.tag = Int((forward ? NSFindPanelAction.next : NSFindPanelAction.previous).rawValue)
        tv.performFindPanelAction(item)
    }

    // MARK: 이름·기타

    func rename(_ id: String) {
        guard let t = tab(id) else { return }
        if !t.isShell, let store {            // 대화 탭 = 대화 이름 (그래프·목록에도 같이)
            NameActions.rename(store, id)
            if t.customTitle != nil { t.customTitle = nil; save() }
            objectWillChange.send()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "탭 이름")
        alert.informativeText = String(localized: "비우면 지금 폴더 이름을 써요.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = title(id)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "바꾸기"))
        alert.addButton(withTitle: String(localized: "취소"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        t.customTitle = name.isEmpty ? nil : name
        save()
        objectWillChange.send()
    }

    func revealInFinder(_ id: String) {
        guard let d = currentDir(id) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: d)
    }

    func copyPath(_ id: String) {
        guard let d = currentDir(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d, forType: .string)
        store?.notice = String(localized: "경로 복사함: \(Fmt.shortPath(d))")
    }

    // MARK: 열기

    /// 노드 더블클릭: 이미 탭이 있으면 그 탭으로, 없으면 이 대화를 여기서 이어서 연다.
    /// model 을 주면 그 모델로 (이미 다른 모델로 열려 있으면 확인 후 다시 연다). 없으면 이 대화를 마지막으로 연 모델.
    func open(_ id: String, model: String? = nil, split: Bool? = nil) {
        dbg("open \(id.prefix(8)) hasTab=\(hasTab(id)) model=\(model ?? "-")")
        paneVisible = true
        if let tab = tabs.first(where: { $0.id == id }) {
            if tab.space != space {
                // 이 공간 그래프에 있는 대화면 탭을 이리로 데려오고, 아니면 탭이 있는 공간으로 간다
                if store?.isHere(id) == true { moveTabs([id], to: space) } else { goToSpace(tab.space) }
            }
            if let model, model != tab.modelID {
                if tab.state == .running {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "«\(store?.model(model)?.name ?? model)» 로 다시 열까요?")
                    alert.informativeText = String(localized: "지금 열린 Claude 를 닫고 같은 대화를 새 모델로 이어서 열어요. 대화 기록은 그대로예요. 작업 중이면 중단돼요.")
                    alert.addButton(withTitle: String(localized: "다시 열기"))
                    alert.addButton(withTitle: String(localized: "취소"))
                    guard alert.runModal() == .alertFirstButtonReturn else { show(id); return }
                }
                replace(tab, with: TermTab(id: id, cwd: tab.cwd, isNew: !hasTranscript(tab), modelID: model))
            } else if tab.state == .dormant {
                restart(id)      // 노드를 더블클릭했으면 꺼져 있던 대화를 바로 이어서 연다
            } else if let split, pane(of: id) == nil {
                self.split(horizontal: split, tab: id)
            } else {
                show(id)
            }
            return
        }
        let cwd = store?.node(id)?.cwd ?? store?.session(id)?.cwd ?? Paths.home
        let m = model ?? store?.node(id)?.modelID.flatMap { store?.model($0)?.id } ?? "claude"
        let tab = TermTab(id: id, cwd: FileManager.default.fileExists(atPath: cwd) ? cwd : Paths.home,
                          isNew: false, modelID: m,
                          space: store?.isHere(id) == true ? space : (store?.node(id)?.spaces.first ?? space))
        if tab.space != space { goToSpace(tab.space) }
        tabs.append(tab)
        if let split { self.split(horizontal: split, tab: id) } else { show(id) }
        Task { await checkAndStart(tab) }
    }

    /// 같은 대화를 새로 띄운다 (모델 바꾸기·다시 열기). 보관자 안의 이전 프로세스를 끝낸 뒤 시작.
    private func replace(_ old: TermTab, with fresh: TermTab) {
        if old.state == .running { stopRelay(old.view) }
        old.view?.removeFromSuperview()
        old.view = nil
        fresh.customTitle = old.customTitle
        fresh.space = old.space
        let k = killHolder(old.id)
        if let i = tabs.firstIndex(where: { $0.id == old.id }) { tabs[i] = fresh }
        show(fresh.id)
        Task {
            await k.value
            await checkAndStart(fresh)
        }
    }

    @discardableResult
    private func killHolder(_ id: String) -> Task<Void, Never> {
        if let t = killing[id] { return t }
        let t = Task {
            await PtyHost.kill(id)
            self.killing[id] = nil
        }
        killing[id] = t
        return t
    }

    private func hasTranscript(_ tab: TermTab) -> Bool {
        store?.session(tab.id) != nil
            || FileManager.default.fileExists(atPath: Paths.transcript(id: tab.id, cwd: tab.cwd))
    }

    /// 새 대화. linkTo 가 있으면 첫 메시지부터 그 대화의 맥락을 받도록 미리 노드와 linkTo → 새 대화 연결을 만든다.
    /// at: 그래프 좌표 (그래프 빈 곳 우클릭 → '여기서 새 대화')
    func openNew(cwd: String? = nil, linkTo: String? = nil, model: String? = nil, at point: CGPoint? = nil) {
        paneVisible = true
        let dir = cwd ?? linkTo.flatMap { store?.node($0)?.cwd } ?? defaultCwd
        let id = UUID().uuidString.lowercased()
        let tab = TermTab(id: id, cwd: FileManager.default.fileExists(atPath: dir) ? dir : Paths.home,
                          isNew: true, modelID: model ?? store?.defaultModelID ?? "claude", space: space)
        tabs.append(tab)
        show(id)
        store?.addPendingNode(id, cwd: tab.cwd, near: linkTo, at: point)
        if let linkTo { store?.link(linkTo, id, select: false) }   // linkTo 의 맥락이 새 대화로
        Task { await launch(tab) }
    }

    /// 일반 셸 탭 (그래프 노드 아님). 앱을 꺼도 유지되고, 탭을 닫으면 끝난다.
    @discardableResult
    func openShell(cwd: String? = nil) -> String {
        paneVisible = true
        let dir = cwd ?? currentDir(activeID) ?? defaultCwd
        let id = "sh-" + String(UUID().uuidString.lowercased().prefix(13))
        let tab = TermTab(id: id, kind: .shell, cwd: FileManager.default.fileExists(atPath: dir) ? dir : Paths.home,
                          space: space)
        tabs.append(tab)
        show(id)
        startShell(tab)
        return id
    }

    private func checkAndStart(_ tab: TermTab) async {
        tab.state = .checking
        if let k = killing[tab.id] { await k.value }
        // 앱을 껐다 켜기 전부터 보관자 안에서 돌고 있으면 그대로 붙는다
        if let info = await PtyHost.probe(tab.id) {
            tab.scope = info["scope"] as? String
            attach(tab)
            return
        }
        if tab.isShell {
            startShell(tab)
            return
        }
        if let live = await LiveSessions.find(tab.id) {
            tab.state = .elsewhere(pid: live.pid, tty: live.tty, busy: live.busy)
        } else {
            await launch(tab)
        }
    }

    func recheck(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        Task { await checkAndStart(tab) }
    }

    /// 다른 터미널의 Claude 를 종료(SIGTERM — 대화 기록은 이미 저장돼 있음)하고 여기서 이어서 연다.
    func moveHere(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }),
              case .elsewhere(let pid, _, let busy) = tab.state, !busy else { return }
        tab.state = .moving
        Task {
            kill(pid, SIGTERM)
            for _ in 0..<40 {
                if kill(pid, 0) != 0 { break }
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
            if kill(pid, 0) == 0 {
                tab.state = .elsewhere(pid: pid, tty: nil, busy: false)
                store?.notice = String(localized: "다른 터미널의 대화가 종료되지 않았어요. 그쪽에서 직접 닫아 주세요.")
                return
            }
            await launch(tab)
        }
    }

    func showElsewhere(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }), case .elsewhere(_, let tty, _) = tab.state,
              let tty else { return }
        let script = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set index of w to 1
                activate
                return
              end if
            end repeat
          end repeat
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { store?.notice = String(localized: "Terminal 에서 그 창을 찾지 못했어요") }
    }

    // MARK: 프로세스

    /// 모델 프로필에 맞는 env·인자를 ctxgraph.py 에서 받아 Claude Code 를 띄운다 (orc 와 같은 방식).
    private func launch(_ tab: TermTab) async {
        tab.state = .launching
        let r = await Python.run(["launch-env", tab.modelID, "--session", tab.id])
        guard let data = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tab.state = .failed(String(localized: "모델 설정을 읽지 못했어요: \(Fmt.oneLine(r.output, 160))"))
            return
        }
        if let err = obj["error"] as? String {
            tab.state = .failed(err)
            return
        }
        let env = obj["env"] as? [String: String] ?? [:]
        let args = obj["args"] as? [String] ?? []
        tab.scope = obj["scope"] as? String ?? "none"
        // 엄격 모드면 sandbox-exec 로 감싼다 (셸 명령까지 운영체제가 막음)
        start(tab, extraEnv: env, extraArgs: args, wrap: obj["wrap"] as? [String] ?? [])
    }

    private func makeView(_ tab: TermTab) -> CtxTerminalView {
        let tv = CtxTerminalView(frame: NSRect(origin: .zero, size: viewSize))
        Self.style(tv, size: fontSize, face: face)
        tv.processDelegate = self
        let id = tab.id
        tv.onFocus = { [weak self] in self?.focusedTerminal(id) }
        tv.onNotify = { [weak self] title, body in
            let msg = body.isEmpty ? title : (title.isEmpty ? body : "\(title): \(body)")
            self?.handleEvent(id: nil, tab: id, kind: "notify", message: Fmt.oneLine(msg, 200), at: Date(), quiet: false)
        }
        tab.view = tv
        tv.beginReplay()
        return tv
    }

    private func workDir(_ tab: TermTab) -> String {
        FileManager.default.fileExists(atPath: tab.cwd) ? tab.cwd : Paths.home
    }

    private static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// 보관자를 만들고 그 안에서 Claude 를 띄운 뒤 붙는다 (이미 있으면 그냥 붙는다).
    private func start(_ tab: TermTab, extraEnv: [String: String], extraArgs: [String], wrap: [String] = []) {
        let tv = makeView(tab)
        let claude = Self.claudePath()
        let flag = tab.isNew ? "--session-id" : "--resume"
        let extra = extraArgs.map(Fmt.shellQuote).joined(separator: " ")
        let pre = wrap.map(Fmt.shellQuote).joined(separator: " ")
        let skip = store?.skipPermissions == true ? " --dangerously-skip-permissions" : ""
        let cmd = "exec \(pre) \(Fmt.shellQuote(claude))\(skip) \(extra) \(flag) \(tab.id)"
        let meta = Self.json(["session": tab.id, "kind": "claude", "cwd": tab.cwd, "model": tab.modelID,
                              "isNew": tab.isNew, "scope": tab.scope ?? "none"])
        var env = extraEnv
        env["CTXGRAPH_TAB"] = tab.id
        tv.startProcess(executable: Paths.python,
                        args: ["-I", Paths.ptyScript, "open", "--sock", PtyHost.sock(tab.id), "--meta", meta,
                               "--", "/bin/zsh", "-l", "-i", "-c", cmd],
                        environment: Self.environment(extra: env), execName: nil, currentDirectory: workDir(tab))
        tab.state = .running
        store?.setNodeModel(tab.id, tab.modelID == "claude" ? nil : tab.modelID)
        objectWillChange.send()
        if activeID == tab.id { focusActive() }
    }

    private func startShell(_ tab: TermTab) {
        let tv = makeView(tab)
        let meta = Self.json(["session": tab.id, "kind": "shell", "cwd": tab.cwd, "model": "shell"])
        tv.startProcess(executable: Paths.python,
                        args: ["-I", Paths.ptyScript, "open", "--sock", PtyHost.sock(tab.id), "--meta", meta,
                               "--", "/bin/zsh", "-l"],
                        environment: Self.environment(extra: ["CTXGRAPH_TAB": tab.id]), execName: nil,
                        currentDirectory: workDir(tab))
        tab.state = .running
        objectWillChange.send()
        if activeID == tab.id { focusActive() }
    }

    /// 이미 돌고 있는 보관자에 붙기만 한다 (최근 화면을 다시 그림). 그 사이 꺼졌으면 종료 코드 3 → dormant.
    private func attach(_ tab: TermTab) {
        let tv = makeView(tab)
        tv.startProcess(executable: Paths.python,
                        args: ["-I", Paths.ptyScript, "open", "--sock", PtyHost.sock(tab.id), "--attach-only"],
                        environment: Self.environment(), execName: nil, currentDirectory: workDir(tab))
        tab.state = .running
        objectWillChange.send()
        if activeID == tab.id { focusActive() }
    }

    /// 다시 열기 (종료됐거나 꺼져 있던 탭). 셸은 마지막 폴더에서 새 셸, 대화는 이어서.
    func restart(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.isShell {
            replace(tab, with: TermTab(id: tab.id, kind: .shell, cwd: currentDir(id) ?? tab.cwd))
        } else {
            replace(tab, with: TermTab(id: tab.id, cwd: tab.cwd, isNew: !hasTranscript(tab), modelID: tab.modelID))
        }
    }

    /// 실패 카드에서 "다시 시도"
    func retry(_ id: String) { restart(id) }

    // MARK: 복원

    /// 앱을 켤 때: 저장된 탭·분할 배치를 되살리고, 보관자가 살아 있는 탭은 다시 붙는다.
    /// 목록에 없는데 살아 있는 보관자도 탭으로 가져온다 (보이지 않는 프로세스가 남지 않게).
    func restore() {
        guard !restored else { return }
        restored = true
        let saved = SavedTabs.load()
        if let w = saved.width, let h = saved.height, w > 200, h > 100 { viewSize = CGSize(width: w, height: h) }
        if let f = store?.settings["term_font"], let v = Double(f) { fontSize = CGFloat(v) }
        restoring = true
        space = saved.space ?? Space.main
        var restoredTabs: [TermTab] = []
        for t in saved.tabs where !hasTab(t.id) {
            let kind = TermTab.Kind(rawValue: t.kind ?? "claude") ?? .claude
            let tab = TermTab(id: t.id, kind: kind, cwd: t.cwd, isNew: t.isNew, modelID: t.model,
                              space: t.space ?? Space.main)
            tab.customTitle = t.title
            tab.unread = t.unread ?? false
            tab.lastNote = t.note
            restoredTabs.append(tab)
            tabs.append(tab)
        }
        let here = Set(spaceTabs.map(\.id))
        if let l = saved.layout, !l.leaves.isEmpty {
            layout = l
            paneTabs = (saved.paneTabs ?? [:]).filter { l.leaves.contains($0.key) && here.contains($0.value) }
            focusedPane = saved.focused.flatMap { l.leaves.contains($0) ? $0 : nil } ?? l.leaves[0]
        } else if let a = saved.active, here.contains(a) {
            paneTabs = [focusedPane: a]          // 분할 전 버전의 tabs.json
        }
        // 다른 공간들의 배치 (그 공간에 없는 탭은 뺀다)
        for (sp, var st) in saved.spaces ?? [:] where sp != space && !st.layout.leaves.isEmpty {
            let theirs = Set(tabs(in: sp).map(\.id))
            st.paneTabs = st.paneTabs.filter { st.layout.leaves.contains($0.key) && theirs.contains($0.value) }
            stash[sp] = st
        }
        if activeID == nil, let first = hiddenTabs.first { paneTabs[focusedPane] = first.id }
        vertical = saved.vertical ?? false
        if saved.pane && !here.isEmpty { paneVisible = true }
        restoring = false
        // 앱이 꺼져 있는 동안 온 알림은 안 읽음으로 (macOS 알림은 다시 띄우지 않음)
        lastEventID = saved.lastEvent ?? (store?.maxTermEventID() ?? 0)
        pollEvents(quiet: true)
        startLoops()
        Task {
            let live = await PtyHost.list()
            var liveIDs = Set<String>()
            for info in live {
                guard let sid = info["session"] as? String else { continue }
                liveIDs.insert(sid)
                if !hasTab(sid) {
                    let shell = (info["kind"] as? String) == "shell" || sid.hasPrefix("sh-")
                    let tab = TermTab(id: sid, kind: shell ? .shell : .claude, cwd: info["cwd"] as? String ?? Paths.home,
                                      isNew: info["isNew"] as? Bool ?? false, modelID: info["model"] as? String ?? "claude",
                                      space: space)
                    tab.scope = info["scope"] as? String
                    tabs.append(tab)
                    if activeID == nil { paneTabs[focusedPane] = sid }
                    attach(tab)
                }
            }
            let scopes = Dictionary(live.compactMap { i in (i["session"] as? String).map { ($0, i["scope"] as? String) } },
                                    uniquingKeysWith: { a, _ in a })
            for tab in restoredTabs where tab.state == .checking && tabs.contains(where: { $0 === tab }) {
                if liveIDs.contains(tab.id) {
                    tab.scope = scopes[tab.id] ?? nil
                    attach(tab)
                } else {
                    tab.state = .dormant
                }
            }
            dbg("restore: saved=\(saved.tabs.count) live=\(liveIDs.count) panes=\(layout.leaves.count)")
            if let spec = ProcessInfo.processInfo.environment["CTXGRAPH_TEST_ACTIONS"] { runTestActions(spec) }
        }
    }

    /// 화면 점검용 (CTXGRAPH_TEST_ACTIONS="shell:/dir;;type:ls;;split:h;;split:v;;vertical;;focus:0;;closeall;;quit")
    private func runTestActions(_ spec: String) {
        let steps = spec.components(separatedBy: ";;")
        Task {
            for st in steps {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                let parts = st.split(separator: ":", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                dbg("test action: \(st)")
                switch parts.first ?? "" {
                case "shell": openShell(cwd: arg.isEmpty ? nil : arg)
                case "type": active?.view?.send(txt: arg + "\r")
                case "down": active?.view?.send(txt: "\u{1b}[B")
                case "enter": active?.view?.send(txt: "\r")
                case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 1) * 1e9))
                case "split": split(horizontal: arg != "v")
                case "vertical": vertical = true
                case "focus": if let i = Int(arg), layout.leaves.indices.contains(i) { focusPane(layout.leaves[i]) }
                case "closeall": for t in tabs { close(t.id, force: true) }
                case "show": if let t = tabs.first(where: { $0.id.hasPrefix(arg) }) { show(t.id) }
                case "close": if let id = arg.isEmpty ? activeID : tabs.first(where: { $0.id.hasPrefix(arg) })?.id { close(id, force: true) }
                case "closepane": closePane()
                case "where":   // 시험: 탭마다 뷰가 창에 붙어 있는지
                    let lines = tabs.map { t in "\(t.id.prefix(10)) space=\(t.space) pane=\(pane(of: t.id) ?? "-") win=\(t.view?.window != nil) super=\(t.view?.superview != nil) unread=\(t.unread) state=\(t.state)" }
                    let sp = "space=\(space) visible=\(paneVisible) stash=\(stash.keys.sorted()) graph=\(store?.nodes.map { String($0.id.prefix(8)) } ?? [])"
                    try? (lines.joined(separator: "\n") + "\nlayout=\(layout.key)\n\(sp)\n").write(toFile: arg, atomically: true, encoding: .utf8)
                case "newspace": store?.createSpace(arg)
                case "hover":   // 시험: 창 내용 좌표(왼쪽 위, pt)로 마우스가 움직인 것처럼 — hover:462,465
                    let xy = arg.split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2 { EdgePeek.shared.pointerMoved(CGPoint(x: xy[0], y: xy[1])) }
                case "hoverev":   // 시험: 창 좌표(왼쪽 위, pt)에 실제 NSEvent 를 만들어 감시와 같은 변환을 거치게
                    let xy = arg.split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2, let w = NSApp.windows.first(where: { $0.title == "CtxGraph" && $0.isVisible }),
                       let ev = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: xy[0], y: w.frame.height - xy[1]),
                                                   modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                        EdgePeek.shared.handle(ev)
                    }
                case "peek", "arrive":   // 시험: 화살표 엿보기 / 맥락 도착 장면 — peek:<보내는 ID 앞>,<받는 ID 앞>
                    let ab = arg.split(separator: ",").map(String.init)
                    if ab.count == 2, let store,
                       let l = store.links.first(where: { $0.src.hasPrefix(ab[0]) && $0.dst.hasPrefix(ab[1]) }),
                       let sn = store.node(l.src), let s = store.position(l.src), let d = store.position(l.dst) {
                        if parts[0] == "arrive" {
                            FlowStatus.shared.simulateArrival(l.id, version: sn.version)
                        } else {
                            let o = store.worldRect.origin
                            let k = 0.35
                            EdgePeek.shared.show(l, at: CGPoint(x: s.x + (d.x - s.x) * k - o.x, y: s.y + (d.y - s.y) * k - o.y))
                        }
                    }
                case "space":   // 이름 또는 순번(0부터)
                    if let i = Int(arg) { store?.switchSpace(index: i) }
                    else if let sp = store?.spaces.first(where: { $0.name == arg }) { store?.switchSpace(sp.id) }
                case "movenode":   // "세션앞부분|공간이름"
                    let a = arg.components(separatedBy: "|")
                    if a.count == 2, let n = store?.allNodes.first(where: { $0.id.hasPrefix(a[0]) }),
                       let sp = store?.spaces.first(where: { $0.name == a[1] }) { store?.moveNodes([n.id], to: sp.id) }
                case "alsoshow":   // "세션앞부분|공간이름" (다른 공간에도 놓기)
                    let a = arg.components(separatedBy: "|")
                    if a.count == 2, let n = store?.allNodes.first(where: { $0.id.hasPrefix(a[0]) }),
                       let sp = store?.spaces.first(where: { $0.name == a[1] }) { store?.setShown(n.id, in: sp.id, true) }
                case "label":   // "세션앞부분|이름" (대화 이름 바꾸기)
                    let a = arg.components(separatedBy: "|")
                    if a.count == 2, let s = store?.sessions.first(where: { $0.id.hasPrefix(a[0]) }) { store?.setLabel(s.id, a[1]) }
                case "removenode": if let n = store?.allNodes.first(where: { $0.id.hasPrefix(arg) }) { store?.removeNode(n.id) }
                case "delspace": if let sp = store?.spaces.first(where: { $0.name == arg }) { store?.deleteSpace(sp.id) }
                case "open": if let n = store?.allNodes.first(where: { $0.id.hasPrefix(arg) }) { open(n.id) }
                case "horizontal": vertical = false
                case "zoom":   // "배율|x|y" (x,y = 그래프 칸 화면 좌표, 없으면 가운데)
                    let a = arg.components(separatedBy: "|").compactMap { Double($0) }
                    if let f = a.first { CanvasViewport.shared.zoom(by: f, at: a.count == 3 ? CGPoint(x: a[1], y: a[2]) : nil) }
                case "fit": CanvasViewport.shared.fit()
                case "addhere":   // 시험: 빈 곳 우클릭 메뉴의 '여기에 대화 추가'와 같은 경로 ("#순번")
                    let all = store?.sessions ?? []
                    if let i = Int(arg.dropFirst()), all.indices.contains(i), let store { EmptyCanvasMenu.add(all[i].id, store) }
                case "menupoint":   // 시험: 빈 곳 우클릭한 자리 (화면 좌표 "x|y")
                    let a = arg.components(separatedBy: "|").compactMap { Double($0) }
                    if a.count == 2 { CanvasViewport.shared.menuPoint = CGPoint(x: a[0], y: a[1]) }
                case "addsheet": CanvasViewport.shared.addTarget = .init(point: CanvasViewport.shared.menuWorldPoint())
                case "snapsheet":   // 시험: 떠 있는 시트 창을 그림으로
                    if let w = NSApp.windows.first(where: { $0.title == "CtxGraph" })?.attachedSheet,
                       let v = w.contentView?.superview ?? w.contentView, let layer = v.layer {
                        let sc = w.backingScaleFactor, sz = v.bounds.size
                        if let ctx = CGContext(data: nil, width: Int(sz.width * sc), height: Int(sz.height * sc), bitsPerComponent: 8,
                                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            ctx.scaleBy(x: sc, y: sc)
                            var bg = NSColor.windowBackgroundColor.cgColor
                            w.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }
                            ctx.setFillColor(bg)
                            ctx.fill(CGRect(origin: .zero, size: sz))
                            if layer.isGeometryFlipped || v.isFlipped { ctx.translateBy(x: 0, y: sz.height); ctx.scaleBy(x: 1, y: -1) }
                            layer.render(in: ctx)
                            if let img = ctx.makeImage() {
                                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                                    .write(to: URL(fileURLWithPath: arg))
                            }
                        }
                    }
                case "drop":   // "세션앞부분|x|y" — 끌어 놓기와 같은 경로 (화면 좌표 → 그래프 좌표)
                    let a = arg.components(separatedBy: "|")
                    let all = store?.sessions ?? []
                    let pick = a[0].hasPrefix("#") ? Int(a[0].dropFirst()).flatMap { all.indices.contains($0) ? all[$0] : nil }
                                                   : all.first(where: { $0.id.hasPrefix(a[0]) })
                    if a.count == 3, let x = Double(a[1]), let y = Double(a[2]), let s = pick {
                        CanvasViewport.shared.touched()
                        store?.addNodes([s.id], at: CanvasViewport.shared.toWorld(CGPoint(x: x, y: y)))
                    }
                case "view":   // 시험: 배율·위치·노드 자리·끌어 놓기 받는 뷰
                    let vp = CanvasViewport.shared
                    var out = "zoom=\(String(format: "%.3f", vp.zoom)) pan=\(Int(vp.pan.x)),\(Int(vp.pan.y)) size=\(Int(vp.size.width))x\(Int(vp.size.height)) menu=\(vp.menuPoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-") sheet=\(vp.addTarget != nil)\n"
                    for n in store?.nodes ?? [] {
                        let sp = vp.toScreen(n.point)
                        out += "node \(n.id.prefix(8)) world=\(Int(n.x)),\(Int(n.y)) screen=\(Int(sp.x)),\(Int(sp.y))\n"
                    }
                    out += "listdrag ids=\(ListDrag.shared.ids.count) canvas=\(ListDrag.shared.canvasPoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-") hover=\(ListDropHover.shared.space ?? "-")\n"
                    out += "allnodes " + (store?.allNodes.map { "\($0.id.prefix(8))@\($0.spaces.joined(separator: "+"))" }.joined(separator: " ") ?? "") + "\n"
                    for (kind, n) in [("space", 4), ("session", 5)] {
                        for (id, r) in RowMarkerView.dump(kind).sorted(by: { $0.1.maxY > $1.1.maxY }).prefix(n) {
                            out += "row \(kind) \(id.prefix(10)) frame=\(r.integral)\n"
                        }
                    }
                    if let w = NSApp.windows.first(where: { $0.title == "CtxGraph" }), let cv = w.contentView {
                        @MainActor func walk(_ v: NSView, _ d: Int) {
                            if !v.registeredDraggedTypes.isEmpty {
                                out += "drop \(type(of: v)) frame=\(v.convert(v.bounds, to: nil).integral) types=\(v.registeredDraggedTypes.map(\.rawValue).filter { $0.contains("text") || $0.contains("string") }.prefix(3))\n"
                            }
                            if v is CanvasEventView {
                                var chain: [String] = []
                                var c: NSView? = v.superview
                                while let x = c { chain.append(String(describing: type(of: x)).prefix(40).description); c = x.superview }
                                out += "catcher frame=\(v.convert(v.bounds, to: nil).integral) chain=\(chain)\n"
                            }
                            for sv in v.subviews { walk(sv, d + 1) }
                        }
                        walk(cv, 0)
                    }
                    try? out.write(toFile: arg, atomically: true, encoding: .utf8)
                case "snap": snapTo(arg)
                case "rec":     // 시험·데모 녹화: rec:<폴더>|<초당 장수>|<초>|<배율> — 뒤에서 찍고 다음 액션은 바로 이어감
                    let ps = arg.components(separatedBy: "|")
                    if ps.count >= 3, let fps = Double(ps[1]), let secs = Double(ps[2]) {
                        let dir = ps[0], scale = ps.count > 3 ? Double(ps[3]).map { CGFloat($0) } : nil
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        Task { @MainActor in
                            let start = Date()
                            for i in 0..<Int(fps * secs) {
                                let due = start.addingTimeInterval(Double(i) / fps)
                                let wait = due.timeIntervalSinceNow
                                // 한 장 찍는 데 간격만큼 걸리면 쉬지 않고 돌아서 다음 시험 액션(hover·hookrun)이 녹화가 끝날 때까지 밀린다: 늘 한 번은 양보
                                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } else { await Task.yield() }
                                self.snapTo(String(format: "%@/f%04d.png", dir, i), scale: scale, async: true)
                            }
                            try? "done".write(toFile: dir + "/done", atomically: true, encoding: .utf8)
                        }
                    }
                case "hookrun":   // 시험·데모: ctxgraph.py hook 에 이 JSON 파일을 넣어 실제로 실행 (메시지를 보낸 것처럼)
                    if let py = PythonRuntime.path {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: py)
                        p.arguments = ["-I", Paths.script, "hook"]
                        p.standardInput = FileHandle(forReadingAtPath: arg)
                        p.standardOutput = FileHandle.nullDevice
                        try? p.run()
                    }
                case "snapwin":     // 시험: 다른 창 (예: 설정 'Claude Code') — snapwin:창제목|경로
                    let ps = arg.components(separatedBy: "|")
                    if ps.count == 2 { snapTo(ps[1], title: ps[0]) }
                case "feedtest":   // 시험: 파일 바이트를 새 터미널 뷰에 직접 넣고(앞에서 n 바이트까지) 화면 글자를 덤프 — "파일|n|출력"
                    let a = arg.components(separatedBy: "|")
                    if a.count == 3, let data = FileManager.default.contents(atPath: a[0]), let n = Int(a[1]) {
                        let tv = CtxTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                        let bytes = [UInt8](data.prefix(n))
                        tv.feed(byteArray: bytes[...])
                        let t = tv.getTerminal()
                        let txt = "alt=\(t.isCurrentBufferAlternate)\n" + String(decoding: t.getBufferAsData(kind: .active), as: UTF8.self)
                        try? txt.write(toFile: a[2], atomically: true, encoding: .utf8)
                    }
                case "dump":   // 시험: 지금 탭 터미널 화면 글자를 파일로 (active 버퍼 + 대체 화면 여부)
                    if let t = active?.view?.getTerminal() {
                        let d = t.getBufferAsData(kind: .active)
                        var head = "alt=\(t.isCurrentBufferAlternate) cols=\(t.cols) rows=\(t.rows) view=\(String(describing: active?.view?.frame.size))\n"
                        head += String(decoding: d, as: UTF8.self)
                        try? head.write(toFile: arg, atomically: true, encoding: .utf8)
                    }
                case "move": if let x = Double(arg) { NSApp.windows.first(where: { $0.title == "CtxGraph" })?.setFrameOrigin(NSPoint(x: x, y: 60)) }
                case "quit": NSApp.terminate(nil)
                default: break
                }
            }
        }
    }

    private func save() {
        guard !restoring, restored else { return }
        var s = SavedTabs()
        s.tabs = tabs.map { .init(id: $0.id, cwd: $0.cwd, isNew: $0.isNew, model: $0.modelID,
                                  kind: $0.kind.rawValue, title: $0.customTitle,
                                  unread: $0.unread ? true : nil, note: $0.lastNote,
                                  space: $0.space == Space.main ? nil : $0.space) }
        s.active = activeID
        s.pane = paneVisible
        s.width = viewSize.width
        s.height = viewSize.height
        s.layout = layout
        s.paneTabs = paneTabs
        s.focused = focusedPane
        s.vertical = vertical
        s.lastEvent = lastEventID
        s.space = space
        s.spaces = stash.isEmpty ? nil : stash
        s.save()
    }

    func close(_ id: String, force: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[i]
        if tab.state == .running && !force {
            if tab.isShell, let inf = info[id], inf.procs > 0 {
                let alert = NSAlert()
                alert.messageText = String(localized: "실행 중인 프로그램이 있는 셸을 닫을까요?")
                alert.informativeText = String(localized: "이 셸에서 프로그램 \(inf.procs)개가 돌고 있어요") +
                    (inf.ports.isEmpty ? "" : String(localized: " (포트 \(inf.ports.map(String.init).joined(separator: ", ")))")) +
                    String(localized: ". 탭을 닫으면 함께 종료돼요.")
                alert.addButton(withTitle: String(localized: "닫기"))
                alert.addButton(withTitle: String(localized: "취소"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            } else if !tab.isShell, store?.session(id)?.liveStatus == "busy" {
                let alert = NSAlert()
                alert.messageText = String(localized: "작업 중인 대화를 닫을까요?")
                alert.informativeText = String(localized: "Claude 가 아직 작업 중이에요. 탭을 닫으면 지금 작업이 중단돼요. 대화 기록은 남아서 나중에 이어서 열 수 있어요.")
                alert.addButton(withTitle: String(localized: "닫기"))
                alert.addButton(withTitle: String(localized: "취소"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        if tab.state == .running { stopRelay(tab.view) }
        tab.view?.removeFromSuperview()
        killHolder(id)                      // 탭을 닫을 때만 프로세스를 끝낸다
        let si = spaceTabs.firstIndex { $0.id == id }
        if tab.space == space {
            vacate(id, near: si)
        } else if var st = stash[tab.space] {
            st.paneTabs = st.paneTabs.filter { $0.value != id }
            stash[tab.space] = st
        }
        tabs.remove(at: i)
        notes.removeAll { $0.tab == id }
        if spaceTabs.isEmpty { paneVisible = false }
        focusActive()
    }

    /// 앱 종료: 탭 목록을 저장하고 중계만 끊는다. 프로세스는 보관자 안에서 계속 돈다.
    func detachAll() {
        quitting = true
        dbg("detachAll viewSize=\(viewSize)")
        save()
        for t in tabs where t.state == .running { t.view?.terminate() }
    }

    /// 중계 프로세스를 끝내고 거둔다 (SwiftTerm terminate 는 kill 만 하고 waitpid 를 안 해서 좀비가 남음)
    private func stopRelay(_ tv: CtxTerminalView?) {
        guard let tv else { return }
        let pid = tv.process.shellPid
        tv.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var st: Int32 = 0
            for _ in 0..<50 {
                if waitpid(pid, &st, WNOHANG) != 0 { return }
                usleep(100_000)
            }
        }
    }

    func focusActive() {
        guard let tv = active?.view else { return }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }

    // MARK: 설정

    static func claudePath() -> String {
        for p in [Paths.home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "claude"
    }

    static func environment(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment.filter { k, _ in
            // CTXGRAPH_HOME 은 넘긴다: 시험용 앱이면 그 안 대화의 훅도 시험 DB 를 쓰게
            !k.hasPrefix("CLAUDE") && (!k.hasPrefix("CTXGRAPH") || k == "CTXGRAPH_HOME") && k != "AI_AGENT" && !k.hasPrefix("ANTHROPIC_")
                && !k.hasPrefix("__CF") && k != "XPC_SERVICE_NAME" && !k.hasPrefix("XPC_")
        }
        for (k, v) in extra { env[k] = v }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "CtxGraph"
        env["LANG"] = env["LANG"] ?? "ko_KR.UTF-8"
        env["SHELL"] = "/bin/zsh"
        env["HOME"] = Paths.home
        // 스크립트 폴더: 터미널 안에서 `ctxgraph notify 메시지` 로 이 탭에 알림
        env["PATH"] = "\(Paths.home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(Paths.binDir)"
        return env.map { "\($0.key)=\($0.value)" }
    }

    static func style(_ tv: LocalProcessTerminalView, size: CGFloat = 13, face: TermFont = .system) {
        tv.font = face.font(size)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tv.nativeBackgroundColor = dark ? NSColor(srgbRed: 0.105, green: 0.11, blue: 0.125, alpha: 1)
                                        : NSColor(srgbRed: 0.985, green: 0.983, blue: 0.976, alpha: 1)
        tv.nativeForegroundColor = dark ? NSColor(srgbRed: 0.88, green: 0.88, blue: 0.86, alpha: 1)
                                        : NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
        tv.caretColor = .controlAccentColor
        tv.optionAsMetaKey = false     // ⌥ 로 특수문자 입력 (macOS 기본과 같게)
    }
}

extension TerminalManager: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            // 화면에 붙을 때 레이아웃으로 정해진 크기 (분할 패널이면 그 패널 크기)
            let s = source.frame.size
            if s.width > 200, s.height > 100, !self.multiPane { self.viewSize = s }
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let ptr = ObjectIdentifier(source)
        Task { @MainActor in
            guard let tab = self.tabs.first(where: { $0.view.map(ObjectIdentifier.init) == ptr }), tab.isShell else { return }
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if tab.osTitle != t { tab.osTitle = t.isEmpty ? nil : t; self.objectWillChange.send() }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let ptr = ObjectIdentifier(source)
        Task { @MainActor in
            guard !self.quitting,
                  let tab = self.tabs.first(where: { $0.view.map(ObjectIdentifier.init) == ptr }) else { return }
            if exitCode == 3 {
                tab.state = .dormant                 // 붙으려던 보관자가 이미 없음
            } else if tab.isShell && exitCode == 0 {
                self.close(tab.id)                   // 셸에서 exit → 탭 닫기 (보통 터미널처럼)
                return
            } else {
                tab.state = .exited(exitCode)
            }
            self.objectWillChange.send()
            if !tab.isShell { Task { await self.store?.rescan() } }
        }
    }
}

extension TerminalManager: UNUserNotificationCenterDelegate {
    /// macOS 알림을 누르면 그 탭으로
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["tab"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id { self.show(id) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])        // 앱이 앞에 있으면 앱 안 표시로 충분
    }
}

/// `claude agents --json` 으로 지금 열려 있는 대화를 찾는다 (pid·tty·작업 중 여부).
enum LiveSessions {
    struct Live { let pid: Int32; let tty: String?; let busy: Bool }

    static func find(_ sessionID: String) async -> Live? {
        let r = await run([TerminalManager.claudePath(), "agents", "--json"])
        guard let data = r.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        guard let s = list.first(where: { ($0["sessionId"] as? String) == sessionID }),
              let pidNum = s["pid"] as? NSNumber else { return nil }
        let pid = pidNum.int32Value
        guard kill(pid, 0) == 0 else { return nil }
        let tty = await run(["/bin/ps", "-o", "tty=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Live(pid: pid, tty: tty.isEmpty || tty == "??" ? nil : "/dev/" + tty,
                    busy: (s["status"] as? String) == "busy")
    }

    private static func run(_ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: args[0])
                p.arguments = Array(args.dropFirst())
                var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
                env["PATH"] = "\(Paths.home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
