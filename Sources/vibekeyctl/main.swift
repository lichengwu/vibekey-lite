import Foundation
import Darwin
import VibeKeyLiteCore

/// vibekeyctl — thin CLI that talks to the resident VibeKey Lite app.
/// The app is the only HID writer; this process never touches the device.
///
/// Usage:
///   vibekeyctl led --state <idle|thinking|working|attention|notification|error|sweeping|sleeping|off>
///   vibekeyctl led --restore
///   vibekeyctl hook --agent <id> --event <name> [--dialect dsh]   (stdin JSON)
///   vibekeyctl status
///   vibekeyctl install-hooks --agent <id> [--ctl-path <path>]
///   vibekeyctl uninstall-hooks --agent <id>
///   vibekeyctl detect [--agent <id>]

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func optionValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func socketPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(VibeKeyCtlProtocol.socketRelativePath).path
}

/// Sends one request line and reads one response line.
func sendRequest(_ request: VibeKeyCtlProtocol.Request) -> VibeKeyCtlProtocol.Response {
    let path = socketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return .init(ok: false, error: "无法创建 socket")
    }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        return .init(ok: false, error: "socket 路径过长")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { rebound in
            for (index, byte) in pathBytes.enumerated() { rebound[index] = byte }
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            connect(fd, rebound, size)
        }
    }
    guard connected == 0 else {
        return .init(ok: false, error: "VibeKey Lite 未运行（socket 不存在）。请先启动 App。")
    }
    // 5 s receive timeout so a hung app never blocks an agent hook.
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    guard let line = try? VibeKeyCtlProtocol.encodeLine(request) else {
        return .init(ok: false, error: "请求编码失败")
    }
    let sent = line.withUnsafeBytes { buffer in
        send(fd, buffer.baseAddress!, buffer.count, 0)
    }
    guard sent == line.count else {
        return .init(ok: false, error: "请求发送失败")
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let received = recv(fd, &buffer, buffer.count, 0)
    guard received > 0,
          let response = VibeKeyCtlProtocol.decodeResponse(Data(buffer.prefix(received))) else {
        return .init(ok: false, error: "未收到 App 响应")
    }
    return response
}

func ctlPathForHooks() -> String {
    if let explicit = optionValue("--ctl-path") { return explicit }
    // Prefer the binary inside the installed app bundle; fall back to argv[0].
    let bundlePath = "/Applications/VibeKey Lite.app/Contents/MacOS/vibekeyctl"
    if FileManager.default.isExecutableFile(atPath: bundlePath) {
        return "\"\(bundlePath)\""
    }
    let argv0 = CommandLine.arguments[0]
    if argv0.hasPrefix("/") { return "\"\(argv0)\"" }
    return "\"\(URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path)\""
}

func requireTarget() -> VibeKeyAgentTarget {
    guard let raw = optionValue("--agent"),
          let target = VibeKeyAgentTarget(rawValue: raw) else {
        fail("用法: --agent <claude-code|qwen-code|qoder|codebuddy|codex|dsh|qwenwork>")
    }
    return target
}

