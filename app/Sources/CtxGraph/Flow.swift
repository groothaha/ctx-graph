import Foundation
import SwiftUI

/// 맥락 전달 상태 (보내는 쪽 대화 → 요약 → 받는 쪽 대화). 2초마다 GraphStore.reloadGraph 가 갱신.
/// 자주 바뀌므로 GraphStore 와 따로 둔다 (사이드바가 같이 다시 그려지지 않게).
@MainActor
final class FlowStatus: ObservableObject {
    static let shared = FlowStatus()

    /// 받는 쪽이 받은 요약 (injections 테이블)
    struct Received: Equatable {
        let version: Int
        let at: Double            // 받은 시각
        let srcAt: Double?        // 그 요약이 담은 보내는 쪽의 마지막 메시지 시각
    }
    /// 보내는 쪽 대화 기록 파일
    struct Activity: Equatable {
        let size: Int
        let mtime: Double
        let hasNew: Bool          // 요약 뒤로 새 대화 내용이 붙었음
    }

    /// 방금 들어간 맥락 — 선 위 물결·화살촉·터미널 위 줄 강조를 한 번 보여 준다
    struct Arrival: Equatable {
        let version: Int
        let at: Double            // 앱이 알아챈 시각
    }
    /// 물결이 선을 지나는 시간, 도착 뒤 강조가 남는 시간 (초). CTXGRAPH_SLOWMO=배수 면 느리게 (화면 점검·데모 녹화)
    static let slow: Double = Double(ProcessInfo.processInfo.environment["CTXGRAPH_SLOWMO"] ?? "") ?? 1
    static let sweep: Double = 0.95 * slow
    static let afterglow: Double = 1.7 * slow

    @Published private(set) var received: [String: Received] = [:]   // Link.id
    @Published private(set) var activity: [String: Activity] = [:]   // 보내는 노드 id
    @Published private(set) var arrivals: [String: Arrival] = [:]    // Link.id
    private var newCache: [String: (size: Int, from: Int, hasNew: Bool)] = [:]
    private var loaded = false

    /// 받은 버전이 새로 생기거나 올라간 연결 = 방금 맥락이 들어감 (처음 읽을 때·오래된 기록은 빼고)
    private func noteArrivals(_ rec: [String: Received]) {
        let now = Date().timeIntervalSince1970
        var fresh: [String: Arrival] = [:]
        if loaded {
            for (id, r) in rec where r.at > now - 15 && r.version > (received[id]?.version ?? -1) {
                fresh[id] = Arrival(version: r.version, at: now)
            }
        }
        loaded = true
        guard !fresh.isEmpty else { return }
        if ProcessInfo.processInfo.environment["CTXGRAPH_DEBUG"] != nil {
            FileHandle.standardError.write(Data("arrival \(fresh.keys.sorted()) at \(now)\n".utf8))
        }
        arrivals.merge(fresh) { $1 }
        let life = Self.sweep + Self.afterglow + 0.2
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(life * 1e9))
            self?.pruneArrivals()
        }
    }

    private func pruneArrivals() {
        let now = Date().timeIntervalSince1970
        let kept = arrivals.filter { now - $0.value.at < Self.sweep + Self.afterglow }
        if kept != arrivals { arrivals = kept }
    }

    /// 화면 점검용: 이 연결에 맥락이 막 들어간 것처럼
    func simulateArrival(_ id: String, version: Int) {
        arrivals[id] = Arrival(version: version, at: Date().timeIntervalSince1970)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.sweep + Self.afterglow + 0.2) * 1e9))
            self?.pruneArrivals()
        }
    }

    func reload(_ db: SQLiteDB, nodes: [GraphNode], links: [Link]) {
        var rec: [String: Received] = [:]
        db.query("SELECT target, source, version, at, src_at FROM injections") { r in
            guard let t = r.text(0), let s = r.text(1) else { return }
            rec[Link(src: s, dst: t).id] = Received(version: r.int(2), at: r.double(3) ?? 0, srcAt: r.double(4))
        }
        var act: [String: Activity] = [:]
        let senders = Set(links.map(\.src))
        for n in nodes where senders.contains(n.id) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: n.transcriptPath),
                  let size = (a[.size] as? NSNumber)?.intValue,
                  let m = a[.modificationDate] as? Date else { continue }
            act[n.id] = Activity(size: size, mtime: m.timeIntervalSince1970,
                                 hasNew: hasNewMessages(n.id, n.transcriptPath, from: n.srcSize, size: size))
        }
        noteArrivals(rec)
        if rec != received { received = rec }
        if act != activity { activity = act }
    }

    /// 요약이 읽은 곳(from) 뒤에 사람·Claude 의 글이 있는지 (도구 결과·메타 줄만 붙은 건 새 대화가 아님)
    private func hasNewMessages(_ id: String, _ path: String, from: Int, size: Int) -> Bool {
        guard size > from else { return false }
        if let c = newCache[id], c.size == size, c.from == from { return c.hasNew }
        var found = size - from > 4_000_000          // 너무 많이 붙었으면 읽지 않고 새 내용으로 본다
        if !found, let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            try? fh.seek(toOffset: UInt64(from))
            if let data = try? fh.read(upToCount: size - from) {
                for line in data.split(separator: UInt8(ascii: "\n")) {
                    let s = String(decoding: line, as: UTF8.self)
                    if (s.contains("\"type\":\"user\"") && !s.contains("\"tool_result\"") && !s.contains("\"isMeta\":true"))
                        || (s.contains("\"type\":\"assistant\"") && s.contains("\"type\":\"text\"")) {
                        found = true
                        break
                    }
                }
            }
        }
        newCache[id] = (size, from, found)
        return found
    }
}

