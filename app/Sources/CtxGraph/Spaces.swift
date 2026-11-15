import AppKit
import SwiftUI

/// 작업 공간 만들기·이름 바꾸기·지우기 (메뉴·사이드바·노드 메뉴에서 같이 씀)
@MainActor
enum SpaceActions {
    static func ask(_ title: String, info: String, initial: String, ok: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = String(localized: "예: 앱 개발, 퀀트 연구")
        alert.accessoryView = field
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: String(localized: "취소"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 새 공간. moving 이 있으면 그 대화들(과 열린 터미널 탭)을 데리고 간다. keep 이면 옮기지 않고 새 공간에도 놓는다.
    static func create(_ store: GraphStore, moving ids: [String] = [], keep: Bool = false) {
        let info = ids.isEmpty
            ? String(localized: "공간마다 그래프와 터미널 탭·분할 배치가 따로 저장돼요. 공간을 바꿔도 다른 공간의 터미널은 계속 돌아요.")
            : keep ? String(localized: "고른 대화 \(ids.count)개를 새 공간에도 놓아요. 지금 공간에도 그대로 있어요.")
            : String(localized: "고른 대화 \(ids.count)개와 그 터미널 탭을 새 공간으로 옮겨요.")
        guard let name = ask(String(localized: "새 작업 공간"), info: info, initial: "", ok: String(localized: "만들기")) else { return }
        let id = store.createSpace(name, switchTo: ids.isEmpty)
        if !ids.isEmpty {
            if keep { store.alsoShow(ids, in: id) } else { store.moveNodes(ids, to: id) }
            store.switchSpace(id)
        }
    }

    static func rename(_ store: GraphStore, _ id: String) {
        guard let name = ask(String(localized: "작업 공간 이름"), info: "", initial: store.spaceName(id), ok: String(localized: "바꾸기")),
              !name.isEmpty else { return }
        store.renameSpace(id, name)
    }

    /// 지워도 대화·터미널은 기본 공간으로 옮길 뿐 아무것도 끄지 않는다
    static func delete(_ store: GraphStore, _ terms: TerminalManager, _ id: String) {
        guard id != Space.main else { return }
        let n = store.nodeCount(in: id), t = terms.tabs(in: id).count
        let alert = NSAlert()
        alert.messageText = String(localized: "«\(store.spaceName(id))» 공간을 지울까요?")
        alert.informativeText = (n + t == 0 ? String(localized: "빈 공간이에요.") :
            String(localized: "이 공간의 대화 \(n)개와 터미널 탭 \(t)개는 «\(store.spaceName(Space.main))» 공간으로 옮겨져요."))
            + String(localized: " 대화나 터미널을 끄거나 지우지는 않아요.")
        alert.addButton(withTitle: String(localized: "지우기"))
        alert.addButton(withTitle: String(localized: "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteSpace(id)
    }

    /// 노드 메뉴의 '옮기기' 목록
    static func move(_ store: GraphStore, _ ids: [String], to sp: Space) {
        store.moveNodes(ids, to: sp.id)
        let k = store.spaces.firstIndex(of: sp).map { $0 < 9 ? " (⌘\($0 + 1))" : "" } ?? ""
        store.notice = String(localized: "«\(sp.name)» 공간으로 옮겼어요\(k)")
    }
}

/// 노드(또는 연결된 묶음)를 다른 공간으로 옮기는 메뉴 항목들
struct MoveToSpaceMenu: View {
    @EnvironmentObject var store: GraphStore
    let title: String
    let ids: [String]

    var body: some View {
        let others = store.spaces.filter { $0.id != store.space }
        Menu(title) {
            ForEach(others) { sp in
                Button(sp.name) { SpaceActions.move(store, ids, to: sp) }
            }
            if !others.isEmpty { Divider() }
            Button("새 작업 공간으로…") { SpaceActions.create(store, moving: ids) }
        }
    }
}

/// 노드를 다른 공간에도 놓는 메뉴 (지금 공간에도 그대로 — 위치는 공간마다 따로, 맥락 연결은 하나)
struct AlsoShowMenu: View {
    @EnvironmentObject var store: GraphStore
    let id: String

    var body: some View {
        let others = store.spaces.filter { !store.isShown(id, in: $0.id) }
        Menu("다른 공간에도 놓기") {
            ForEach(others) { sp in
                Button(sp.name) { store.setShown(id, in: sp.id, true) }
            }
            if !others.isEmpty { Divider() }
            Button("새 작업 공간에…") { SpaceActions.create(store, moving: [id], keep: true) }
        }
    }
}

// MARK: - 사이드바 맨 위: 작업 공간 목록

struct SpaceSection: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager
    @ObservedObject private var hover = ListDropHover.shared

    var body: some View {
        Section {
            ForEach(Array(store.spaces.enumerated()), id: \.element.id) { i, sp in
                SpaceRow(space: sp, index: i, current: sp.id == store.space,
                         nodes: store.nodeCount(in: sp.id), running: terms.runningCount(in: sp.id),
                         unread: terms.unreadCount(in: sp.id), dropHover: hover.space == sp.id)
                    .background(RowMarker(kind: "space", id: sp.id))
                    .onTapGesture { store.switchSpace(sp.id) }
                    .contextMenu {
                        if sp.id != store.space { Button("이 공간으로 가기") { store.switchSpace(sp.id) } }
                        Button("이름 바꾸기…") { SpaceActions.rename(store, sp.id) }
                        Button("위로") { store.moveSpace(sp.id, by: -1) }.disabled(i == 0)
                        Button("아래로") { store.moveSpace(sp.id, by: 1) }.disabled(i == store.spaces.count - 1)
                        Divider()
                        Button("지우기…", role: .destructive) { SpaceActions.delete(store, terms, sp.id) }
                            .disabled(sp.id == Space.main)
                    }
            }
        } header: {
            HStack {
                Text("작업 공간")
                Spacer()
                Button { SpaceActions.create(store) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("새 작업 공간 (⇧⌘N)")
                .accessibilityLabel("새 작업 공간")
            }
        }
    }
}

struct SpaceRow: View {
    let space: Space
    let index: Int
    let current: Bool
    let nodes: Int
    let running: Int
    let unread: Int
    var dropHover = false            // 대화를 끌고 이 줄 위에 있음
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: current ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                .font(.system(size: 12))
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(space.name)
                .font(.system(size: 13, weight: current ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if unread > 0 {
                Text("\(unread)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Ink.attention))
                    .help("안 읽은 알림 \(unread)개")
            }
            if hovering && index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                HStack(spacing: 6) {
                    if running > 0 {
                        Label("\(running)", systemImage: "terminal").labelStyle(CountLabel())
                    }
                    if nodes > 0 { Text("\(nodes)") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(current ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: dropHover ? 2 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .help((current ? String(localized: "지금 공간") : String(localized: "이 공간으로 가기 — 대화를 끌어 놓으면 이 공간으로 옮겨요"))
              + String(localized: " · 노드 \(nodes) · 터미널 \(running)") + (index < 9 ? " · ⌘\(index + 1)" : ""))
    }
}

/// 아이콘 + 숫자를 바짝 붙인 라벨 (공간 줄의 터미널 수)
struct CountLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon.imageScale(.small); configuration.title }
    }
}
