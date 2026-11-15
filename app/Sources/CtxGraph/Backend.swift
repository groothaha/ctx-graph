import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// graph.sqlite 형식 번호 (PRAGMA user_version). bin/ctxgraph.py 의 SCHEMA_VERSION 과 같아야 한다
/// (tests/test_schema.py 가 확인). 형식을 바꾸는 쪽은 ctxgraph.py 의 MIGRATIONS — 앱은 번호만 확인한다.
enum Schema { static let version = 3 }

/// 백엔드(ctxgraph.py)와 같이 쓰는 SQLite 파일. 스키마는 `ctxgraph.py init` 이 만든다.
final class SQLiteDB {
    struct Row {
        let st: OpaquePointer
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(st, i) != SQLITE_NULL, let c = sqlite3_column_text(st, i) else { return nil }
            return String(cString: c)
        }
        func double(_ i: Int32) -> Double? {
            sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
    }

    enum Failure: Error, LocalizedError {
        case open(String)
        var errorDescription: String? { if case .open(let m) = self { return m }; return nil }
    }

    private var handle: OpaquePointer?
    private(set) var lastError: String?
    /// 더 새 CtxGraph 가 만든 DB 면 켠다: 읽기만 하고 쓰는 문장은 거절
    var readOnly = false

    /// PRAGMA user_version
    var userVersion: Int {
        var v = 0
        query("PRAGMA user_version") { v = $0.int(0) }
        return v
    }

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw Failure.open(msg)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func query(_ sql: String, _ args: [Any?] = [], _ each: (Row) -> Void = { _ in }) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
            lastError = String(cString: sqlite3_errmsg(handle))
            return false
        }
        defer { sqlite3_finalize(st) }
        if readOnly && sqlite3_stmt_readonly(st) == 0 {
            lastError = "read-only (graph.sqlite is from a newer CtxGraph)"
            return false
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let arg else { sqlite3_bind_null(st, idx); continue }
            switch arg {
            case let s as String: sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            default: sqlite3_bind_null(st, idx)
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { each(Row(st: st)); continue }
            if rc == SQLITE_DONE { return true }
            lastError = String(cString: sqlite3_errmsg(handle))
            return false
        }
    }
}

/// 백엔드를 돌릴 python3. /usr/bin/python3 는 macOS 개발자 도구(Command Line Tools·Xcode)가 없으면
/// 실행하는 순간 설치 창만 띄우는 껍데기라, 개발자 도구가 있을 때만 쓴다. 없으면 nil → 첫 실행 안내가 알려 준다.
enum PythonRuntime {
    private static let lock = NSLock()
    private static var cached: String?? = nil

    static var path: String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let p = find()
        cached = .some(p)
        return p
    }

    /// 개발자 도구를 설치한 뒤 다시 찾기
    static func refresh() {
        lock.lock(); cached = nil; lock.unlock()
    }

    private static func find() -> String? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["CTXGRAPH_PYTHON"] {   // 직접 지정 (시험·pyenv 등)
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where fm.isExecutableFile(atPath: p) { return p }
        if developerToolsHavePython() { return "/usr/bin/python3" }
        let local = Paths.home + "/.local/bin/python3"
        return fm.isExecutableFile(atPath: local) ? local : nil
    }

    /// `xcode-select -p` 는 설치 창을 띄우지 않고 개발자 도구 위치만 알려 준다
    private static func developerToolsHavePython() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let dir = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        return p.terminationStatus == 0 && !dir.isEmpty
            && FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/python3")
    }

    /// macOS 의 '개발자 도구 설치' 창 (python3 가 들어 있음)
    static func installDeveloperTools() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// ctxgraph.py 를 백그라운드에서 실행 (스캔·요약). 앱을 Finder 에서 열어도 PATH 가 잡히게 한다.
enum Python {
    /// python3 를 못 찾았을 때의 종료 코드 (셸의 'command not found' 와 같게)
    static let missing: Int32 = 127
    /// DB 가 더 새 형식이라 백엔드가 멈췄을 때 (ctxgraph.py NewerSchema)
    static let newerData: Int32 = 3

