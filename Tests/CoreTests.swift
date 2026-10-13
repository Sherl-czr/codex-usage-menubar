import Foundation
import Darwin

@main struct CoreTests {
    static let payload = #"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null,"planType":"plus"}}"#
    static func fake(_ mode: String) {
        if mode == "early" { return }
        if mode == "hang" { Thread.sleep(forTimeInterval: 5); return }
        if mode == "oversized" { FileHandle.standardOutput.write(Data(repeating: 65, count: 2 * 1024 * 1024 + 8192)); return }
        _ = readLine()
        print(#"{"id":999,"error":{"message":"unrelated"}}"#)
        print(#"{"id":1,"result":{}}"#); fflush(stdout)
        _ = readLine(); _ = readLine()
        let response = "{\"id\":2,\"result\":" + payload + "}\n"
        let data = Data(response.utf8); let middle = data.count / 2
        FileHandle.standardOutput.write(data.prefix(middle))
        Thread.sleep(forTimeInterval: 0.01)
        FileHandle.standardOutput.write(data.suffix(from: middle))
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        print("PASS: \(label)")
    }
    static func main() throws {
        if let index = CommandLine.arguments.firstIndex(of: "--fake") { fake(CommandLine.arguments[index + 1]); return }
        let snapshot = try UsageSnapshot.parse(Data(payload.utf8))
        expect(snapshot.primary == nil && snapshot.weekly?.remaining == 80, "只有每周窗口时不误标五小时")
        let swapped = #"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080},"secondary":{"usedPercent":35,"windowDurationMins":300}}}"#
        let normalized = try UsageSnapshot.parse(Data(swapped.utf8))
        expect(normalized.primary?.remaining == 65 && normalized.weekly?.remaining == 88, "交换位置按时长归类")
        let bucket = #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10.5,"windowDurationMins":300},"secondary":{"usedPercent":150,"windowDurationMins":10080}}}}"#
        let selected = try UsageSnapshot.parse(Data(bucket.utf8))
        expect(selected.primary?.remaining == 89 && selected.weekly?.remaining == 0, "优先 Codex 桶、夹紧百分比及向下取整")
        let unavailable = try UsageSnapshot.parse(Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8))
        expect(unavailable.primary == nil && unavailable.weekly == nil, "未提供窗口不伪造剩余百分比")
        let unknown = try UsageSnapshot.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":1440}}}"#.utf8))
        expect(unknown.primary == nil && unknown.weekly == nil, "非标准窗口不冒充五小时")
        let now = Date(timeIntervalSince1970: 1000)
        var gate = RefreshGate(); gate.started(at: now)
        expect(!gate.permits(force: false, now: now.addingTimeInterval(29)), "30 秒内打开面板不重复查询")
        expect(gate.permits(force: true, now: now), "手动刷新可跳过缓存")
        gate.completed(success: false, at: now)
        expect(!gate.permits(force: false, now: now.addingTimeInterval(59)), "失败退避")
        gate.completed(success: false, at: now)
        expect(gate.retryAt == now.addingTimeInterval(120), "连续失败延长退避")
        gate.completed(success: true, at: now)
        expect(gate.failures == 0 && gate.retryAt == nil, "成功后恢复正常刷新")
        let paths = CodexLocator.candidates(home: "/test", path: "/custom/bin:/usr/bin")
        expect(paths.contains("/test/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex") && paths.contains("/custom/bin/codex"), "用户安装路径及 PATH 兼容")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let liveFake = try CodexClient().fetch(customPath: executable, timeout: 2, arguments: ["--fake", "success"])
        expect(liveFake.weekly?.remaining == 80, "分段 JSON 接收及忽略无关 RPC 错误")
        for mode in ["early", "hang", "oversized"] {
            let started = Date()
            do {
                _ = try CodexClient().fetch(customPath: executable, timeout: 0.3, arguments: ["--fake", mode])
                expect(false, "\(mode) 应返回错误")
            } catch {
                expect(Date().timeIntervalSince(started) < 1.5, "\(mode)：受控失败且不挂住")
            }
        }
        print("全部核心测试通过")
    }
}
