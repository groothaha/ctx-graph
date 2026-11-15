import AppKit
import SwiftUI

/// 왼쪽 대화 목록 → 그래프(또는 작업 공간 줄)로 끌어 놓기, 대화 줄 더블클릭.
/// SwiftUI List 는 줄의 첫 클릭을 표(NSTableView)가 가져가 혼자 마우스를 추적하므로, 줄에 단 제스처나
/// 시스템 드래그가 잘 시작되지 않는다. 그래서 대화 줄 위의 왼쪽 버튼 이벤트는 창으로 가기 전에 여기서 받아
/// 직접 처리한다 (같은 창 안이라 시스템 드래그도 필요 없다). 오른쪽 클릭·⌃클릭 메뉴는 그대로.
@MainActor
final class ListDrag: ObservableObject {
    static let shared = ListDrag()

    @Published private(set) var ids: [String] = []
    /// 그래프 칸 위면 그 화면 좌표 (놓을 자리 미리보기), 아니면 nil
    @Published private(set) var canvasPoint: CGPoint?
    weak var canvas: CanvasEventView?
    weak var store: GraphStore?

    private var monitor: Any?
    private var pressID: String?          // 대화 줄에서 왼쪽 버튼을 누른 채
    private var pressPoint: NSPoint = .zero

    var active: Bool { !ids.isEmpty }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { e in
            guard let w = e.window else { return e }
            return ListDrag.shared.handle(e, e.locationInWindow, w) ? nil : e
        }
    }

    /// true = 이 이벤트는 여기서 처리했음 (창·표로 보내지 않음)
    func handle(_ e: NSEvent, _ wp: NSPoint, _ w: NSWindow) -> Bool {
        switch e.type {
        case .leftMouseDown:
            pressID = nil
            guard !e.modifierFlags.contains(.control),
                  let id = RowMarkerView.find("session", at: wp, in: w) else { return false }
            if e.clickCount >= 2 {
                store?.addNode(id)
                return true
            }
            pressID = id
            pressPoint = wp
            return true
        case .leftMouseDragged:
            guard let id = pressID else { return false }
            if !active {
                guard hypot(wp.x - pressPoint.x, wp.y - pressPoint.y) > 4 else { return true }
                begin([id])
            }
            update(wp)
            return true
        case .leftMouseUp:
            guard pressID != nil else { return false }
            pressID = nil
            if active { end(wp) }
            return true
        default:
            return false
        }
    }

    private func begin(_ ids: [String]) {
        self.ids = ids
        NSCursor.dragCopy.push()
    }

    private func update(_ wp: NSPoint) {
        guard active, let c = canvas, let w = c.window else { return }
        let p = c.convert(wp, from: nil)
        let cp: CGPoint? = c.isOverCanvas(wp, p) ? p : nil
        if cp != canvasPoint { canvasPoint = cp }
        let sp = cp == nil ? RowMarkerView.find("space", at: wp, in: w) : nil
        if sp != ListDropHover.shared.space { ListDropHover.shared.space = sp }
    }

    /// 놓기: 그래프 위면 그 자리에 추가(이미 있으면 그 자리로 옮김), 작업 공간 줄 위면 그 공간에 넣기, 그 밖이면 취소
    private func end(_ wp: NSPoint) {
        update(wp)
        let ids = self.ids
        if let store, let p = canvasPoint {
            CanvasViewport.shared.touched()
            store.addNodes(ids, at: CanvasViewport.shared.toWorld(p))
        } else if let store, let sp = ListDropHover.shared.space {
            store.addNodes(ids, toSpace: sp)
        }
        self.ids = []
        canvasPoint = nil
        ListDropHover.shared.space = nil
        NSCursor.pop()
    }
}

/// 끄는 중 마우스 아래 작업 공간 줄 (사이드바 줄만 다시 그리게 따로 둔다)
@MainActor
final class ListDropHover: ObservableObject {
    static let shared = ListDropHover()
    @Published var space: String?
}

