import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Pure relay credential state. The macOS transport owns HMAC/ECDH and Keychain
// access; keeping lifecycle decisions here makes expiry, rotation, and revocation
// deterministic and testable without a socket or Security.framework.

public enum RelayRejection: String, Sendable, Equatable {
    case badOrigin
    case invalidCredential
    case expiredCredential
}

public enum RelayDecision: Sendable, Equatable {
    case challenge(RelayCredential)
    case needsPairing
    case rejected(RelayRejection)
}

public enum RelayOrigin {
    public static let allowedSchemes = [
        "chrome-extension://",
        "safari-web-extension://",
        "moz-extension://",
    ]

    public static func isAllowed(_ origin: String?) -> Bool {
        guard let origin else { return false }
        return allowedSchemes.contains { origin.hasPrefix($0) }
    }
}

/// One relay HMAC credential. `key` is never sent over the transport: initial
/// pairing derives it with ECDH, and reconnect rotation derives it from the
/// previously authenticated key. The previous key is retained briefly so a
/// dropped rotation acknowledgement cannot permanently unpair the extension.
public struct RelayCredential: Codable, Sendable, Equatable {
    public let id: String
    public var key: String
    public var expiresAt: Date
    public var previousKey: String?
    public var previousKeyExpiresAt: Date?

    public init(id: String,
                key: String,
                expiresAt: Date,
                previousKey: String? = nil,
                previousKeyExpiresAt: Date? = nil) {
        self.id = id
        self.key = key
        self.expiresAt = expiresAt
        self.previousKey = previousKey
        self.previousKeyExpiresAt = previousKeyExpiresAt
    }

    public func activeKeys(at now: Date) -> [String] {
        guard expiresAt > now else { return [] }
        var keys = [key]
        if let previousKey, let previousKeyExpiresAt, previousKeyExpiresAt > now {
            keys.append(previousKey)
        }
        return keys
    }
}

public struct RelayGate: Sendable, Equatable {
    public private(set) var credentials: [String: RelayCredential]

    public init(credentials: [RelayCredential] = []) {
        self.credentials = Dictionary(uniqueKeysWithValues: credentials.map { ($0.id, $0) })
    }

    /// An origin and public credential id are enough to request a challenge, but
    /// never to authenticate. The transport proves possession of an active key
    /// before accepting any command.
    public func evaluate(origin: String?, credentialID: String?, now: Date = Date()) -> RelayDecision {
        guard RelayOrigin.isAllowed(origin) else { return .rejected(.badOrigin) }
        guard let credentialID else { return .needsPairing }
        guard let credential = credentials[credentialID] else {
            return .rejected(.invalidCredential)
        }
        guard credential.expiresAt > now else { return .rejected(.expiredCredential) }
        return .challenge(credential)
    }

    public mutating func approvePairing(_ credential: RelayCredential) {
        credentials[credential.id] = credential
    }

    public mutating func rotate(id: String,
                                to newKey: String,
                                from authenticatedKey: String,
                                expiresAt: Date,
                                previousKeyExpiresAt: Date) {
        // Only rotate forward from the *current* key. If two connections
        // authenticate against the same credential in quick succession, the second
        // may still hold a stale-but-in-grace `previousKey`; letting it rotate would
        // clobber the fresher key the first connection just installed and force a
        // needless re-pair. Reject rotations that don't originate from `credential.key`.
        guard var credential = credentials[id], credential.key == authenticatedKey else { return }
        credential.previousKey = authenticatedKey
        credential.previousKeyExpiresAt = previousKeyExpiresAt
        credential.key = newKey
        credential.expiresAt = expiresAt
        credentials[id] = credential
    }

    public mutating func revoke(_ id: String) {
        credentials.removeValue(forKey: id)
    }

    public mutating func revokeAll() {
        credentials.removeAll()
    }
}

public struct RelayAuthenticatedSession<ConnectionID: Hashable>: Equatable {
    public let connectionID: ConnectionID
    public let credentialID: String
    public let nonce: String

    public init(connectionID: ConnectionID, credentialID: String, nonce: String) {
        self.connectionID = connectionID
        self.credentialID = credentialID
        self.nonce = nonce
    }
}

/// Tracks the single socket allowed to service DOM requests. Re-authentication
/// atomically replaces the prior socket so callers can close it.
public struct RelayAuthenticationRegistry<ConnectionID: Hashable> {
    public private(set) var current: RelayAuthenticatedSession<ConnectionID>?

    public init() {}

    public mutating func authenticate(_ session: RelayAuthenticatedSession<ConnectionID>)
        -> ConnectionID? {
        let previous = current?.connectionID
        current = session
        return previous == session.connectionID ? nil : previous
    }

    @discardableResult
    public mutating func disconnect(_ connectionID: ConnectionID) -> Bool {
        guard current?.connectionID == connectionID else { return false }
        current = nil
        return true
    }

    public mutating func removeAll() {
        current = nil
    }
}

/// Binds each in-flight resolve to both the authenticated socket and its session
/// nonce. A reply from any other socket/session cannot consume the request.
public struct RelayPendingStore<ConnectionID: Hashable, Value> {
    private struct Entry {
        let connectionID: ConnectionID
        let sessionNonce: String
        let value: Value
    }

    private var entries: [Int: Entry] = [:]

    public init() {}

    public var count: Int { entries.count }

    @discardableResult
    public mutating func insert(id: Int,
                                connectionID: ConnectionID,
                                sessionNonce: String,
                                value: Value,
                                maxCount: Int) -> Bool {
        guard entries.count < maxCount, entries[id] == nil else { return false }
        entries[id] = Entry(connectionID: connectionID, sessionNonce: sessionNonce, value: value)
        return true
    }