    struct Result { let status: Int32; let output: String }

    static func run(_ args: [String], script: String = Paths.script) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let python = PythonRuntime.path else {
                    cont.resume(returning: Result(status: missing, output: "python3 not found"))
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: python)
                p.arguments = ["-I", script] + args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(Paths.home)/.local/bin"
                env["CTXGRAPH_LANG"] = AppLang.code      // 백엔드 문구·요약 언어
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, output: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus,
                                              output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}


/// ctxpty.py 보관자: 탭마다 하나. 앱을 꺼도 Claude 는 그 안에서 계속 돌고, 다시 켜면 붙는다.
enum PtyHost {
    static func sock(_ id: String) -> String { Paths.ptyDir + "/" + String(id.prefix(18)) + ".sock" }

    static func alive(_ id: String) async -> Bool { await probe(id) != nil }

    /// 살아 있으면 보관자 메타 (session·cwd·model·scope…), 없으면 nil
    static func probe(_ id: String) async -> [String: Any]? {
        let r = await Python.run(["probe", "--sock", sock(id)], script: Paths.ptyScript)
        guard r.status == 0, let d = r.output.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    /// 보관자 안의 Claude 를 끝낸다 (끝날 때까지 기다림, 최대 몇 초)
    static func kill(_ id: String) async {
        _ = await Python.run(["kill", "--sock", sock(id)], script: Paths.ptyScript)
    }

    /// 탭마다 지금 폴더·git 브랜치·열린 포트·하위 프로세스 수
    static func info() async -> [[String: Any]] {
        let r = await Python.run(["info", "--dir", Paths.ptyDir], script: Paths.ptyScript)
        guard r.status == 0, let d = r.output.data(using: .utf8),
              let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return a
    }

    /// 살아 있는 보관자들의 메타 (session·cwd·model·isNew·attached)
    static func list() async -> [[String: Any]] {
        let r = await Python.run(["list", "--dir", Paths.ptyDir], script: Paths.ptyScript)
        guard r.status == 0, let d = r.output.data(using: .utf8),
              let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return a
    }
}

/// 한 작업 공간의 터미널 분할 배치
struct SpaceLayout: Codable, Equatable {
    var layout: PaneNode
    var paneTabs: [String: String]
    var focused: String
    var pane: Bool
}

/// 열려 있던 탭 목록 (앱을 다시 켜면 그대로 복원)
struct SavedTabs: Codable {
    struct Tab: Codable {
        let id: String
        let cwd: String
        let isNew: Bool
        let model: String
        var kind: String? = nil       // claude | shell (없으면 claude)
        var title: String? = nil      // 사용자가 붙인 탭 이름
        var unread: Bool? = nil       // 안 읽은 알림
        var note: String? = nil       // 마지막 알림 내용
        var space: String? = nil      // 작업 공간 (없으면 기본)
    }
    var tabs: [Tab] = []
    var active: String?
    var pane = false
    var width: Double?
    var height: Double?
    var layout: PaneNode?             // 분할 배치
    var paneTabs: [String: String]?   // 패널 → 탭
    var focused: String?
    var vertical: Bool?
    var lastEvent: Int?               // 마지막으로 본 term_events id
    var space: String?                // 지금 공간 (layout·paneTabs·focused·pane 은 이 공간 것)
    var spaces: [String: SpaceLayout]?   // 다른 공간들의 분할 배치

    static func load() -> SavedTabs {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.tabsFile)),
              let s = try? JSONDecoder().decode(SavedTabs.self, from: d) else { return SavedTabs() }
        return s
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.dataDir, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: Paths.tabsFile), options: .atomic)
    }
}

/// API 키: dataDir/keys.json (0600). ctxgraph.py 와 같은 파일을 쓴다.
enum Keys {
    static var url: URL { URL(fileURLWithPath: Paths.dataDir + "/keys.json") }

    static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }

    static func save(_ keys: [String: String]) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: keys) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Paths.dataDir, withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return false }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
    }
}
