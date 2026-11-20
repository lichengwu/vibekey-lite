import Foundation
import Darwin
import OSLog
import VibeKeyLiteCore

/// Unix-domain-socket server for vibekeyctl. One JSON line per connection.
/// Main-queue callbacks; the handler replies synchronously via the closure.
final class CtlSocketServer {
    private let logger = Logger(subsystem: "io.github.arumwu.VibeKeyLite", category: "CTL")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let handler: (VibeKeyCtlProtocol.Request) -> VibeKeyCtlProtocol.Response
    private let socketURL: URL

    init(handler: @escaping (VibeKeyCtlProtocol.Request) -> VibeKeyCtlProtocol.Response) {
        self.handler = handler
        socketURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(VibeKeyCtlProtocol.socketRelativePath)
    }

    func start() {
        stop()
        let fm = FileManager.default
        try? fm.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Remove a stale socket from a previous crash.
        if fm.fileExists(atPath: socketURL.path) {
            try? fm.removeItem(at: socketURL)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("ctl socket create failed")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            logger.error("ctl socket path too long")
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { rebound in
                for (index, byte) in pathBytes.enumerated() { rebound[index] = byte }
            }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            logger.error("ctl socket bind/listen failed errno=\(errno)")
            return
        }
        // Owner-only access.
        chmod(socketURL.path, 0o600)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.resume()
        acceptSource = source
        logger.notice("ctl socket listening at \(self.socketURL.path, privacy: .public)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = recv(client, &buffer, buffer.count, 0)
        defer { close(client) }
        guard received > 0,
              let request = VibeKeyCtlProtocol.decodeRequest(Data(buffer.prefix(received))) else {
            reply(client, .init(ok: false, error: "无法解析请求"))
            return
        }
        let response = handler(request)
        reply(client, response)
    }

    private func reply(_ client: Int32, _ response: VibeKeyCtlProtocol.Response) {
        guard let data = try? VibeKeyCtlProtocol.encodeLine(response) else { return }
        data.withUnsafeBytes { buffer in
            _ = send(client, buffer.baseAddress!, buffer.count, 0)
        }
    }
}