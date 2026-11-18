import Foundation

/// File-based diagnostics. os Logger output cannot be read from this
/// environment (`log show` refuses to run), so key runtime events are
/// also appended to `~/Library/Application Support/VibeKey Lite/debug.log`.
enum DebugLog {
    private static let queue = DispatchQueue(label: "io.github.arumwu.VibeKeyLite.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        queue.async {
            let dir = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("VibeKey Lite", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("debug.log")
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }
}