func installHooks(uninstall: Bool) {
    let target = requireTarget()
    guard target.hookDialect == "claude", let relative = target.settingsRelativePath else {
        fail("\(target.displayName) 使用特殊接入流程（App 内操作），CLI 暂不支持。")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let detection = VibeKeyHookInstaller.detect(
        target: target,
        homeDirectory: home,
        pathDirectories: (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
    )
    guard detection.detected else {
        fail("未检测到 \(target.displayName)。请先安装该软件（\(target.downloadURL)），再回来接入灯效。")
    }
    let settingsURL = home.appendingPathComponent(relative)
    let existing = try? Data(contentsOf: settingsURL)
    do {
        let newData: Data?
        if uninstall {
            guard let existing else {
                print("没有配置文件，无需卸载。")
                return
            }
            newData = try VibeKeyHookInstaller.unmergedSettings(existing: existing)
            guard let newData else {
                print("未找到 vibekey-lite 条目，无需卸载。")
                return
            }
            try backupAndWrite(existing: existing, new: newData, at: settingsURL)
            print("已卸载 \(target.displayName) 的 vibekey-lite hooks（其余配置原样保留）。")
        } else {
            newData = try VibeKeyHookInstaller.mergedSettings(
                existing: existing, target: target, ctlPath: ctlPathForHooks()
            )
            try backupAndWrite(existing: existing, new: newData!, at: settingsURL)
            print("已安装 \(target.displayName) hooks → \(settingsURL.path)")
        }
        // Read-back verification.
        let written = try Data(contentsOf: settingsURL)
        let root = try JSONSerialization.jsonObject(with: written) as? [String: Any] ?? [:]
        let hasMarker = VibeKeyHookInstaller.containsMarker(in: root)
        if uninstall {
            guard !hasMarker else { fail("读回校验失败：标记条目仍存在") }
        } else {
            guard hasMarker else { fail("读回校验失败：标记条目缺失") }
        }
    } catch let error as VibeKeyHookInstallerError {
        fail(error.localizedDescription)
    } catch {
        fail("写入失败：\(error.localizedDescription)")
    }
}

func backupAndWrite(existing: Data?, new: Data, at url: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let existing {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("bak-vibekey-\(timestamp)")
        try existing.write(to: backup)
    }
    try new.write(to: url, options: .atomic)
}

// MARK: - Main dispatch

guard let command = arguments.first else {
    fail("""
    用法:
      vibekeyctl led --state <state> | --restore
      vibekeyctl hook --agent <id> --event <name> [--dialect dsh]
      vibekeyctl status
      vibekeyctl install-hooks --agent <id> [--ctl-path <path>]
      vibekeyctl uninstall-hooks --agent <id>
      vibekeyctl detect [--agent <id>]
    """)
}

switch command {
case "led":
    let request: VibeKeyCtlProtocol.Request
    if arguments.contains("--restore") {
        request = .init(command: "restore")
    } else if let state = optionValue("--state") {
        guard VibeKeyAgentState(rawValue: state) != nil else {
            fail("未知状态 \(state)。可选: \(VibeKeyAgentState.allCases.map(\.rawValue).joined(separator: "|"))")
        }
        request = .init(command: "led", state: state)
    } else {
        fail("用法: vibekeyctl led --state <state> | --restore")
    }
    let response = sendRequest(request)
    if response.ok {
        print("ok \(response.state ?? "")")
    } else {
        fail(response.error ?? "未知错误")
    }

case "hook":
    // Hook mode must never block the agent: always print {} and exit 0,
    // even when the app is not running.
    let agent = optionValue("--agent") ?? "unknown"
    let dialect = optionValue("--dialect") ?? "claude"
    let event = optionValue("--event")
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]
    if let request = VibeKeyCtlProtocol.requestFromHookPayload(
        payload, agent: agent, dialect: dialect, fallbackEvent: event
    ) {
        _ = sendRequest(request)
    }
    print("{}")

case "status":
    let response = sendRequest(.init(command: "status"))
    if response.ok {
        print("state=\(response.state ?? "unknown")")
    } else {
        fail(response.error ?? "未知错误")
    }

case "install-hooks":
    installHooks(uninstall: false)

case "uninstall-hooks":
    installHooks(uninstall: true)

case "detect":
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map(String.init)
    let targets: [VibeKeyAgentTarget]
    if let raw = optionValue("--agent"), let target = VibeKeyAgentTarget(rawValue: raw) {
        targets = [target]
    } else {
        targets = VibeKeyAgentTarget.allCases
    }
    for target in targets {
        let detection = VibeKeyHookInstaller.detect(
            target: target, homeDirectory: home, pathDirectories: pathDirectories
        )
        let detected = detection.detected ? "已安装" : "未检测到"
        let installed = detection.installed ? "已接入" : "未接入"
        print("\(target.rawValue)\t\(target.displayName)\t\(detected)\t\(installed)")
    }

default:
    fail("未知命令 \(command)")
}