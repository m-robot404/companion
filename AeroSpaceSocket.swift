import Foundation

public actor AeroSpaceSocket {
    public static let shared = AeroSpaceSocket()
    private let socketPath: String
    private var streamFd: Int32 = -1

    public init() {
        let username = NSUserName()
        self.socketPath = "/tmp/bobko.aerospace-\(username).sock"
        signal(SIGPIPE, SIG_IGN)
    }

    /// Sends a CLI-equivalent command directly to AeroSpace without spawning a process.
    public func sendCommand(_ command: String) async -> String? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRes == 0 else { return nil }

        // Send newline-delimited command payload
        let payload = command + "\n"
        guard let data = payload.data(using: .utf8) else { return nil }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
        guard written == data.count else { return nil }

        // Read response
        var buffer = [UInt8](<repeating: 0, count: 8192>)
        var responseData = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            responseData.append(buffer, count: n)
        }
        return String(data: responseData, encoding: .utf8)
    }

    public func focusWorkspace(_ name: String) async {
        _ = await sendCommand("workspace \(name)")
    }

    public func focusWindow(_ id: String) async {
        _ = await sendCommand("focus --window-id \(id)")
    }
}
