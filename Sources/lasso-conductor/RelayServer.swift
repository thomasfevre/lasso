#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Foundation
import LassoConductorCore
import Security

/// Unix-domain-socket bridge for the optional browser extension's native host.
/// Pairing uses ephemeral ECDH; reconnects use a mutual nonce/HMAC handshake.
/// Credential keys never cross the socket and are stored only in the Keychain.
final class RelayServer {
    private static let maxConnections = 8
    private static let maxMessageBytes = 64 * 1024
    private static let maxJSONDepth = 8
    private static let maxPendingRequests = 32
    private static let maxFingerprintStringLength = 4_096
    private static let handshakeTimeout: TimeInterval = 30
    private static let credentialLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let previousKeyGrace: TimeInterval = 24 * 60 * 60

    private let queue = DispatchQueue(label: "xyz.allez.lasso.relay")
    private let keychain = RelayKeychain()
    private let socketURL: URL
    private var listenerFD: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var gate: RelayGate
    private var connections: [ObjectIdentifier: ConnectionPhase] = [:]
    private var connectionAdmission = RelayConnectionAdmission()
    private var pairingRate = RelayRateWindow()
    private var promptInFlight = false

    private struct Challenge {
        let credentialID: String
        let serverNonce: String
        let sessionNonce: String
        let keys: [Data]
    }

    private struct Session {
        let credentialID: String
        let nonce: String
    }

    private enum ConnectionPhase {
        case awaitingHandshake
        case pairing(clientNonce: String)
        case challenged(Challenge)
        case authenticated(Session)
        case closing
    }

    private typealias PendingCompletion = ([String: Any]?) -> Void
    private var authentication = RelayAuthenticationRegistry<ObjectIdentifier>()
    private var pending = RelayPendingStore<ObjectIdentifier, PendingCompletion>()
    private var connectionObjects: [ObjectIdentifier: RelayConnection] = [:]
    private var nextRequestID = 1
    private let resolveTimeout: TimeInterval = 2

    private let publishedLock = NSLock()
    private var _extensionConnected = false
    private var _statusSummary = "Browser relay starting…"

    var hasConnectedExtension: Bool {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return _extensionConnected
    }

    /// Human-visible listener state used by the status menu. A bind failure is
    /// reported here as well as stderr, rather than silently losing the socket.
    var statusSummary: String {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return _statusSummary
    }

    init(storeDirectory: URL) {
        socketURL = storeDirectory.appendingPathComponent("relay.sock")
        do {
            let now = Date()
            let storedCredentials = try keychain.load()
            let credentials = storedCredentials.filter { $0.expiresAt > now }
            gate = RelayGate(credentials: credentials)
            if credentials.count != storedCredentials.count {
                try keychain.save(credentials)
            }
        } catch {
            gate = RelayGate()
            Self.log("relay Keychain unavailable: \(error)")
        }

        // Remove the obsolete cleartext bearer-token file. Those bearer tokens
        // cannot participate in the new proof protocol and must be paired again.
        let legacy = storeDirectory.appendingPathComponent("relay-tokens.json")
        try? FileManager.default.removeItem(at: legacy)
    }

    func start() {
        queue.async { self.openListener() }
    }

    private func openListener() {
        guard listenerFD < 0 else { return }
        let path = socketURL.path
        guard let address = Self.socketAddress(path: path) else {
            return listenerFailed("socket path is too long")
        }
        if unlink(path) != 0, errno != ENOENT {
            return listenerFailed("could not unlink stale socket: \(Self.lastPOSIXError())")
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return listenerFailed(Self.lastPOSIXError()) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            return listenerFailed(Self.lastPOSIXError())
        }
        var mutableAddress = address
        // Tighten umask across bind() so the socket file is never briefly created
        // with a permissive mode (default umask commonly yields 0755) before the
        // chmod below narrows it — that window would be connectable by other users.
        let previousUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &mutableAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousUmask)
        guard bindResult == 0 else {
            let error = Self.lastPOSIXError()
            Darwin.close(fd)
            return listenerFailed(error)
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            let error = Self.lastPOSIXError()
            Darwin.close(fd)
            unlink(path)
            return listenerFailed(error)
        }
        guard Darwin.listen(fd, Int32(Self.maxConnections)) == 0 else {
            let error = Self.lastPOSIXError()
            Darwin.close(fd)
            unlink(path)
            return listenerFailed(error)
        }

        listenerFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
        listenerSource = source
        source.resume()
        publish(status: "Browser relay ready")
        Self.log("relay listening on \(path)")
    }

    private func listenerFailed(_ reason: String) {
        Self.log("relay failed to start at \(socketURL.path): \(reason)")
        publish(status: "Browser relay unavailable — native messaging socket unavailable")
        closeAllConnections()
    }

    private static func socketAddress(path: String) -> sockaddr_un? {
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

    func revokeAll() {
        queue.async {
            do {
                try self.keychain.removeAll()
            } catch {
                Self.log("relay revoke failed: \(error)")
                self.publish(status: "Browser relay — revoke failed (Keychain unavailable)")
                return
            }
            self.gate.revokeAll()
            self.closeAllConnections()
            self.publish(status: "Browser relay ready — pairing revoked")
        }
    }

    // MARK: - Connections

    private func acceptAvailableConnections() {
        while true {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    Self.log("relay accept failed: \(Self.lastPOSIXError())")
                }
                return
            }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(fd)
                continue
            }
            accept(RelayConnection(fd: fd, queue: queue,
                                   maxMessageBytes: Self.maxMessageBytes))
        }
    }

    private func accept(_ connection: RelayConnection) {
        let now = Date()
        guard connectionAdmission.admit(now: now,
                                        activeConnections: connections.count,
                                        maxConnections: Self.maxConnections,
                                        rateLimit: 30,
                                        interval: 60) else {
            Self.log("relay refused connection: capacity/rate limit")
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = .awaitingHandshake
        connectionObjects[id] = connection
        connection.onFrame = { [weak self, weak connection] data in
            guard let self, let connection else { return false }
            return self.handle(data, on: connection)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self, let connection,
                  self.connections[ObjectIdentifier(connection)] != nil else { return }
            self.drop(connection)
        }
        connection.start()
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self, weak connection] in
            guard let self, let connection, let phase = self.connections[id] else { return }
            // `.pairing` waits on a human clicking Allow in a modal; it has its own
            // serialized gate (promptInFlight / pairingRate) and must not be
            // cancelled by the handshake timer, or a slow approval both discards the
            // pairing and self-DoSes every retry until the stale alert is dismissed.
            switch phase {
            case .authenticated, .pairing: return
            default:
                Self.log("relay handshake timed out")
                self.drop(connection)
            }
        }
    }

    private func drop(_ connection: RelayConnection) {
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        connectionObjects.removeValue(forKey: id)
        failPending(for: id)
        if authentication.disconnect(id) {
            publishConnected(false)
        }
        connection.cancel()
    }

    private func closeAllConnections() {
        pending.removeAll().forEach { $0(nil) }
        let sockets = Array(connectionObjects.values)
        connections.removeAll()
        connectionObjects.removeAll()
        sockets.forEach { $0.cancel() }
        authentication.removeAll()
        publishConnected(false)
    }

    @discardableResult
    private func handle(_ data: Data, on connection: RelayConnection) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              RelayValidation.validJSON(object, maxDepth: Self.maxJSONDepth),
              let message = object as? [String: Any],
              let type = message["type"] as? String,
              type.count <= 32 else { return false }

        let id = ObjectIdentifier(connection)
        guard let phase = connections[id] else { return false }

        switch (type, phase) {
        case ("identify", .awaitingHandshake), ("identify", .pairing):
            return handleIdentify(message, on: connection)
        case ("pair", .awaitingHandshake):
            return handlePair(message, on: connection)
        case ("authenticate", .challenged(let challenge)):
            return handleAuthentication(message, challenge: challenge, on: connection)
        case ("ping", .authenticated):
            send(["type": "pong"], on: connection)
            return true
        case ("fingerprint", .authenticated(let session)):
            return handleFingerprint(message, session: session, on: connection)
        default:
            // Unknown, out-of-order, and unauthenticated commands are protocol
            // violations. Closing prevents the connection from probing further.
            return false
        }
    }

    private func handleIdentify(_ message: [String: Any], on connection: RelayConnection) -> Bool {
        let origin = message["origin"] as? String
        let credentialID = message["credentialId"] as? String
        guard origin?.count ?? 0 <= 160, credentialID?.count ?? 0 <= 128 else { return false }

        switch gate.evaluate(origin: origin, credentialID: credentialID) {
        case .challenge(let credential):
            let keys = credential.activeKeys(at: Date()).compactMap { Data(base64URL: $0) }
            guard !keys.isEmpty else { return reject("expiredCredential", on: connection) }
            let serverNonce = RelayRandom.generate()
            let sessionNonce = RelayRandom.generate()
            let challenge = Challenge(credentialID: credential.id,
                                      serverNonce: serverNonce,
                                      sessionNonce: sessionNonce,
                                      keys: keys)
            connections[ObjectIdentifier(connection)] = .challenged(challenge)
            let transcript = RelayCrypto.serverProofTranscript(credentialID: credential.id,
                                                               serverNonce: serverNonce,
                                                               sessionNonce: sessionNonce)
            send([
                "type": "challenge",
                "credentialId": credential.id,
                "serverNonce": serverNonce,
                "sessionNonce": sessionNonce,
                "serverProofs": keys.map {
                    RelayCrypto.authenticationCode(transcript, key: $0).base64URLString
                },
            ], on: connection)
            return true
        case .needsPairing:
            return reject("pairingRequired", on: connection)
        case .rejected(let reason):
            return reject(reason.rawValue, on: connection)
        }
    }

    private func handleAuthentication(_ message: [String: Any],
                                      challenge: Challenge,
                                      on connection: RelayConnection) -> Bool {
        guard message["credentialId"] as? String == challenge.credentialID,
              message["sessionNonce"] as? String == challenge.sessionNonce,
              let clientNonce = message["clientNonce"] as? String,
              clientNonce.count <= 128,
              let proofString = message["proof"] as? String,
              let proof = Data(base64URL: proofString) else { return false }

        let transcript = RelayCrypto.clientProofTranscript(credentialID: challenge.credentialID,
                                                           serverNonce: challenge.serverNonce,
                                                           sessionNonce: challenge.sessionNonce,
                                                           clientNonce: clientNonce)
        guard let authenticatedKey = challenge.keys.first(where: {
            RelayCrypto.isValidAuthenticationCode(proof, message: transcript, key: $0)
        }) else { return reject("invalidProof", on: connection) }

        let session = Session(credentialID: challenge.credentialID, nonce: challenge.sessionNonce)
        let id = ObjectIdentifier(connection)
        let previousID = authentication.authenticate(RelayAuthenticatedSession(
            connectionID: id,
            credentialID: session.credentialID,
            nonce: session.nonce
        ))
        if let previousID, let previous = connectionObjects[previousID] {
            drop(previous)
        }
        connections[ObjectIdentifier(connection)] = .authenticated(session)
        publishConnected(true)

        // Rotate after every successful proof. Only the nonce crosses the wire;
        // both sides derive the replacement key from the authenticated old key.
        let rotationNonce = RelayRandom.generate()
        let newKey = RelayCrypto.authenticationCode(
            "lasso-rotate-v1|\(challenge.credentialID)|\(rotationNonce)",
            key: authenticatedKey
        )
        let expiresAt = Date().addingTimeInterval(Self.credentialLifetime)
        let previousGate = gate
        gate.rotate(id: challenge.credentialID,
                    to: newKey.base64URLString,
                    from: authenticatedKey.base64URLString,
                    expiresAt: expiresAt,
                    previousKeyExpiresAt: Date().addingTimeInterval(Self.previousKeyGrace))
        guard persistCredentials() else {
            gate = previousGate
            return reject("keychainUnavailable", on: connection)
        }
        send([
            "type": "authenticated",
            "sessionNonce": session.nonce,
            "rotationNonce": rotationNonce,
            "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1_000),
        ], on: connection)
        return true
    }

    // MARK: - Pairing

    private func handlePair(_ message: [String: Any], on connection: RelayConnection) -> Bool {
        let now = Date()
        guard pairingRate.isAllowed(now: now, limit: 3, interval: 60), !promptInFlight else {
            return reject("pairingRateLimited", on: connection)
        }
        guard let origin = message["origin"] as? String, RelayOrigin.isAllowed(origin),
              let clientNonce = message["clientNonce"] as? String, clientNonce.count <= 128,
              let publicString = message["clientPublicKey"] as? String,
              let publicData = Data(base64URL: publicString), publicData.count == 65 else {
            return false
        }

        pairingRate.record(now)
        promptInFlight = true
        connections[ObjectIdentifier(connection)] = .pairing(clientNonce: clientNonce)
        DispatchQueue.main.async { [weak self, weak connection] in
            guard let self else { return }
            guard let connection else {
                self.queue.async { self.promptInFlight = false }
                return
            }
            let approved = Self.promptApproval(origin: origin)
            self.queue.async { [weak self, weak connection] in
                guard let self else { return }
                self.promptInFlight = false
                guard let connection else { return }
                let id = ObjectIdentifier(connection)
                guard case .pairing(let expectedNonce)? = self.connections[id],
                      expectedNonce == clientNonce else { return }
                guard approved else {
                    _ = self.reject("userDeclined", on: connection)
                    return
                }
                do {
                    let privateKey = P256.KeyAgreement.PrivateKey()
                    let credentialID = RelayRandom.generate()
                    let serverNonce = RelayRandom.generate()
                    let keyData = try RelayCrypto.pairingKey(
                        privateKey: privateKey,
                        peerPublicKey: publicData,
                        credentialID: credentialID,
                        clientNonce: clientNonce,
                        serverNonce: serverNonce
                    )
                    let expiresAt = Date().addingTimeInterval(Self.credentialLifetime)
                    let previousGate = self.gate
                    self.gate.approvePairing(RelayCredential(
                        id: credentialID,
                        key: keyData.base64URLString,
                        expiresAt: expiresAt
                    ))
                    guard self.persistCredentials() else {
                        self.gate = previousGate
                        _ = self.reject("keychainUnavailable", on: connection)
                        return
                    }
                    self.connections[id] = .awaitingHandshake
                    self.send([
                        "type": "paired",
                        "credentialId": credentialID,
                        "serverNonce": serverNonce,
                        "serverPublicKey": privateKey.publicKey.x963Representation.base64URLString,
                        "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1_000),
                    ], on: connection)
                } catch {
                    Self.log("relay pairing failed: \(error)")
                    self.drop(connection)
                }
            }
        }
        return true
    }

    @MainActor
    private static func promptApproval(origin: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow the Lasso extension to pair?"
        alert.informativeText = """
        Request from “\(sanitizedOrigin(origin))”.
        """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        // Accepted residual: another same-user process can reach the 0600 UDS
        // during this window. The one-click Allow gates credential minting and
        // permissions mitigate it; full closure needs per-connection host
        // attestation, which is intentionally out of scope.
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func sanitizedOrigin(_ origin: String?) -> String {
        guard let origin, !origin.isEmpty else { return "unknown" }
        let cleaned = origin.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)
        return String(cleaned.prefix(80))
    }

    // MARK: - DOM resolve

    func resolve(screenBBox: CGRect, completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            guard let session = self.authentication.current,
                  let connection = self.connectionObjects[session.connectionID],
                  self.pending.count < Self.maxPendingRequests else {
                completion(nil)
                return
            }
            let id = self.nextRequestID
            self.nextRequestID &+= 1
            guard self.pending.insert(id: id,
                                      connectionID: session.connectionID,
                                      sessionNonce: session.nonce,
                                      value: completion,
                                      maxCount: Self.maxPendingRequests) else {
                completion(nil)
                return
            }
            self.send([
                "type": "resolve",
                "id": id,
                "sessionNonce": session.nonce,
                "bbox": ["x": screenBBox.minX, "y": screenBBox.minY,
                         "width": screenBBox.width, "height": screenBBox.height],
            ], on: connection)
            self.queue.asyncAfter(deadline: .now() + self.resolveTimeout) {
                self.pending.remove(id: id)?(nil)
            }
        }
    }

    func resolveFingerprint(screenBBox: CGRect) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            resolve(screenBBox: screenBBox) { continuation.resume(returning: $0) }
        }
    }

    private func handleFingerprint(_ message: [String: Any],
                                   session: Session,
                                   on connection: RelayConnection) -> Bool {
        guard message["sessionNonce"] as? String == session.nonce,
              let id = message["id"] as? Int,
              pending.matches(id: id,
                              connectionID: ObjectIdentifier(connection),
                              sessionNonce: session.nonce) else { return false }

        let fingerprint = message["fingerprint"]
        guard fingerprint is NSNull || fingerprint == nil
                || (fingerprint is [String: Any]
                    && RelayValidation.validFingerprint(
                        fingerprint,
                        maxDepth: Self.maxJSONDepth,
                        maxStringLength: Self.maxFingerprintStringLength
                    )) else {
            return false
        }
        pending.remove(id: id)?(fingerprint as? [String: Any])
        return true
    }

    private func failPending(for connectionID: ObjectIdentifier) {
        pending.removeAll(for: connectionID).forEach { $0(nil) }
    }

    // MARK: - Encoding / persistence

    private func reject(_ reason: String, on connection: RelayConnection) -> Bool {
        connections[ObjectIdentifier(connection)] = .closing
        send(["type": "rejected", "reason": reason], on: connection) { [weak self, weak connection] in
            if let connection { self?.drop(connection) }
        }
        return true
    }

    private func send(_ object: [String: Any],
                      on connection: RelayConnection,
                      completion: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= Self.maxMessageBytes else {
            drop(connection)
            return
        }
        connection.send(payload: data, completion: completion)
    }

    @discardableResult
    private func persistCredentials() -> Bool {
        do {
            try keychain.save(Array(gate.credentials.values))
            return true
        } catch {
            Self.log("relay Keychain write failed: \(error)")
            publish(status: "Browser relay unavailable — Keychain error")
            return false
        }
    }

    private func publishConnected(_ connected: Bool) {
        publishedLock.lock()
        _extensionConnected = connected
        publishedLock.unlock()
    }

    private func publish(status: String) {
        publishedLock.lock()
        _statusSummary = status
        publishedLock.unlock()
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("lasso: \(message)\n".utf8))
    }

    private static func lastPOSIXError() -> String {
        String(cString: strerror(errno))
    }

}

