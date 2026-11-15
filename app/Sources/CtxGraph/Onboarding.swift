import SwiftUI

/// 그래프가 비었을 때의 시작 안내: ① Claude Code ② 맥락 연결(훅) 켜기 ③ 대화 끌어 놓고 잇기.
/// 왼쪽의 세로선이 단계마다 차오른다 (캔버스의 '선이 찬 만큼 왔다'와 같은 말).
struct Onboarding: View {
    @EnvironmentObject var store: GraphStore
    let dropping: Bool

    private var claudeOK: Bool { store.pythonOK && store.hooks?.claude != nil }
    private var hooksOK: Bool { store.hooks?.ok ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(dropping ? "놓으면 그래프에 추가돼요" : "대화를 이으면 맥락이 흘러요")
                    .font(.system(size: 20, weight: .semibold))
                Text("A → B 로 이으면, B 에서 메시지를 보낼 때마다 A 의 최신 요약이 같이 들어가요.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !store.pythonOK {
                    // python3 가 없으면 아무것도 확인할 수 없다 — 이것부터
                    step(1, done: false, last: false, failed: true,
                         title: "Python 3",
                         detail: String(localized: "CtxGraph 의 백엔드는 Python 3 으로 돌아요. macOS 개발자 도구(Command Line Tools)에 들어 있어요 — 설치한 뒤 '다시 확인'을 눌러 주세요.")) {
                        Button("개발자 도구 설치") { PythonRuntime.installDeveloperTools() }.controlSize(.small)
                        Button("다시 확인") { Task { await store.recheckRuntime() } }.controlSize(.small)
                    }
                } else if let err = store.backendError {
                    step(1, done: false, last: false, failed: true, title: "Claude Code", detail: err) {
                        Button("다시 확인") { Task { await store.recheckRuntime() } }.controlSize(.small)
                    }
                } else {
                    step(1, done: claudeOK, last: false, failed: store.hooks != nil && !claudeOK,
                         title: "Claude Code",
                         detail: store.hooks == nil ? String(localized: "확인하는 중…")
                            : (store.hooks?.claude.map { String(localized: "찾았어요 · ") + Fmt.shortPath($0) }
                               ?? String(localized: "claude 명령을 찾지 못했어요 — Claude Code 를 먼저 설치해 주세요"))) {
                        if store.hooks != nil, !claudeOK {
                            Button("다시 확인") { Task { await store.recheckRuntime() } }.controlSize(.small)
                        }
                    }
                }
                step(2, done: hooksOK, last: false,
                     title: String(localized: "맥락 연결 켜기"),
                     detail: hooksOK ? String(localized: "켜져 있어요") : String(localized: "~/.claude/settings.json 에 훅을 넣어요. 원래 파일은 옆에 백업해요.")) {
                    if !hooksOK, claudeOK {
                        Button(store.hooks?.stale == true ? "경로 고치기" : "켜기") { Task { await store.setHooks(true) } }
                            .controlSize(.small)
                            .disabled(store.hookBusy || store.hooks?.error != nil)
                    }
                }
                step(3, done: false, last: true,
                     title: String(localized: "대화 두 개를 끌어 놓고 잇기"),
                     detail: String(localized: "왼쪽 목록에서 끌어 놓거나 빈 곳을 우클릭하세요. 카드의 ⊕ 를 다른 카드로 끌면 화살표가 생겨요. 카드를 더블클릭하면 오른쪽 터미널에서 이어서 써요.")) { EmptyView() }
            }
            if let err = store.hooks?.error {
                Text(err).font(.system(size: 12)).foregroundStyle(Ink.fail)
            }
        }
        .padding(28)
        .frame(width: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.ring))
    }

    private func step<Accessory: View>(_ n: Int, done: Bool, last: Bool, failed: Bool = false, title: String, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    if done {
                        Circle().fill(Ink.flow)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.basin)
                    } else if failed {
                        Circle().strokeBorder(Ink.fail, lineWidth: 2)
                        Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.fail)
                    } else {
                        Circle().strokeBorder(Ink.pipe, lineWidth: 2)
                        Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.meta)
                    }
                }
                .frame(width: 22, height: 22)
                if !last {
                    // 다음 단계까지의 선: 끝낸 단계면 차 있고, 아니면 점선
                    Rectangle()
                        .fill(done ? Ink.flow : .clear)
                        .overlay {
                            if !done {
                                Line().stroke(Ink.pipe, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 4]))
                            }
                        }
                        .frame(width: 2)
                        .frame(minHeight: 18, maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    accessory()
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.meta)          // 막힌 단계는 빨간 고리로만 — 긴 설명까지 빨갛게 하지 않는다
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, last ? 0 : 16)
        }
        // 줄 높이는 글 쪽이 정하고, 왼쪽 연결선은 그 높이만큼만 늘어나게
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(n)단계 \(title): \(done ? String(localized: "완료") : detail)")
    }
}

