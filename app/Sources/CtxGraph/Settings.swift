import SwiftUI

/// ⌘, 설정: 모델 프로필·요약 모델·API 키
struct SettingsView: View {
    @EnvironmentObject var store: GraphStore
    /// 화면 점검용: CTXGRAPH_SETTINGS_TAB=hooks|models|keys|terminal|places
    @State private var tab = ProcessInfo.processInfo.environment["CTXGRAPH_SETTINGS_TAB"] ?? "hooks"

    var body: some View {
        TabView(selection: $tab) {
            HookSettings()
                .tabItem { Label("Claude Code", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("hooks")
            ModelSettings()
                .tabItem { Label("모델", systemImage: "cpu") }
                .tag("models")
            KeySettings()
                .tabItem { Label("API 키", systemImage: "key") }
                .tag("keys")
            TerminalSettings()
                .tabItem { Label("터미널", systemImage: "terminal") }
                .tag("terminal")
            if store.experimental || !store.places.isEmpty {
                PlaceSettings()
                    .tabItem { Label("폴더", systemImage: "folder") }
                    .tag("places")
            }
        }
        .frame(width: 720, height: 560)
    }
}

// MARK: 터미널

struct TerminalSettings: View {
    @EnvironmentObject var store: GraphStore
    @EnvironmentObject var terms: TerminalManager

    var body: some View {
        Form {
            Section {
                Picker("글꼴", selection: Binding(get: { terms.face }, set: { terms.setFace($0) })) {
                    Text("D2Coding — 한글과 영문 폭이 정확히 2:1").tag(TermFont.d2coding)
                    Text("SF Mono — macOS 기본 (한글 사이가 조금 벌어져요)").tag(TermFont.system)
                }
                .pickerStyle(.radioGroup)
                .disabled(!TermFont.bundled)
                LabeledContent("글자 크기") {
                    Stepper("\(Int(terms.fontSize)) pt", value: Binding(get: { Double(terms.fontSize) },
                                                                        set: { terms.setFontSize(CGFloat($0)) }),
                            in: 9...28)
                    .monospacedDigit()
                }
                // 미리보기: 지금 고른 글꼴로
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "열려 있는 터미널에서 연달아 | abc 123")
                    Text(verbatim: "⏺ 고쳐서 설치했어요. Claude 의 답")
                }
                .font(Font(terms.face.font(terms.fontSize) as CTFont))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
            } footer: {
                Text("열린 터미널에도 바로 적용돼요. ⌘+ / ⌘− 로도 글자 크기를 바꿀 수 있어요. D2Coding © NAVER Corp., SIL Open Font License 1.1.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Claude 를 권한 확인 없이 실행 (--dangerously-skip-permissions)",
                       isOn: Binding(get: { store.skipPermissions }, set: { store.setSetting("skip_permissions", $0 ? "1" : "0") }))
            } footer: {
                Text("켜면 앱 터미널의 Claude 가 파일 수정·명령 실행을 묻지 않고 바로 해요. 믿을 수 있는 폴더에서만 켜세요. 새로 여는 대화부터 적용돼요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: 모델

struct ModelSettings: View {
    @EnvironmentObject var store: GraphStore
    @State private var selectedID: String?
    @State private var draft: ModelProfile?
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("새 대화 기본 모델", selection: Binding(
                    get: { store.defaultModelID }, set: { store.setSetting("default_model", $0) })) {
                    ForEach(store.models) { m in Text(label(m)).tag(m.id) }
                }
                Picker("맥락 요약 모델", selection: Binding(
                    get: { store.summaryModelID }, set: { store.setSetting("summary_model", $0) })) {
                    ForEach(store.models) { m in Text(label(m)).tag(m.id) }
                }
                Text("요약은 맥락을 보내는 대화가 한 턴 끝날 때마다 갱신돼요. 싸고 빠른 모델이 좋아요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .formStyle(.columns)

            Divider()

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 6) {
                    List(selection: $selectedID) {
                        ForEach(store.models) { m in
                            HStack(spacing: 6) {
                                Text(m.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if !store.isReady(m) {
                                    Image(systemName: "key.slash")
                                        .foregroundStyle(Ink.fail)
                                        .help("API 키가 없어요")
                                }
                            }
                            .tag(m.id)
                        }
                    }
                    .frame(width: 270)
                    HStack(spacing: 6) {
                        Button { addProfile() } label: { Image(systemName: "plus") }
                            .help("프로필 추가")
                            .accessibilityLabel("프로필 추가")
                        Button { if let id = selectedID { store.deleteModel(id); selectedID = nil } } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(selectedID == nil || ModelProfile.builtinIDs.contains(selectedID ?? ""))
                        .help("프로필 삭제")
                        .accessibilityLabel("프로필 삭제")
                        Spacer()
                        if FileManager.default.fileExists(atPath: Paths.home + "/.config/openrouter/or.zsh") {
                            Button("orc 별칭 가져오기") { Task { await store.importOrc(withKey: false) } }
                                .help("~/.config/openrouter/or.zsh 의 OR_MODELS 를 OpenRouter 프로필로")
                        }
                    }
                    .controlSize(.small)
                }

                if let d = Binding($draft) {
                    ProfileEditor(draft: d, testResult: testResult, testing: testing,
                                  onSave: { store.saveModel(d.wrappedValue) },
                                  onTest: { runTest(d.wrappedValue) })
                } else {
                    Text("왼쪽에서 프로필을 고르세요")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(20)
        .onChange(of: selectedID) {
            draft = store.model(selectedID)
            testResult = nil
        }
    }

    private func label(_ m: ModelProfile) -> String { store.isReady(m) ? m.name : String(localized: "\(m.name) (키 필요)") }

    private func addProfile() {
        var n = 1
        while store.model("my-\(n)") != nil { n += 1 }
        let m = ModelProfile(id: "my-\(n)", name: String(localized: "새 모델 \(n)"), provider: .openrouter, model: "",
                             smallModel: nil, baseURL: nil, sort: 200 + n)
        store.saveModel(m)
        selectedID = m.id
        draft = m
    }

    private func runTest(_ m: ModelProfile) {
        store.saveModel(m)
        testing = true
        testResult = nil
        Task {
            testResult = await store.testModel(m.id)
            testing = false
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var store: GraphStore
    @Binding var draft: ModelProfile
    let testResult: String?
    let testing: Bool
    let onSave: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("이름", text: $draft.name)
                Picker("방식", selection: $draft.provider) {
                    ForEach(ModelProfile.Provider.allCases) { p in Text(p.label).tag(p) }
                }
                .disabled(draft.isBuiltin)
                TextField(draft.provider == .subscription ? "모델 (opus·sonnet·haiku, 비우면 기본)" : "모델 ID",
                          text: Binding(get: { draft.model ?? "" }, set: { draft.model = $0 }),
                          prompt: Text(placeholder))
                    .font(.system(size: 12, design: .monospaced))
                if draft.provider != .subscription {
                    TextField("작은 모델 (선택)", text: Binding(get: { draft.smallModel ?? "" }, set: { draft.smallModel = $0 }),
                              prompt: Text(draft.provider == .openrouter ? "비우면 공통 설정 (OpenRouter)" : "비우면 위 모델"))
                        .font(.system(size: 12, design: .monospaced))
                        .help("Claude Code 의 haiku·서브에이전트 자리에 쓰는 모델")
                }
                if draft.provider == .custom {
                    TextField("엔드포인트 URL", text: Binding(get: { draft.baseURL ?? "" }, set: { draft.baseURL = $0 }),
                              prompt: Text("비우면 API 키 탭의 URL"))
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .formStyle(.grouped)
            .disabled(draft.isBuiltin && draft.provider == .subscription && draft.id == "claude")

            Text(help)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("저장") { onSave() }
                    .keyboardShortcut(.defaultAction)
                Button(testing ? "시험 중…" : "연결 시험") { onTest() }
                    .disabled(testing || draft.provider == .subscription || !store.isReady(draft))
                if let testResult {
                    Text(testResult)
                        .font(.system(size: 11))
                        .foregroundStyle(testResult.hasPrefix("OK") ? Ink.ok : Ink.fail)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholder: String {
        switch draft.provider {
        case .subscription: return "sonnet"
        case .openrouter: return "openai/gpt-6.1-sol"
        case .anthropic: return "claude-sonnet-5-5"
        case .custom: return "glm-5.3"
        }
    }

    private var help: String {
        switch draft.provider {
        case .subscription:
            return String(localized: "Claude Code 로그인(구독)으로 실행해요. 키가 필요 없어요.")
        case .openrouter:
            return String(localized: "OpenRouter 의 Anthropic 호환 주소로 Claude Code 를 실행해요 (orc 와 같은 방식). 모델 ID 는 openrouter.ai/models 의 이름 그대로 써요.")
        case .anthropic:
            return String(localized: "Anthropic API 키로 실행해요 (구독 대신 사용량 과금). 처음 열 때 Claude Code 가 키 사용을 한 번 확인할 수 있어요.")
        case .custom:
            return String(localized: "Anthropic Messages API 를 흉내 내는 주소 (LiteLLM 프록시, 각 회사의 Anthropic 호환 엔드포인트 등).")
        }
    }
}

// MARK: 폴더 (수정 범위에 쓰는 위치 목록)

struct PlaceSettings: View {
    @EnvironmentObject var store: GraphStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("대화마다 파일을 모아 둘 작업 폴더를 고를 때 쓰는 목록이에요. 각 대화의 작업 폴더는 그래프에서 노드를 선택해 인스펙터의 '작업 폴더' 에서 정해요.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.places.isEmpty {
                Text("아직 폴더가 없어요")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.places) { p in PlaceRow(place: p) }
                }
            }
            HStack {
                Button("폴더 추가…") { addFolders() }
                Spacer()
                Text("고른 대화는 파일을 그 폴더 안에 만들고 고쳐요")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "추가")
        guard panel.runModal() == .OK else { return }
        for u in panel.urls { store.addPlace(u.path) }
    }
}

struct PlaceRow: View {
    @EnvironmentObject var store: GraphStore
    let place: Place
    @State private var name = ""

    var body: some View {
        let used = store.placeUsage(place.id)
        HStack(spacing: 10) {
            Image(systemName: place.exists ? "folder" : "questionmark.folder")
                .foregroundStyle(place.exists ? Color.secondary : Ink.fail)
            VStack(alignment: .leading, spacing: 2) {
                TextField("이름", text: $name, prompt: Text((place.path as NSString).lastPathComponent))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit { store.renamePlace(place.id, name) }
                Text(Fmt.shortPath(place.path) + (place.exists ? "" : String(localized: " — 폴더가 없어요")))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(used == 0 ? "쓰는 대화 없음" : "대화 \(used)개")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: place.path)
            } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain)
                .help("Finder 에서 보기")
                .accessibilityLabel("Finder 에서 보기")
                .disabled(!place.exists)
            Button(role: .destructive) { remove(used) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .help("목록에서 빼기")
                .accessibilityLabel("목록에서 빼기")
        }
        .padding(.vertical, 3)
        .onAppear { name = place.name }
        .onDisappear { if name != place.name { store.renamePlace(place.id, name) } }
    }

    private func remove(_ used: Int) {
        if used > 0 {
            let alert = NSAlert()
            alert.messageText = String(localized: "«\(place.title)» 를 목록에서 뺄까요?")
            alert.informativeText = String(localized: "이 폴더를 고른 대화 \(used)개에서도 빠져요. 그 대화들은 남은 작업 폴더만 쓰게 돼요.")
            alert.addButton(withTitle: String(localized: "빼기"))
            alert.addButton(withTitle: String(localized: "취소"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.removePlace(place.id)
    }
}

// MARK: API 키

struct KeySettings: View {
    @EnvironmentObject var store: GraphStore
    @State private var openrouter = ""
    @State private var anthropic = ""
    @State private var custom = ""
    @State private var customURL = ""
    @State private var orSmall = ""
    @State private var orVision = ""

    private var orcKeyExists: Bool {
        FileManager.default.fileExists(atPath: Paths.home + "/.config/openrouter/key")
    }

    var body: some View {
        Form {
            Section("OpenRouter") {
                KeyRow(saved: store.keyStatus["openrouter"] == true, text: $openrouter,
                       onSave: { store.setKey("openrouter", openrouter); openrouter = "" },
                       onClear: { store.setKey("openrouter", "") })
                if orcKeyExists {
                    Button("~/.config/openrouter/key 에서 가져오기") { Task { await store.importOrc(withKey: true) } }
                        .help("orc 가 쓰는 키 파일을 복사해요 (별칭 프로필도 함께 가져와요)")
                }
                TextField("작은 모델 (haiku 자리)", text: $orSmall)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { store.setSetting("or_small", orSmall) }
                TextField("이미지 대체 모델", text: $orVision)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { store.setSetting("or_vision", orVision) }
                    .help("텍스트 전용 모델에 이미지가 들어오면 이 모델로 넘겨요 (비우면 끔)")
            }
            Section("Anthropic API") {
                KeyRow(saved: store.keyStatus["anthropic"] == true, text: $anthropic,
                       onSave: { store.setKey("anthropic", anthropic); anthropic = "" },
                       onClear: { store.setKey("anthropic", "") })
            }
            Section("사용자 지정 (Anthropic 호환)") {
                TextField("엔드포인트 URL", text: $customURL, prompt: Text("http://127.0.0.1:4000"))
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { store.setSetting("custom_base_url", customURL) }
                KeyRow(saved: store.keyStatus["custom"] == true, text: $custom,
                       onSave: { store.setKey("custom", custom); custom = "" },
                       onClear: { store.setKey("custom", "") })
            }
            Section {
                Text("키는 \(Fmt.shortPath(Paths.dataDir))/keys.json 에 본인만 읽을 수 있게(0600) 저장돼요. 앱 터미널에서 그 모델로 대화를 열 때 환경변수로 넘겨요.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            orSmall = store.settings["or_small"] ?? ""
            orVision = store.settings["or_vision"] ?? ""
            customURL = store.settings["custom_base_url"] ?? ""
        }
        .onDisappear {
            store.setSetting("or_small", orSmall)
            store.setSetting("or_vision", orVision)
            store.setSetting("custom_base_url", customURL)
        }
    }
}

struct KeyRow: View {
    let saved: Bool
    @Binding var text: String
    let onSave: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SecureField(saved ? "저장됨 — 바꾸려면 새 키 입력" : "API 키", text: $text)
                .onSubmit { if !text.isEmpty { onSave() } }
            Button("저장") { onSave() }.disabled(text.isEmpty)
            if saved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Ink.ok)
                    .accessibilityLabel("저장됨")
                Button("지우기", role: .destructive) { onClear() }
            }
        }
    }
}