/// One nonblocking UDS client. It owns Chrome native-messaging framing while
/// `RelayServer` continues to own JSON validation and protocol state.
private final class RelayConnection {
    private struct PendingWrite {
        var data: Data
        var offset = 0
        let completion: (() -> Void)?
    }

    let fd: Int32
    private let maxMessageBytes: Int
    private var framer: NativeMessageFramer
    private var writes: [PendingWrite] = []
    private var isClosed = false
    private var isStarted = false
    private var isWriteSourceResumed = false
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite

    var onFrame: ((Data) -> Bool)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue, maxMessageBytes: Int) {
        self.fd = fd
        self.maxMessageBytes = maxMessageBytes
        framer = NativeMessageFramer(maxMessageBytes: maxMessageBytes)
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        writeSource.setEventHandler { [weak self] in self?.flushWrites() }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        readSource.resume()
    }

    func send(payload: Data, completion: (() -> Void)?) {
        guard !isClosed,
              let framed = try? NativeMessageFramer.encode(payload,
                                                           maxMessageBytes: maxMessageBytes) else {
            cancel()
            return
        }
        writes.append(PendingWrite(data: framed, completion: completion))
        flushWrites()
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        if !isStarted {
            isStarted = true
            readSource.resume()
        }
        if !isWriteSourceResumed {
            isWriteSourceResumed = true
            writeSource.resume()
        }
        readSource.cancel()
        writeSource.cancel()
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        writes.removeAll()
        onClose?()
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while !isClosed {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress!, rawBuffer.count)
            }
            if count == 0 {
                cancel()
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                cancel()
                return
            }
            do {
                let frames = try framer.append(Data(bytes[0 ..< count]))
                for frame in frames where onFrame?(frame) != true {
                    cancel()
                    return
                }
            } catch {
                cancel()
                return
            }
        }
    }

    private func flushWrites() {
        while !isClosed, !writes.isEmpty {
            let written = writes[0].data.withUnsafeBytes { rawBuffer in
                Darwin.write(fd,
                             rawBuffer.baseAddress!.advanced(by: writes[0].offset),
                             writes[0].data.count - writes[0].offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !isWriteSourceResumed {
                        isWriteSourceResumed = true
                        writeSource.resume()
                    }
                    return
                }
                cancel()
                return
            }
            writes[0].offset += written
            if writes[0].offset == writes[0].data.count {
                let completion = writes.removeFirst().completion
                completion?()
            }
        }
        if isWriteSourceResumed, !isClosed {
            isWriteSourceResumed = false
            writeSource.suspend()
        }
    }
}

private final class RelayKeychain {
    private let service = "xyz.allez.lasso.relay"
    private let account = "credentials-v1"

    func load() throws -> [RelayCredential] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status)
        }
        return try JSONDecoder().decode([RelayCredential].self, from: data)
    }

    func save(_ credentials: [RelayCredential]) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    func removeAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
        var description: String {
            SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        }
    }
}

private extension Data {
    init?(base64URL string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#endif
