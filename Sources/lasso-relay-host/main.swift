import Darwin
import Foundation

// Kept intentionally larger than RelayServer's 64 KiB UDS cap: this matches
// Chrome's own native-messaging outgoing-message limit (1 MiB). Oversized frames
// are rejected downstream by RelayServer, which then drops the connection.
private let maxFrameBytes = 1024 * 1024

private func log(_ message: String) {
    FileHandle.standardError.write(Data("lasso-relay-host: \(message)\n".utf8))
}

private func socketAddress(path: String) -> sockaddr_un? {
    let pathBytes = Array(path.utf8CString)
    var address = sockaddr_un()
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) {
            $0.initialize(from: pathBytes, count: pathBytes.count)
        }
    }
    return address
}

private func connectToConductor(path: String) -> Int32? {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, var address = socketAddress(path: path) else {
        if fd >= 0 { Darwin.close(fd) }
        return nil
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(fd)
        return nil
    }
    return fd
}

private func readExactly(fd: Int32, count: Int) -> Data? {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let readCount = data.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress!.advanced(by: offset), count - offset)
        }
        if readCount == 0 { return nil }
        if readCount < 0 {
            if errno == EINTR { continue }
            return nil
        }
        offset += readCount
    }
    return data
}

private func writeAll(fd: Int32, data: Data) -> Bool {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { rawBuffer in
            Darwin.write(fd, rawBuffer.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}

/// Pumps complete framed messages without interpreting their JSON payloads.
private func pump(from source: Int32, to destination: Int32) {
    while let prefix = readExactly(fd: source, count: 4) {
        let length = Int(prefix[0])
            | Int(prefix[1]) << 8
            | Int(prefix[2]) << 16
            | Int(prefix[3]) << 24
        guard length <= maxFrameBytes,
              let payload = readExactly(fd: source, count: length),
              writeAll(fd: destination, data: prefix),
              writeAll(fd: destination, data: payload) else { return }
    }
}

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.count > 1 {
    log("invoked by \(CommandLine.arguments[1])")
}

// Chrome does not inherit the Conductor's development environment, so the
// native host intentionally does not support LASSO_STORE_DIR overrides.
let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
let socketPath = URL(fileURLWithPath: home, isDirectory: true)
    .appendingPathComponent("Library/Application Support/Lasso/relay.sock").path

guard let socketFD = connectToConductor(path: socketPath) else {
    log("could not connect to \(socketPath): \(String(cString: strerror(errno)))")
    exit(1)
}

// Tear the shared socket fd down only after BOTH directions have finished.
// Closing it as soon as one pump returns (e.g. Chrome closes stdin on extension
// reload) would truncate an in-flight Conductor→Chrome reply and force-close the
// fd while the other thread may still be blocked in read() on it (UB on Darwin).
let group = DispatchGroup()
group.enter()
DispatchQueue.global(qos: .userInitiated).async {
    pump(from: STDIN_FILENO, to: socketFD)
    // Half-close the write side so the Conductor sees EOF and drains, letting the
    // socket→stdout pump finish naturally instead of being cut off.
    Darwin.shutdown(socketFD, SHUT_WR)
    group.leave()
}
group.enter()
DispatchQueue.global(qos: .userInitiated).async {
    pump(from: socketFD, to: STDOUT_FILENO)
    group.leave()
}
group.wait()
Darwin.close(socketFD)