/// 사이드바 줄의 창 안 위치를 알려 주는 보이지 않는 NSView (끌어 놓을 곳 찾기·시험용)
final class RowMarkerView: NSView {
    var kind = ""
    var id = ""
    private static let all = NSHashTable<RowMarkerView>.weakObjects()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.all.add(self) } else { Self.all.remove(self) }
    }

    /// 보이는 부분(스크롤로 가려진 곳 제외)이 창 좌표 wp 를 덮는 표시
    static func find(_ kind: String, at wp: NSPoint, in w: NSWindow) -> String? {
        for m in all.allObjects where m.kind == kind && m.window === w && !m.isHiddenOrHasHiddenAncestor {
            let r = m.visibleRect
            if !r.isEmpty, m.convert(r, to: nil).contains(wp) { return m.id }
        }
        return nil
    }

    /// 시험: 보이는 표시들의 창 좌표
    static func dump(_ kind: String) -> [(String, NSRect)] {
        all.allObjects.filter { $0.kind == kind && $0.window != nil && !$0.visibleRect.isEmpty }
            .map { ($0.id, $0.convert($0.visibleRect, to: nil)) }
    }
}

struct RowMarker: NSViewRepresentable {
    let kind: String
    let id: String

    func makeNSView(context: Context) -> RowMarkerView { RowMarkerView() }

    func updateNSView(_ v: RowMarkerView, context: Context) {
        v.kind = kind
        v.id = id
    }
}

/// 그래프 위로 끌고 오는 동안 놓일 자리에 보이는 반투명 카드
struct DropPreview: View {
    let title: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text(count > 1 ? "대화 \(count)개 — 놓으면 추가" : "놓으면 여기에 추가")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Layout.node.width, height: Layout.node.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Ink.card.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// 그래프 빈 곳 우클릭 메뉴: 우클릭한 자리에 대화 추가 / 새 대화
struct EmptyCanvasMenu: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager

    /// 메뉴·시험이 같이 쓰는 '여기에 추가' (이미 있으면 그 자리로 옮김, 다른 공간에만 있으면 이 공간에도 놓음)
    static func add(_ id: String, _ store: GraphStore) {
        CanvasViewport.shared.touched()
        store.addNode(id, at: CanvasViewport.shared.menuWorldPoint())
    }

    var body: some View {
        let recent = Array(store.sessions.lazy.filter { !store.isHere($0.id) }.prefix(12))
        Menu("여기에 대화 추가") {
            ForEach(recent) { s in
                Button(label(s)) { Self.add(s.id, store) }
            }
            if !recent.isEmpty { Divider() }
            Button("대화 찾아서 추가…") {
                CanvasViewport.shared.addTarget = .init(point: CanvasViewport.shared.menuWorldPoint())
            }
        }
        Menu("여기서 새 대화") {
            ModelButtons { terms.openNew(model: $0, at: CanvasViewport.shared.menuWorldPoint()) }
        }
        Divider()
        Button("노드 전부 보기") { CanvasViewport.shared.fit() }
    }

    private func label(_ s: SessionInfo) -> String {
        store.title(s.id) + " · " + Fmt.ago(s.mtime) + (store.otherSpaceName(s.id).map { String(localized: " · «\($0)» 공간에도 있음") } ?? "")
    }
}

/// '대화 찾아서 추가…': 검색해서 고르면 우클릭한 자리에 놓는다
struct AddConversationSheet: View {
    @EnvironmentObject var store: GraphStore
    @Environment(\.dismiss) private var dismiss
    let at: CGPoint
    @State private var query = ""

    private var shown: [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? store.sessions : store.sessions.filter { s in
            [store.title(s.id), s.title, s.firstPrompt ?? "", s.lastPrompt ?? "", s.cwd ?? ""].contains { $0.lowercased().contains(q) }
                || s.id.hasPrefix(q)
        }
        return Array(list.prefix(200))
    }

    var body: some View {
        let items = shown
        VStack(alignment: .leading, spacing: 10) {
            Text("여기에 대화 추가").font(.headline)
            TextField("제목·내용·폴더 검색 (Return = 맨 위 대화)", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let f = items.first { pick(f.id) } }
            // List 는 첫 클릭을 표가 가져가므로 버튼 목록으로
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { s in
                        PickRow(session: s, title: store.title(s.id), inGraph: store.isHere(s.id), elsewhere: store.otherSpaceName(s.id)) { pick(s.id) }
                    }
                }
            }
            .frame(height: 320)
            .overlay {
                if items.isEmpty { Text("맞는 대화가 없어요").foregroundStyle(.secondary) }
            }
            HStack {
                Text("이미 그래프에 있는 대화를 고르면 이 자리로 옮겨요")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func pick(_ id: String) {
        CanvasViewport.shared.touched()
        store.addNode(id, at: at)
        dismiss()
    }
}

private struct PickRow: View {
    let session: SessionInfo
    let title: String
    let inGraph: Bool
    let elsewhere: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SessionRow(session: session, title: title, inGraph: inGraph, elsewhere: elsewhere)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