/// 세로선 하나 (점선용)
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

/// 캔버스 위쪽 알림: 훅이 꺼졌을 때(노드가 있을 때만), Claude Code 형식이 바뀐 것 같을 때
struct CanvasNotices: View {
    @EnvironmentObject var store: GraphStore
    let hasNodes: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let v = store.newerData {
                NoticeCapsule(text: String(localized: "이 데이터는 더 새 CtxGraph 가 만든 형식이에요 (v\(v)) — 앱을 업데이트해 주세요. 그동안은 보기만 하고 고치지 않아요."))
            }
            if hasNodes {
                if !store.pythonOK {
                    NoticeCapsule(text: String(localized: "python3 를 찾지 못했어요 — 맥락이 흐르지 않아요")) {
                        Button("다시 확인") { Task { await store.recheckRuntime() } }
                    }
                } else if let err = store.backendError {
                    NoticeCapsule(text: err) {
                        Button("다시 확인") { Task { await store.recheckRuntime() } }
                    }
                } else {
                    HookBanner()
                }
            }
            ForEach(store.health, id: \.self) { msg in
                NoticeCapsule(text: msg) {
                    Button("다시 확인") { Task { await store.rescan() } }
                }
            }
        }
    }
}

/// 캔버스 위 빨간 점 한 줄 알림
struct NoticeCapsule<Action: View>: View {
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Ink.fail).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).lineLimit(2)
            action().controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 640)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.card))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.ring))
    }
}

extension NoticeCapsule where Action == EmptyView {
    init(text: String) { self.init(text: text) { EmptyView() } }
}

/// 노드가 있는데 훅이 꺼져 있으면: 화살표가 있어도 맥락이 안 간다는 걸 알린다
struct HookBanner: View {
    @EnvironmentObject var store: GraphStore

    var body: some View {
        if let h = store.hooks, !h.ok {
            NoticeCapsule(text: h.stale ? String(localized: "훅이 예전 위치의 스크립트를 가리켜요 — 맥락이 안 갈 수 있어요")
                                        : (h.partial ? String(localized: "훅 일부가 빠져 있어요 — 맥락이 제대로 안 갈 수 있어요")
                                                     : String(localized: "맥락 연결(훅)이 꺼져 있어요 — 화살표가 있어도 맥락이 안 가요"))) {
                Button(h.stale || h.partial ? "고치기" : "켜기") { Task { await store.setHooks(true) } }
                    .disabled(store.hookBusy || h.error != nil)
            }
        }
    }
}

/// 설정 → Claude Code: 훅·/ctx 스킬 설치 상태와 켜기/끄기
struct HookSettings: View {
    @EnvironmentObject var store: GraphStore