/// 화살표 하나(보내는 쪽 S → 받는 쪽 T)의 전달 상태
struct Flow {
    enum Stage {
        case noSummary      // S 요약 없음
        case failed         // S 요약 실패
        case summarizing    // S 요약 만드는 중
        case sourceActive   // S 대화가 진행 중 (응답이 끝나면 요약 예약)
        case scheduled      // S 요약 갱신 예약됨 (S 가 잠잠해지고 2분 간격이 지나면)
        case stale          // S 에 새 대화가 있는데 갱신 예약이 없음
        case ready          // 새 요약이 준비됨 — T 에서 다음 메시지를 보낼 때 들어감
        case delivered      // T 가 S 의 최신 내용까지 받음
    }
    let stage: Stage
    let version: Int                 // S 요약 버전
    let received: FlowStatus.Received?
    let sourceLast: Double?          // S 의 마지막 대화 시각
    let summaryUpTo: Double?         // 지금 요약이 담은 S 의 마지막 시각
    let eta: Double?                 // 예약된 요약이 시작될 예상 시각

    /// T 가 아는 S 가 S 의 최신보다 얼마나 뒤처졌는지 (초). nil = 아직 아무것도 안 받음
    var lag: Double? {
        if stage == .delivered { return 0 }
        guard let r = received else { return nil }
        guard let known = r.srcAt, let latest = sourceLast ?? summaryUpTo else { return nil }
        return max(0, latest - known)
    }

    var done: Bool { stage == .delivered }

    /// 화살표 위 배지에 쓰는 짧은 글
    func short(now: Double) -> String {
        if done { return String(localized: "✓ 최신") }
        let head: String
        if received == nil { head = String(localized: "아직 안 받음") }
        else if let l = lag { head = String(localized: "\(Fmt.duration(l)) 차") }
        else { head = String(localized: "v\(received!.version) 받음") }
        return head + " · " + stageText(now: now, short: true)
    }

    /// 화살표가 짧아 긴 배지가 노드를 가릴 때
    func tiny(now: Double) -> String {
        switch stage {
        case .delivered: return "✓"
        case .ready: return String(localized: "v\(version) 대기")
        case .scheduled:
            guard let eta else { return String(localized: "대기") }
            return eta - now > 1 ? Fmt.clock(eta - now) : String(localized: "곧")
        case .summarizing: return String(localized: "요약 중")
        case .sourceActive: return String(localized: "진행 중")
        case .stale: return "!"
        case .failed: return String(localized: "실패")
        case .noSummary: return "—"
        }
    }

