import Foundation
import Darwin

struct WindowLimit: Decodable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Int { Int((100 - min(100, max(0, usedPercent))).rounded(.down)) }
    var reset: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
}

struct UsageSnapshot: Equatable {
    let primary: WindowLimit?
    let weekly: WindowLimit?
    let plan: String
    let fetchedAt: Date
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        struct Bucket: Decodable {
            let primary: WindowLimit?
            let secondary: WindowLimit?
            let planType: String?
        }
        struct Result: Decodable {
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits else {
            throw MonitorError.invalidResponse
        }
        var primary: WindowLimit?, weekly: WindowLimit?
        // Window position is not guaranteed: classify known durations first.
        for window in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
            if window.windowDurationMins == 300 { primary = window }
            if window.windowDurationMins == 10080 { weekly = window }
        }
        if let window = bucket.primary, window.windowDurationMins == nil { primary = primary ?? window }
        if let window = bucket.secondary, window.windowDurationMins == nil { weekly = weekly ?? window }
        return UsageSnapshot(primary: primary, weekly: weekly, plan: (bucket.planType ?? "Codex").capitalized, fetchedAt: now)
    }
}

enum MonitorError: LocalizedError {
    case notFound, disconnected, timeout, invalidResponse, oversized, cancelled
    case rpc(String)
    var errorDescription: String? {
        switch self {
        case .notFound: return "未找到 Codex。请安装 Codex 或在设置中选择可执行文件。"
        case .disconnected: return "Codex 连接已断开，请检查安装和登录状态。"
        case .timeout: return "读取超时，请检查网络后重试。"
        case .invalidResponse: return "Codex 返回的数据格式不完整，请更新 Codex。"
        case .oversized: return "Codex 返回的数据过大，已停止读取。"
        case .cancelled: return "读取已取消。"
        case .rpc(let message): return String(message.prefix(400))
        }
    }
}

struct RefreshGate {
    var lastAttempt: Date?
    var retryAt: Date?
    var failures = 0
    func permits(force: Bool, now: Date) -> Bool {
        if force { return true }
        if let retryAt, now < retryAt { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= 30 } ?? true
    }
    mutating func started(at date: Date) { lastAttempt = date }
    mutating func completed(success: Bool, at date: Date) {
        if success { failures = 0; retryAt = nil }
        else {
            failures = min(failures + 1, 5)
            retryAt = date.addingTimeInterval(min(900, 60 * pow(2, Double(failures - 1))))
        }
    }
}

struct CodexLocator {
    static func candidates(home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> [String] {
        let apps = ["/Applications", home + "/Applications"].flatMap { folder in
            ["Codex", "ChatGPT"].flatMap { name in
                [folder + "/\(name).app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                 folder + "/\(name).app/Contents/Resources/codex"]
            }
        }
        let bins = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                    home + "/.codex/packages/standalone/current/codex",
                    home + "/.codex/packages/standalone/current/bin/codex",
                    home + "/.local/bin/codex", home + "/.npm-global/bin/codex", home + "/bin/codex"]
        return apps + bins + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
    }
    static func resolve(custom: String? = nil) throws -> String {
        let paths = custom.flatMap { $0.isEmpty ? nil : $0 }.map { [$0] } ?? candidates()
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw MonitorError.notFound }
        return path
    }
}

final class CodexClient {
    private let lock = NSLock()
    private var active: Process?
    private var stopped = false
    func cancel() {
        lock.lock(); stopped = true; let process = active; lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func fetch(customPath: String? = nil, timeout: TimeInterval = 20, arguments: [String] = ["app-server", "--listen", "stdio://"]) throws -> UsageSnapshot {
        // The child may close stdin before initialize. Treat EPIPE as an error.
        signal(SIGPIPE, SIG_IGN)
        guard !isCancelled() else { throw MonitorError.cancelled }
        let path = try CodexLocator.resolve(custom: customPath)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        lock.lock()
        if stopped { lock.unlock(); throw MonitorError.cancelled }
        do { try process.run(); active = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let stopBy = Date().addingTimeInterval(0.3)
                while process.isRunning && Date() < stopBy { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
            lock.lock(); active = nil; lock.unlock()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.05, timeout) * 1_000_000_000)
        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        for fd in [readFD, writeFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        func wait(_ fd: Int32, events: Int16) throws {
            while true {
                if isCancelled() { throw MonitorError.cancelled }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw MonitorError.timeout }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let millis = Int32(min(200, max(1, (deadline - now) / 1_000_000)))
                let status = poll(&descriptor, 1, millis)
                if status > 0 { return }
                if status < 0 && errno != EINTR { throw MonitorError.disconnected }
            }
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(writeFD, events: Int16(POLLOUT))
                    let count = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    else { throw MonitorError.disconnected }
                }
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_usage_menubar", "title": "Codex 用量", "version": "2.0"]]])
        var buffer = Data(), totalBytes = 0, initialized = false
        while true {
            try wait(readFD, events: Int16(POLLIN))
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(readFD, &bytes, bytes.count)
            if count == 0 { throw MonitorError.disconnected }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw MonitorError.disconnected
            }
            totalBytes += count
            guard totalBytes <= 2 * 1024 * 1024 else { throw MonitorError.oversized }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int, id == 1 || id == 2 else { continue }
                if let error = object["error"] as? [String: Any] { throw MonitorError.rpc(error["message"] as? String ?? "Codex 读取失败。") }
                if id == 1 && !initialized {
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if id == 2 && initialized {
                    guard let result = object["result"] as? [String: Any] else { throw MonitorError.invalidResponse }
                    return try UsageSnapshot.parse(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
    }
}