    public func matches(id: Int, connectionID: ConnectionID, sessionNonce: String) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.connectionID == connectionID && entry.sessionNonce == sessionNonce
    }

    public mutating func remove(id: Int) -> Value? {
        entries.removeValue(forKey: id)?.value
    }

    public mutating func removeAll(for connectionID: ConnectionID) -> [Value] {
        let ids = entries.compactMap { $0.value.connectionID == connectionID ? $0.key : nil }
        return ids.compactMap { entries.removeValue(forKey: $0)?.value }
    }

    public mutating func removeAll() -> [Value] {
        let values = entries.values.map(\.value)
        entries.removeAll()
        return values
    }
}

public struct RelayRateWindow {
    private var timestamps: [Date] = []

    public init() {}

    public mutating func isAllowed(now: Date,
                                   limit: Int,
                                   interval: TimeInterval) -> Bool {
        timestamps.removeAll { now.timeIntervalSince($0) >= interval }
        return timestamps.count < limit
    }

    public mutating func record(_ date: Date) {
        timestamps.append(date)
    }
}

public struct RelayConnectionAdmission {
    private var rate = RelayRateWindow()

    public init() {}

    public mutating func admit(now: Date,
                               activeConnections: Int,
                               maxConnections: Int,
                               rateLimit: Int,
                               interval: TimeInterval) -> Bool {
        guard activeConnections < maxConnections,
              rate.isAllowed(now: now, limit: rateLimit, interval: interval) else {
            return false
        }
        rate.record(now)
        return true
    }
}

public enum RelayValidation {
    public static func validJSON(_ value: Any, depth: Int = 0, maxDepth: Int) -> Bool {
        guard depth <= maxDepth else { return false }
        if let dictionary = value as? [String: Any] {
            return dictionary.allSatisfy {
                $0.key.count <= 128 && validJSON($0.value, depth: depth + 1, maxDepth: maxDepth)
            }
        }
        if let array = value as? [Any] {
            return array.allSatisfy { validJSON($0, depth: depth + 1, maxDepth: maxDepth) }
        }
        return value is String || value is NSNumber || value is NSNull
    }

    public static func validFingerprint(_ value: Any?,
                                        depth: Int = 0,
                                        maxDepth: Int,
                                        maxStringLength: Int) -> Bool {
        guard depth <= maxDepth else { return false }
        if let string = value as? String { return string.count <= maxStringLength }
        if let dictionary = value as? [String: Any] {
            return dictionary.allSatisfy {
                $0.key.count <= maxStringLength
                    && validFingerprint($0.value, depth: depth + 1,
                                        maxDepth: maxDepth,
                                        maxStringLength: maxStringLength)
            }
        }
        if let array = value as? [Any] {
            return array.allSatisfy {
                validFingerprint($0, depth: depth + 1,
                                 maxDepth: maxDepth,
                                 maxStringLength: maxStringLength)
            }
        }
        return value is NSNumber || value is NSNull
    }
}

#if canImport(CryptoKit)
public enum RelayCrypto {
    public static func pairingKey(privateKey: P256.KeyAgreement.PrivateKey,
                                  peerPublicKey: Data,
                                  credentialID: String,
                                  clientNonce: String,
                                  serverNonce: String) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let info = "lasso-pair-v1|\(credentialID)|\(clientNonce)"
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(serverNonce.utf8),
            sharedInfo: Data(info.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public static func serverProofTranscript(credentialID: String,
                                             serverNonce: String,
                                             sessionNonce: String) -> String {
        "lasso-server-v1|\(credentialID)|\(serverNonce)|\(sessionNonce)"
    }

    public static func clientProofTranscript(credentialID: String,
                                             serverNonce: String,
                                             sessionNonce: String,
                                             clientNonce: String) -> String {
        "lasso-client-v1|\(credentialID)|\(serverNonce)|\(sessionNonce)|\(clientNonce)"
    }

    public static func authenticationCode(_ message: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
                                             using: SymmetricKey(data: key)))
    }

    public static func isValidAuthenticationCode(_ code: Data,
                                                  message: String,
                                                  key: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(code,
                                               authenticating: Data(message.utf8),
                                               using: SymmetricKey(data: key))
    }
}
#endif

public enum RelayRandom {
    /// A URL-safe 256-bit random value for credential ids, nonces, and keys.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum NativeMessageFramingError: Error, Equatable {
    case oversizedFrame(Int)
}

/// Incrementally decodes Chrome native-messaging frames: a four-byte
/// little-endian payload length followed by UTF-8 JSON bytes. JSON validation is
/// deliberately left to the relay protocol layer.
public struct NativeMessageFramer {
    private let maxMessageBytes: Int
    private var buffer = Data()

    public init(maxMessageBytes: Int) {
        self.maxMessageBytes = maxMessageBytes
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = Int(buffer[0])
                | Int(buffer[1]) << 8
                | Int(buffer[2]) << 16
                | Int(buffer[3]) << 24
            guard length <= maxMessageBytes else {
                throw NativeMessageFramingError.oversizedFrame(length)
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(buffer.subdata(in: 4 ..< 4 + length))
            buffer.removeSubrange(0 ..< 4 + length)
        }
        return frames
    }

    public static func encode(_ payload: Data, maxMessageBytes: Int) throws -> Data {
        guard payload.count <= maxMessageBytes else {
            throw NativeMessageFramingError.oversizedFrame(payload.count)
        }
        var length = UInt32(payload.count).littleEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(payload)
        return framed
    }
}
