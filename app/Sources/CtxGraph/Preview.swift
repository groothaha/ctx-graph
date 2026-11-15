import AppKit
import SwiftUI

/// 노드 인스펙터: 이 대화에서 다음 메시지를 보낼 때 들어갈 맥락 (미리보기 — 기록하지 않음).
/// 받는 맥락마다 전체 요약 / 바뀐 부분만 / 이미 받음 / 요약 없음, 그리고 실제로 들어갈 글 전체.
struct InjectionPreviewSection: View {
    @EnvironmentObject var store: GraphStore
    @ObservedObject private var fs = FlowStatus.shared
    let node: GraphNode
    @State private var preview: GraphStore.InjectionPreview?
    @State private var loading = false
    @State private var showText = false

    /// 들어오는 요약 버전·받은 버전이 바뀌면 다시 불러온다
    private var key: String {
        node.id + "|" + store.sources(node.id).map { src in
            "\(src):\(store.node(src)?.version ?? 0):\(fs.received[Link(src: src, dst: node.id).id]?.version ?? -1)"
        }.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("다음 메시지에 들어갈 맥락", systemImage: "text.badge.plus").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("다시 불러오기")
                    .accessibilityLabel("미리보기 다시 불러오기")
            }
            if let p = preview {
                ForEach(p.items, id: \.src) { row($0) }
                ForEach(p.gone, id: \.self) { g in
                    Text("«\(Fmt.oneLine(g, 24))» — 연결이 끊겼다는 안내가 한 번 들어가요")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Text(p.text == nil ? String(localized: "새로 들어갈 내용이 없어요 — 다 받은 상태예요")
                                       : String(localized: "\(p.chars.formatted())자") + (p.chars > p.budget ? String(localized: " (\(p.budget.formatted())자에서 잘라 넣어요)") : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.meta)
                        .monospacedDigit()
                    Spacer()
                    if p.text != nil {
                        Button("내용 보기") { showText = true }.controlSize(.small)
                    }
                }
            } else if !loading {
                Text("미리보기를 불러오지 못했어요").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .task(id: key) { await load() }
        .sheet(isPresented: $showText) {
            PreviewSheet(title: String(localized: "«\(Fmt.oneLine(store.title(node.id), 30))» 다음 메시지에 들어갈 맥락"),
                         text: preview?.text ?? "")
        }
    }

    private func load() async {
        loading = true
        preview = await store.preview(node.id)
        loading = false
    }

    private func row(_ i: GraphStore.InjectionPreview.Item) -> some View {
        let (icon, text, tint): (String, String, Color) = {
            switch i.mode {
            case "full": return ("doc.text", String(localized: "전체 요약 v\(i.version)"), Ink.flowText)
            case "delta": return ("plus.forwardslash.minus", String(localized: "바뀐 부분만 (v\(i.version - 1) → v\(i.version))"), Ink.flowText)
            case "same": return ("checkmark", String(localized: "이미 받음 (v\(i.version)) — 안 들어가요"), Ink.meta)
            default: return ("circle.dashed", String(localized: "아직 요약이 없어요"), Ink.meta)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).frame(width: 14)
            Text("«\(Fmt.oneLine(i.title, 22))»").font(.system(size: 12)).lineLimit(1)
            Text(text).font(.system(size: 12)).foregroundStyle(tint).lineLimit(1)
        }
    }
}

/// 미리보기 전체 글 (선택·복사 가능)
struct PreviewSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            Text("메시지를 보내면 Claude 에게 '추가 맥락'으로 같이 들어가요 (대화 화면에는 안 보여요). 미리보기는 아무것도 기록하지 않아요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 660, height: 540)
    }
}