    var body: some View {
        Form {
            Section {
                if !store.pythonOK {
                    LabeledContent("Python 3") {
                        Text("찾지 못함 — macOS 개발자 도구에 들어 있어요").foregroundStyle(Ink.fail)
                    }
                    Button("개발자 도구 설치") { PythonRuntime.installDeveloperTools() }
                }
                if let err = store.backendError {
                    Text(err).font(.system(size: 12)).foregroundStyle(Ink.fail).textSelection(.enabled)
                }
                if let v = store.newerData {
                    Text("이 데이터는 더 새 CtxGraph 가 만든 형식이에요 (v\(v)) — 앱을 업데이트해 주세요. 그동안은 보기만 하고 고치지 않아요.")
                        .font(.system(size: 12)).foregroundStyle(Ink.fail)
                }
                LabeledContent("상태") {
                    if !store.pythonOK || store.backendError != nil {
                        Text("확인할 수 없어요").foregroundStyle(Ink.fail)
                    } else if let h = store.hooks {
                        Text(h.ok ? "켜져 있어요" : (h.stale ? "예전 경로를 가리켜요" : (h.partial ? "일부만 들어 있어요" : "꺼져 있어요")))
                            .foregroundStyle(h.ok ? Color.primary : Ink.fail)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Claude Code") {
                    if store.hooks == nil {
                        Text("—").foregroundStyle(.secondary)          // 백엔드를 못 돌려 아직 모름
                    } else {
                        Text(store.hooks?.claude.map { Fmt.shortPath($0) + (store.hooks?.claude_version.map { " · " + $0 } ?? "") } ?? String(localized: "찾지 못함"))
                            .foregroundStyle(store.hooks?.claude == nil ? Ink.fail : Color.secondary)
                    }
                }
                ForEach(store.health, id: \.self) { msg in
                    Text(msg).font(.system(size: 12)).foregroundStyle(Ink.fail)
                }
                LabeledContent("설정 파일") {
                    Text(Fmt.shortPath(store.hooks?.settings)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("/ctx 명령") {
                    Text(skillText).foregroundStyle(.secondary)
                }
                if let err = store.hooks?.error {
                    Text(err).font(.system(size: 12)).foregroundStyle(Ink.fail)
                }
                HStack {
                    Group {
                        Button(store.hooks?.ok == true ? "다시 넣기" : "켜기") { Task { await store.setHooks(true) } }
                        Button("끄기 (훅 빼기)") { Task { await store.setHooks(false) } }
                            .disabled(!(store.hooks?.installed ?? false) && !(store.hooks?.partial ?? false))
                    }
                    .disabled(store.hookBusy || store.hooks == nil || store.hooks?.error != nil)
                    if store.hookBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("다시 확인") { Task { await store.recheckRuntime() } }
                        .disabled(store.hookBusy)
                }
            } header: {
                Text("맥락 연결 (Claude Code 훅)")
            } footer: {
                Text("켜면 UserPromptSubmit·Stop·SessionStart·Notification·PreToolUse 훅을 settings.json 에 넣고, 원래 파일은 옆에 백업해요. 끄면 CtxGraph 훅만 빼고 다른 훅·설정은 그대로 둬요. 그래프와 요약은 지워지지 않아요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                if !store.pythonOK || store.newerData != nil {
                    Text("—").foregroundStyle(.secondary)
                } else if let u = usage {
                    LabeledContent("오늘") { Text("\(u.today)회").monospacedDigit() }
                    LabeledContent("최근 7일") {
                        Text(String(localized: "\(u.week)회") + (u.failed_week > 0 ? String(localized: " (실패 \(u.failed_week))") : "")).monospacedDigit()
                    }
                    LabeledContent("최근 30일") { Text("\(u.month)회").monospacedDigit() }
                    LabeledContent("요약 모델") {
                        Text(store.model(store.summaryModelID)?.name ?? store.summaryModelID).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("요약 사용량")
            } footer: {
                Text("요약은 맥락을 보내는(나가는 화살표가 있는) 대화만, 턴이 끝나고 20초 잠잠해지고 이전 요약에서 2분이 지나면 새로 붙은 부분만 반영해 만들어요. 구독 모델이면 Claude Code 사용량에서 나가요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("실험 기능 보이기", isOn: Binding(get: { store.experimental },
                                                     set: { store.setSetting("experimental", $0 ? "1" : "0") }))
            } footer: {
                Text("대화마다 파일을 모을 '작업 폴더'와, 앱 터미널을 운영체제 샌드박스로 감싸는 '셸 명령 막기'. 아직 다듬는 중이라 기본으로 숨겨 둬요. 이미 켜 둔 대화에서는 늘 보여요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await store.refreshHooks()
            usage = await store.usage()
        }
    }

    @State private var usage: GraphStore.Usage?

    private var skillText: String {
        switch store.hooks?.skill {
        case "managed": return String(localized: "들어 있어요")
        case "custom": return String(localized: "직접 만든 /ctx 스킬이 있어 그대로 둬요")
        case "none": return String(localized: "켜면 같이 넣어요")
        default: return "—"
        }
    }
}