    /// 배지 글 폭 어림 (10pt 글자: 한글 ≈ 10.5, 영문·숫자 ≈ 6.2, 좌우 여백 포함)
    static func badgeWidth(_ s: String) -> CGFloat {
        s.unicodeScalars.reduce(CGFloat(16)) { $0 + ($1.isASCII ? 6.2 : 10.5) }
    }

    func stageText(now: Double, short: Bool = false) -> String {
        switch stage {
        case .noSummary: return String(localized: "요약 없음")
        case .failed: return String(localized: "요약 실패")
        case .summarizing: return version == 0 ? String(localized: "요약 만드는 중") : String(localized: "요약 갱신 중")
        case .sourceActive: return short ? String(localized: "대화 진행 중") : String(localized: "보내는 쪽 대화가 진행 중 — 응답이 끝나면 요약을 갱신해요")
        case .scheduled:
            guard let eta else { return String(localized: "요약 대기") }
            let left = eta - now
            return left > 1 ? String(localized: "요약까지 \(Fmt.clock(left))") : String(localized: "곧 요약")
        case .stale: return short ? String(localized: "갱신 안 됨") : String(localized: "새 대화가 요약에 반영되지 않았어요 — '지금 요약'을 누르세요")
        case .ready: return short ? String(localized: "다음 메시지 때 v\(version)") : String(localized: "v\(version) 준비됨 — 받는 쪽에서 메시지를 보내면 들어가요")
        case .delivered: return String(localized: "최신 내용까지 전달됨")
        }
    }

    var color: Color {
        switch stage {
        case .delivered: return Ink.flow
        case .ready, .scheduled, .summarizing: return Ink.flowText
        case .failed, .stale: return Ink.fail
        default: return .secondary
        }
    }

    /// 선 위 글자 색 (다 받았으면 글자 없음)
    var labelColor: Color {
        switch stage {
        case .failed: return Ink.fail
        case .ready, .scheduled, .summarizing: return Ink.flowText
        default: return Ink.meta
        }
    }

    /// 여러 개 중 가장 급한 것 고르기: 실패 > 갱신 안 됨 > 요약 없음 > 뒤처진 시간 > 준비됨
    var urgency: Double {
        switch stage {
        case .failed: return 4e12
        case .stale: return 3e12
        case .noSummary: return 2e12
        case .ready: return -1
        case .delivered: return -2
        default: return lag ?? 1e12
        }
    }
}

extension GraphStore {
    /// 요약 작업의 대기 조건 (ctxgraph.py 의 QUIET·COOLDOWN 과 같게)
    static let summaryQuiet: Double = 20
    static let summaryCooldown: Double = 120

    func flow(_ l: Link, _ fs: FlowStatus) -> Flow? {
        guard let s = node(l.src) else { return nil }
        let r = fs.received[l.id]
        let a = fs.activity[l.src]
        let hasNew = a?.hasNew ?? false
        let sourceLast = hasNew ? a?.mtime : (s.srcAt ?? s.summaryAt)
        let now = Date().timeIntervalSince1970
        var eta: Double?
        let stage: Flow.Stage
        if s.version == 0 {
            if s.summarizing || isBusy(s.id) { stage = .summarizing }
            else if s.summaryError != nil { stage = .failed }
            else { stage = .noSummary }
        } else if hasNew {
            if s.summarizing || isBusy(s.id) { stage = .summarizing }
            else if s.jobPending {
                stage = .scheduled
                eta = max((a?.mtime ?? now) + Self.summaryQuiet, (s.summaryAt ?? 0) + Self.summaryCooldown)
            } else if let m = a?.mtime, now - m < 120 { stage = .sourceActive }
            else { stage = .stale }
        } else if r == nil || r!.version < s.version {
            stage = .ready
        } else {
            stage = .delivered
        }
        return Flow(stage: stage, version: s.version, received: r, sourceLast: sourceLast,
                    summaryUpTo: s.srcAt ?? s.summaryAt, eta: eta)
    }
}

