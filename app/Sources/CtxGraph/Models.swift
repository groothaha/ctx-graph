import CoreGraphics
import Foundation

enum Paths {
    /// 홈 폴더: ctxgraph.py(Path.home)·Claude Code 와 같게 HOME 을 먼저 본다 (보통은 NSHomeDirectory 와 같음)
    static let home: String = {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }()
    /// ctxgraph.py·ctxpty.py 가 있는 폴더.
    /// 소스에서 빌드한 앱(build.sh 가 Info.plist 에 소스의 bin 경로를 적음)은 그 폴더를 바로 쓰고 (고치면 바로 반영),
    /// 배포판은 앱에 든 사본을 dataDir/bin 에 풀어 쓴다 — 훅이 가리키는 경로가 앱을 옮기거나 업데이트해도 그대로이게.
    static let binDir: String = {
        if let d = ProcessInfo.processInfo.environment["CTXGRAPH_BIN"] { return d }
        if let src = Bundle.main.object(forInfoDictionaryKey: "CtxGraphSourceBin") as? String,
           FileManager.default.fileExists(atPath: src + "/ctxgraph.py") { return src }
        return dataDir + "/bin"
    }()
    static let script = binDir + "/ctxgraph.py"
    /// CTXGRAPH_HOME 이 있으면 그 폴더 (시험용 — ctxgraph.py 도 같은 env 를 따른다)
    static let dataDir = ProcessInfo.processInfo.environment["CTXGRAPH_HOME"]
        ?? home + "/Library/Application Support/CtxGraph"
    static let db = dataDir + "/graph.sqlite"
    /// 터미널 보관자 (앱을 꺼도 대화가 계속 돌게)
    static let ptyScript = binDir + "/ctxpty.py"

    /// 배포판: 앱에 든 스크립트를 dataDir/bin 에 풀기 (내용이 다를 때만, 바꿔치기는 rename 으로 한 번에)
    static func installBundledScripts() {
        guard binDir == dataDir + "/bin", let res = Bundle.main.resourcePath else { return }
        let from = res + "/bin", fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: from) else { return }
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        for n in names {
            let a = from + "/" + n, b = binDir + "/" + n
            if fm.contentsEqual(atPath: a, andPath: b) { continue }
            let tmp = b + ".new"
            try? fm.removeItem(atPath: tmp)
            if (try? fm.copyItem(atPath: a, toPath: tmp)) != nil { _ = Darwin.rename(tmp, b) }
        }
    }
    static let tabsFile = dataDir + "/tabs.json"
    /// 보관자 소켓 폴더. 유닉스 소켓 경로는 104바이트 제한이 있어서 너무 길면 임시 폴더로.
    static let ptyDir: String = {
        let d = dataDir + "/pty"
        if (d + "/").utf8.count + 18 + 5 <= 100 { return d }
        var h: UInt32 = 2166136261
        for b in dataDir.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return NSTemporaryDirectory() + "ctxgraph-" + String(h, radix: 16)
    }()
    /// 터미널 보관자(ctxpty.py)를 띄울 python3 — 백엔드와 같은 것
    static var python: String { PythonRuntime.path ?? "/usr/bin/python3" }

    /// Claude Code 가 이 대화의 기록을 쓰는 곳 (cwd 의 영숫자 아닌 글자를 - 로)
    static func transcript(id: String, cwd: String) -> String {
        let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return "\(home)/.claude/projects/\(encoded)/\(id).jsonl"
    }
}

enum Layout {
    static let node = CGSize(width: 252, height: 80)
    static let canvas = CGSize(width: 3200, height: 2400)   // 처음 보이는 기본 판 (0,0 부터)
    static let margin: CGFloat = 3000                         // 노드들 바깥으로 이만큼 더 (그래프 판은 노드를 따라 넓어짐)

    /// 가운데가 p 인 카드의 사각형
    static func frame(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - node.width / 2, y: p.y - node.height / 2, width: node.width, height: node.height)
    }
}

struct GraphNode: Identifiable, Equatable {
    let id: String
    var transcriptPath: String
    var cwd: String?
    var label: String?
    var x: Double
    var y: Double
    var summary: String?
    var delta: String?
    var version: Int
    var summaryAt: Double?
    var summaryError: String?
    var jobPending: Bool
    var summarizing: Bool
    var modelID: String?
    var writeLimited: Bool = false      // true = 고른 위치(node_places) 안에서만 파일을 만들고 고침 (정리용)
    var writeStrict: Bool = false       // true = 셸 명령도 운영체제 샌드박스로 막기 (앱 터미널, 다시 열 때 적용)
    var spaces: [String] = [Space.main] // 이 대화가 놓인 작업 공간들 (놓은 순서). x·y 는 지금 공간(nodes) 또는 첫 공간(allNodes) 의 위치
    var srcSize: Int = 0                // 요약이 읽은 기록 파일 위치 (바이트)
    var srcAt: Double? = nil            // 요약이 담은 마지막 메시지 시각

