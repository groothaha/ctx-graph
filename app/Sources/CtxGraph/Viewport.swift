import AppKit
import SwiftUI

/// 그래프 화면의 확대 배율과 위치. 화면 좌표 = 그래프 좌표 × zoom + pan.
/// 끌 때마다 바뀌므로 GraphStore 와 따로 둔다 (사이드바 같은 다른 화면이 같이 다시 그려지지 않게).
@MainActor
final class CanvasViewport: ObservableObject {
    static let shared = CanvasViewport()

    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var pan: CGPoint = .zero
    private(set) var size: CGSize = .zero
    /// 그래프 칸이 창 안에서 차지하는 자리 (창 내용 좌표, 왼쪽 위 기준)
    var frameInWindow: CGRect = .zero

    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 2.5

    weak var store: GraphStore?
    /// 공간마다 마지막으로 보던 배율·위치
    private var saved: [String: (CGFloat, CGPoint)] = [:]
    /// 아직 사용자가 화면을 움직이지 않았으면 노드가 생길 때 전부 보이게 맞춘다
    private var needsFit = true
    /// 빈 곳을 우클릭한 자리 (화면 좌표). 메뉴에서 고르면 여기에 노드를 놓는다
    var menuPoint: CGPoint?
    /// '대화 찾아서 추가…' 창 (놓을 그래프 좌표)
    struct AddTarget: Identifiable { let id = UUID(); let point: CGPoint }
    @Published var addTarget: AddTarget?

    func menuWorldPoint() -> CGPoint {
        toWorld(menuPoint ?? CGPoint(x: size.width / 2, y: size.height / 2))
    }

    func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }
    func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y) }

    func attach(_ store: GraphStore) { self.store = store }

    func resize(_ s: CGSize) {
        guard s != size else { return }
        size = s
        fitIfNeeded()
    }

    /// 사용자가 직접 화면을 만졌다 (이후로는 자동으로 맞추지 않음)
    func touched() { needsFit = false }

    func setPan(_ p: CGPoint) { pan = clamped(p, zoom) }

    /// at: 화면 좌표 (그 점이 그대로 있도록 확대). nil 이면 가운데.
    func zoom(by f: CGFloat, at p: CGPoint? = nil) {
        guard f.isFinite, f > 0 else { return }
        setZoom(zoom * f, at: p)
    }

    func setZoom(_ z: CGFloat, at p: CGPoint? = nil) {
        let nz = min(max(z, Self.minZoom), Self.maxZoom)
        guard nz != zoom else { return }
        let c = p ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let k = nz / zoom
        let np = CGPoint(x: c.x - (c.x - pan.x) * k, y: c.y - (c.y - pan.y) * k)
        zoom = nz
        pan = clamped(np, nz)
        touched()
    }

    /// 단계 확대·축소 (버튼·메뉴)
    func step(_ d: Int) { zoom(by: d > 0 ? 1.25 : 1 / 1.25) }

    /// 노드 전부가 보이게 (100% 보다 키우지는 않음)
    func fit() {
        guard size.width > 0, size.height > 0 else { return }
        let fs = (store?.nodes.map(\.frame) ?? []) + (store?.ghosts.map { Layout.frame(at: $0.point) } ?? [])
        guard !fs.isEmpty else {
            zoom = 1
            pan = .zero
            return
        }
        let box = fs.dropFirst().reduce(fs[0]) { $0.union($1) }.insetBy(dx: -60, dy: -60)
        let z = min(1, size.width / box.width, size.height / box.height)
        let nz = min(max(z, Self.minZoom), Self.maxZoom)
        zoom = nz
        pan = clamped(CGPoint(x: size.width / 2 - box.midX * nz, y: size.height / 2 - box.midY * nz), nz)
        needsFit = false
    }

    func fitIfNeeded() {
        guard needsFit, size.width > 0, let store, !store.nodes.isEmpty else { return }
        fit()
    }

    /// 노드가 화면 밖에 있으면 그 노드를 가운데로
    func reveal(_ id: String) {
        guard size.width > 0, let n = store?.nodes.first(where: { $0.id == id }) else { return }
        let f = n.frame
        let r = CGRect(origin: toScreen(f.origin), size: CGSize(width: f.width * zoom, height: f.height * zoom))
        guard !CGRect(origin: .zero, size: size).intersects(r) else { return }
        pan = clamped(CGPoint(x: size.width / 2 - n.point.x * zoom, y: size.height / 2 - n.point.y * zoom), zoom)
    }

    func spaceChanged(from old: String, to new: String) {
        saved[old] = (zoom, pan)
        if let (z, p) = saved[new] {
            zoom = z
            pan = clamped(p, z)
            needsFit = false
        } else {
            needsFit = true
            zoom = 1
            pan = .zero
            fitIfNeeded()
        }
    }

    /// 그래프 판이 적어도 조금(100pt)은 화면에 남게
    private func clamped(_ p: CGPoint, _ z: CGFloat) -> CGPoint {
        guard size.width > 0 else { return p }
        let w = store?.worldRect ?? CGRect(origin: .zero, size: Layout.canvas), m: CGFloat = 100
        func fit(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo <= hi ? min(max(v, lo), hi) : (lo + hi) / 2 }
        // 정수 pt 로 (그래프가 소수점 픽셀에 그려지면 글자가 번진다)
        return CGPoint(x: fit(p.x, m - w.maxX * z, size.width - m - w.minX * z),
                       y: fit(p.y, m - w.maxY * z, size.height - m - w.minY * z)).snapped
    }
}

/// 왼쪽 아래: − 100% + | 전부 보기
struct ZoomControls: View {
    @ObservedObject private var vp = CanvasViewport.shared

    var body: some View {
        HStack(spacing: 0) {
            Button { vp.step(-1) } label: {
                Image(systemName: "minus").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .help("축소 (⌥⌘−) — 스크롤해도 돼요")
            .accessibilityLabel("축소")
            Button { vp.setZoom(1) } label: {
                Text("\(Int((vp.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 42, height: 26)
                    .contentShape(Rectangle())
            }
            .help("100%로 (⌥⌘1)")
            .accessibilityLabel("배율 \(Int((vp.zoom * 100).rounded()))%, 100%로 되돌리기")
            Button { vp.step(1) } label: {
                Image(systemName: "plus").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .help("확대 (⌥⌘=) — 스크롤해도 돼요")
            .accessibilityLabel("확대")
            Divider().frame(height: 14)
            Button { vp.fit() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .help("노드 전부 보기 (⌥⌘0)")
            .accessibilityLabel("노드 전부 보기")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.ring))
    }
}