/// 인스펙터: S → T 한 방향의 단계별 진행 (① S 대화 ② 요약 ③ T 가 받음)
struct FlowSteps: View {
    @EnvironmentObject var store: GraphStore
    @ObservedObject private var fs = FlowStatus.shared
    let link: Link

    var body: some View {
        if let f = store.flow(link, fs) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                content(f, ctx.date.timeIntervalSince1970)
            }
        }
    }

    private func content(_ f: Flow, _ now: Double) -> some View {
        let s = store.title(link.src), t = store.title(link.dst)
        let sNode = store.node(link.src)
        // ① 보내는 쪽 대화
        let d1: String = f.sourceLast.map { Fmt.time($0) + " (" + Fmt.ago($0) + ")" } ?? "—"
        let s1: StepState = f.stage == .sourceActive ? .active : .done
        // ② 요약
        let t2: String = f.version > 0 ? String(localized: "요약 v\(f.version)") : String(localized: "요약")
        var d2 = String(localized: "아직 없음")
        if f.version > 0 {
            d2 = (f.summaryUpTo.map { String(localized: "\(Fmt.time($0)) 까지 담음") } ?? "")
            if let at = sNode?.summaryAt { d2 += " · " + String(localized: "\(Fmt.time(at)) 만듦") }
        }
        let upstream: [Flow.Stage] = [.summarizing, .scheduled, .stale, .failed, .noSummary, .sourceActive]
        let n2: String? = upstream.contains(f.stage) ? f.stageText(now: now) : nil
        let s2: StepState = [.ready, .delivered].contains(f.stage) ? .done
            : ([.stale, .failed].contains(f.stage) ? .warn : .active)
        // ③ 받는 쪽
        var d3 = String(localized: "아직 안 받음")
        if let r = f.received {
            d3 = "v\(r.version)"
            if let sa = r.srcAt { d3 += " · " + String(localized: "\(Fmt.time(sa)) 까지 내용") }
            d3 += " · " + String(localized: "\(Fmt.time(r.at)) 받음")
        }
        let n3: String? = f.stage == .ready ? f.stageText(now: now) : nil
        let s3: StepState = f.done ? .done : (f.stage == .ready ? .active : .idle)
        let title = "«\(Fmt.oneLine(s, 16))» → «\(Fmt.oneLine(t, 16))»"
        return VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            step(String(localized: "보내는 쪽 마지막 대화"), d1, state: s1)
            step(t2, d2, note: n2, state: s2)
            step(String(localized: "받는 쪽이 받은 것"), d3, note: n3, state: s3)
            lagRow(f, t)
            if [.stale, .failed, .noSummary].contains(f.stage) {
                Button("지금 요약") { store.summarize(link.src, force: false) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func lagRow(_ f: Flow, _ t: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: f.done ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(f.done ? Ink.flow : Color.secondary)
            Text(lagSentence(f, t))
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func lagSentence(_ f: Flow, _ t: String) -> String {
        if f.done { return String(localized: "최신 내용까지 전달됐어요") }
        guard f.received != nil else { return String(localized: "«\(Fmt.oneLine(t, 14))»는 아직 이 맥락을 받지 않았어요") }
        if let l = f.lag { return String(localized: "«\(Fmt.oneLine(t, 14))»가 아는 내용은 \(Fmt.duration(l)) 뒤처져 있어요") }
        return String(localized: "받은 뒤로 새 내용이 있어요")
    }

    enum StepState { case done, active, warn, idle }

    private func step(_ title: String, _ detail: String, note: String? = nil, state: StepState) -> some View {
        let icon: String
        let tint: Color
        switch state {
        case .done: icon = "checkmark.circle.fill"; tint = Ink.flow
        case .warn: icon = "exclamationmark.circle.fill"; tint = Ink.fail
        case .active: icon = "circle.dotted"; tint = Ink.flowText
        case .idle: icon = "circle"; tint = .secondary
        }
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(state == .warn ? Ink.fail : Ink.flowText)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension Fmt {
    /// 3초, 4분, 1시간 5분, 2일
    static func duration(_ s: Double) -> String {
        let s = max(0, s)
        if s < 60 { return String(localized: "\(Int(s))초") }
        if s < 3600 { return String(localized: "\(Int(s / 60))분") }
        if s < 86400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? String(localized: "\(h)시간 \(m)분") : String(localized: "\(h)시간")
        }
        return String(localized: "\(Int(s / 86400))일")
    }

    /// 남은 시간 1:05
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.up))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// 오늘이면 14:03:12, 아니면 11/04 20:14
    static func time(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.locale = AppLang.locale
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "MM/dd HH:mm"
        return f.string(from: d)
    }
}

/// 터미널 위 줄: 받는 맥락마다 전달 상태 («A» ✓ 최신 · «B» 3분 차 · 다음 메시지 때 v2)
struct IncomingFlows: View {
    @EnvironmentObject var store: GraphStore
    @ObservedObject private var fs = FlowStatus.shared
    let target: String
    let sources: [String]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date.timeIntervalSince1970
            HStack(spacing: 8) {
                Text("받는 맥락:")
                ForEach(sources, id: \.self) { src in
                    let l = Link(src: src, dst: target)
                    let f = store.flow(l, fs)
                    let fresh = fs.arrivals[l.id].flatMap { a in
                        now - a.at < FlowStatus.sweep + FlowStatus.afterglow ? a : nil
                    }
                    HStack(spacing: 3) {
                        Text("«\(Fmt.oneLine(store.title(src), 18))»").lineLimit(1)
                        if let a = fresh {
                            Text("v\(a.version) 들어옴")
                                .fontWeight(.semibold)
                                .foregroundStyle(Ink.flowText)
                                .monospacedDigit()
                                .fixedSize()
                        } else if let f {
                            Text(f.short(now: now))
                                .foregroundStyle(f.done ? Color.secondary : f.labelColor)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, fresh != nil ? 5 : 0)
                    .background(Capsule().fill(fresh != nil ? Ink.flow.opacity(0.18) : .clear))
                    .help(f.map { "«\(store.title(src))»: " + $0.stageText(now: now) } ?? "")
                    .onTapGesture { store.selection = .edge(l.id) }
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
}

/// 노드 카드 셋째 줄: 받는 맥락 중 아직 덜 온 게 있을 때만 (여러 개면 가장 급한 것 기준).
/// 다 받았으면 카드에는 아무것도 안 쓰고, 화살표 끝 화살촉이 채워진 걸로 보인다.
struct IncomingStatus: View {
    let items: [(title: String, flow: Flow)]

    static func needed(_ items: [(title: String, flow: Flow)]) -> Bool { items.contains { !$0.flow.done } }

    var body: some View {
        if items.contains(where: { $0.flow.stage == .scheduled }) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in row(ctx.date.timeIntervalSince1970) }
        } else {
            row(Date().timeIntervalSince1970)
        }
    }

    private func row(_ now: Double) -> some View {
        let pending = items.filter { !$0.flow.done }
        let worst = pending.max { $0.flow.urgency < $1.flow.urgency }?.flow
        let n = items.count
        let head = n > 1 ? String(localized: "\(n - pending.count)/\(n) 받음 · ") : ""
        let text = head + (worst?.stageText(now: now, short: true) ?? "")
        return HStack(spacing: 4) {
            Image(systemName: "arrow.left").font(.system(size: 9, weight: .semibold))
            // 카드 폭에 안 들어가면 ("1/2 received · v3 on next message") 선 배지와 같은 짧은 말로
            ViewThatFits(in: .horizontal) {
                Text(text).lineLimit(1)
                Text(head + (worst?.tiny(now: now) ?? "")).lineLimit(1)
            }
            .monospacedDigit()
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(worst?.labelColor ?? Ink.meta)
        .help(items.map { i in
            String(localized: "«\(i.title)» → 이 대화: ") + i.flow.stageText(now: now)
                + (i.flow.done ? "" : i.flow.lag.map { String(localized: " (\(Fmt.duration($0)) 뒤처짐)") } ?? String(localized: " (아직 안 받음)"))
        }.joined(separator: "\n"))
        .accessibilityLabel(String(localized: "받는 맥락 ") + text)
    }
}