    var point: CGPoint { CGPoint(x: x, y: y) }
    var frame: CGRect { Layout.frame(at: point) }
}

/// 방향 있는 연결: src 의 맥락이 dst 로 들어간다. 화살표 하나 = Link 하나 (양방향이면 나란한 화살표 두 개).
struct Link: Hashable, Identifiable {
    let src: String
    let dst: String
    var id: String { src + ">" + dst }
    var reversed: Link { Link(src: dst, dst: src) }
}

/// 화면에 그리는 선 하나 = 두 노드 쌍 (a < b). 방향은 ab(a→b)·ba(b→a), 둘 다면 양방향.
struct EdgePair: Identifiable, Hashable {
    let a: String
    let b: String
    var ab: Bool
    var ba: Bool
    var id: String { a + "|" + b }
    var both: Bool { ab && ba }

    static func key(_ x: String, _ y: String) -> String { x < y ? x + "|" + y : y + "|" + x }

    /// (from, to) 기준 방향
    func direction(from: String) -> FlowDirection {
        let fwd = from == a ? ab : ba
        let back = from == a ? ba : ab
        if fwd && back { return .both }
        return fwd ? .forward : .backward
    }
}

enum FlowDirection: String, CaseIterable, Identifiable {
    case forward, backward, both
    var id: String { rawValue }
}

struct SessionInfo: Identifiable, Equatable {
    let id: String
    let path: String
    let cwd: String?
    let agentName: String?
    let aiTitle: String?
    let firstPrompt: String?
    let lastPrompt: String?
    let nPrompts: Int
    let mtime: Double
    let liveStatus: String?

    var title: String {
        if let t = agentName, !t.isEmpty { return t }
        if let t = aiTitle, !t.isEmpty { return t }
        if let t = firstPrompt, !t.isEmpty { return Fmt.oneLine(t, 60) }
        return String(id.prefix(8))
    }
}

/// 대화·요약에 쓰는 모델 프로필 (models 테이블, ctxgraph.py 와 공유)
struct ModelProfile: Identifiable, Hashable {
    enum Provider: String, CaseIterable, Identifiable {
        case subscription, openrouter, anthropic, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .subscription: return String(localized: "Claude 구독")
            case .openrouter: return "OpenRouter"
            case .anthropic: return "Anthropic API"
            case .custom: return String(localized: "사용자 지정 (Anthropic 호환)")
            }
        }
        /// keys.json 의 키 이름 (구독은 없음)
        var keyName: String? { self == .subscription ? nil : rawValue }
    }

    var id: String
    var name: String
    var provider: Provider
    var model: String?
    var smallModel: String?
    var baseURL: String?
    var sort: Int

    static let builtinIDs: Set<String> = ["claude", "claude-opus", "claude-sonnet", "claude-haiku"]
    var isBuiltin: Bool { Self.builtinIDs.contains(id) }
    /// 탭·노드에 붙이는 짧은 이름
    var short: String {
        if id == "claude" { return "Claude" }
        if id.hasPrefix("or:") { return String(id.dropFirst(3)) }
        return Fmt.oneLine(name.components(separatedBy: " ·").first ?? name, 14)
    }
}

/// 작업 공간 (spaces 테이블): 그래프 노드 묶음 + 그 공간의 터미널 탭·분할 배치. 공간을 바꿔도 다른 공간의 터미널은 계속 돈다.
struct Space: Identifiable, Hashable {
    static let main = "main"
    let id: String
    var name: String
    var sort: Int
}

/// 파일 위치 목록의 한 항목 (places 테이블). 대화마다 이 중 몇 개를 골라 '그 안만 수정' 으로 제한한다.
struct Place: Identifiable, Hashable {
    let id: Int
    var name: String
    let path: String
    var title: String { name.isEmpty ? (path as NSString).lastPathComponent : name }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

enum Selection: Equatable {
    case node(String)
    case edge(String)
}

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLang.locale
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ ts: Double?) -> String {
        guard let ts, ts > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: ts)
        if Date().timeIntervalSince(d) < 60 { return String(localized: "방금") }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    static func shortPath(_ p: String?) -> String {
        guard let p, !p.isEmpty else { return "?" }
        let h = Paths.home
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }

    static func oneLine(_ s: String, _ n: Int) -> String {
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
