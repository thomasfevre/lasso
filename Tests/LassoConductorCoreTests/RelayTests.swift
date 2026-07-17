import XCTest
@testable import LassoConductorCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class RelayTests: XCTestCase {
    private let origin = "chrome-extension://id"

    func testUnexpectedOriginRejectedBeforeCredentialLookup() {
        let gate = RelayGate()
        XCTAssertEqual(gate.evaluate(origin: "https://evil.example.com", credentialID: nil),
                       .rejected(.badOrigin))
        XCTAssertEqual(gate.evaluate(origin: nil, credentialID: "public-id"),
                       .rejected(.badOrigin))
    }

    func testAllowedExtensionOrigins() {
        XCTAssertTrue(RelayOrigin.isAllowed("chrome-extension://abcdefghijklmnop"))
        XCTAssertTrue(RelayOrigin.isAllowed("safari-web-extension://ABC-123"))
        XCTAssertTrue(RelayOrigin.isAllowed("moz-extension://xyz"))
        XCTAssertFalse(RelayOrigin.isAllowed("https://app.example.com"))
    }

    func testMissingCredentialRequestsPairing() {
        XCTAssertEqual(RelayGate().evaluate(origin: origin, credentialID: nil), .needsPairing)
    }

    func testUnknownAndExpiredCredentialsAreRejected() {
        let now = Date()
        let expired = RelayCredential(id: "expired", key: "key",
                                      expiresAt: now.addingTimeInterval(-1))
        let gate = RelayGate(credentials: [expired])
        XCTAssertEqual(gate.evaluate(origin: origin, credentialID: "missing", now: now),
                       .rejected(.invalidCredential))
        XCTAssertEqual(gate.evaluate(origin: origin, credentialID: expired.id, now: now),
                       .rejected(.expiredCredential))
    }

    func testActiveCredentialProducesChallengeMaterial() {
        let now = Date()
        let credential = RelayCredential(id: "id", key: "key",
                                         expiresAt: now.addingTimeInterval(60))
        XCTAssertEqual(RelayGate(credentials: [credential])
            .evaluate(origin: origin, credentialID: credential.id, now: now),
                       .challenge(credential))
    }

    func testApprovedPairingMintsCredentialIntoGate() {
        let credential = RelayCredential(id: "minted", key: "derived-key",
                                         expiresAt: Date().addingTimeInterval(60))
        var gate = RelayGate()

        gate.approvePairing(credential)

        XCTAssertEqual(gate.credentials[credential.id], credential)
        XCTAssertEqual(gate.evaluate(origin: origin, credentialID: credential.id),
                       .challenge(credential))
    }

    #if canImport(CryptoKit)
    func testECDHPairingDerivesSameCredentialWithoutHumanCode() throws {
        let client = P256.KeyAgreement.PrivateKey()
        let server = P256.KeyAgreement.PrivateKey()
        let arguments = (credentialID: "credential", clientNonce: "client", serverNonce: "server")

        let serverKey = try RelayCrypto.pairingKey(
            privateKey: server,
            peerPublicKey: client.publicKey.x963Representation,
            credentialID: arguments.credentialID,
            clientNonce: arguments.clientNonce,
            serverNonce: arguments.serverNonce
        )
        let clientKey = try RelayCrypto.pairingKey(
            privateKey: client,
            peerPublicKey: server.publicKey.x963Representation,
            credentialID: arguments.credentialID,
            clientNonce: arguments.clientNonce,
            serverNonce: arguments.serverNonce
        )

        XCTAssertEqual(serverKey, clientKey)
    }

    func testHMACChallengeAcceptsCorrectProofAndRejectsWrongProof() {
        let key = Data(repeating: 7, count: 32)
        let transcript = RelayCrypto.clientProofTranscript(
            credentialID: "credential",
            serverNonce: "server",
            sessionNonce: "session",
            clientNonce: "client"
        )
        let proof = RelayCrypto.authenticationCode(transcript, key: key)

        XCTAssertTrue(RelayCrypto.isValidAuthenticationCode(proof,
                                                            message: transcript,
                                                            key: key))
        XCTAssertFalse(RelayCrypto.isValidAuthenticationCode(Data(repeating: 0, count: 32),
                                                             message: transcript,
                                                             key: key))
    }
    #endif

    func testRotationKeepsPreviousKeyOnlyDuringGrace() {
        let now = Date()
        let credential = RelayCredential(id: "id", key: "old",
                                         expiresAt: now.addingTimeInterval(60))
        var gate = RelayGate(credentials: [credential])
        gate.rotate(id: credential.id, to: "new", from: "old",
                    expiresAt: now.addingTimeInterval(120),
                    previousKeyExpiresAt: now.addingTimeInterval(10))
        let rotated = gate.credentials[credential.id]!
        XCTAssertEqual(rotated.activeKeys(at: now), ["new", "old"])
        XCTAssertEqual(rotated.activeKeys(at: now.addingTimeInterval(11)), ["new"])
    }

    func testStalePreviousKeyCannotRotateOverCurrentKey() {
        let now = Date()
        var gate = RelayGate(credentials: [
            RelayCredential(id: "id", key: "current", expiresAt: now.addingTimeInterval(60)),
        ])

        gate.rotate(id: "id", to: "attacker", from: "stale",
                    expiresAt: now.addingTimeInterval(120),
                    previousKeyExpiresAt: now.addingTimeInterval(10))

        XCTAssertEqual(gate.credentials["id"]?.key, "current")
        XCTAssertNil(gate.credentials["id"]?.previousKey)
    }

    func testRevokeAll() {
        let credential = RelayCredential(id: "id", key: "key",
                                         expiresAt: Date().addingTimeInterval(60))
        var gate = RelayGate(credentials: [credential])
        gate.revokeAll()
        XCTAssertTrue(gate.credentials.isEmpty)
    }

    func testReauthenticationReplacesPreviousSocket() {
        var registry = RelayAuthenticationRegistry<String>()
        XCTAssertNil(registry.authenticate(RelayAuthenticatedSession(
            connectionID: "first", credentialID: "credential", nonce: "one"
        )))

        XCTAssertEqual(registry.authenticate(RelayAuthenticatedSession(
            connectionID: "second", credentialID: "credential", nonce: "two"
        )), "first")
        XCTAssertEqual(registry.current?.connectionID, "second")
        XCTAssertFalse(registry.disconnect("first"))
        XCTAssertTrue(registry.disconnect("second"))
    }

    func testPendingRequestsRequireMatchingSocketAndSessionNonce() {
        var pending = RelayPendingStore<String, String>()
        XCTAssertTrue(pending.insert(id: 1, connectionID: "socket-a", sessionNonce: "nonce-a",
                                     value: "result", maxCount: 2))

        XCTAssertFalse(pending.matches(id: 1, connectionID: "socket-b", sessionNonce: "nonce-a"))
        XCTAssertFalse(pending.matches(id: 1, connectionID: "socket-a", sessionNonce: "nonce-b"))
        XCTAssertTrue(pending.matches(id: 1, connectionID: "socket-a", sessionNonce: "nonce-a"))
        XCTAssertEqual(pending.remove(id: 1), "result")
    }

    func testPendingRequestCapRejectsAdditionalWork() {
        var pending = RelayPendingStore<String, String>()
        XCTAssertTrue(pending.insert(id: 1, connectionID: "socket", sessionNonce: "nonce",
                                     value: "first", maxCount: 1))
        XCTAssertFalse(pending.insert(id: 2, connectionID: "socket", sessionNonce: "nonce",
                                      value: "second", maxCount: 1))
        XCTAssertEqual(pending.count, 1)
    }

    func testConnectionAndPairingRateWindowsEnforceCapsAndRecover() {
        let now = Date(timeIntervalSince1970: 1_000)
        var connections = RelayConnectionAdmission()
        XCTAssertFalse(connections.admit(now: now,
                                         activeConnections: 8,
                                         maxConnections: 8,
                                         rateLimit: 30,
                                         interval: 60))
        for _ in 0 ..< 30 {
            XCTAssertTrue(connections.admit(now: now,
                                            activeConnections: 0,
                                            maxConnections: 8,
                                            rateLimit: 30,
                                            interval: 60))
        }
        XCTAssertFalse(connections.admit(now: now,
                                         activeConnections: 0,
                                         maxConnections: 8,
                                         rateLimit: 30,
                                         interval: 60))
        XCTAssertTrue(connections.admit(now: now.addingTimeInterval(60),
                                        activeConnections: 0,
                                        maxConnections: 8,
                                        rateLimit: 30,
                                        interval: 60))

        var pairings = RelayRateWindow()
        for _ in 0 ..< 3 {
            XCTAssertTrue(pairings.isAllowed(now: now, limit: 3, interval: 60))
            pairings.record(now)
        }
        XCTAssertFalse(pairings.isAllowed(now: now, limit: 3, interval: 60))
    }

    func testJSONAndFingerprintDepthAndStringCaps() {
        let nested: [String: Any] = [
            "one": ["two": ["three": "value"] as [String: Any]] as [String: Any],
        ]
        XCTAssertFalse(RelayValidation.validJSON(nested, maxDepth: 2))
        XCTAssertTrue(RelayValidation.validJSON(nested, maxDepth: 3))

        let longFingerprint: [String: Any] = ["selector": String(repeating: "x", count: 9)]
        XCTAssertFalse(RelayValidation.validFingerprint(longFingerprint,
                                                        maxDepth: 8,
                                                        maxStringLength: 8))
        XCTAssertTrue(RelayValidation.validFingerprint(longFingerprint,
                                                       maxDepth: 8,
                                                       maxStringLength: 9))
        XCTAssertFalse(RelayValidation.validFingerprint(nested,
                                                        maxDepth: 2,
                                                        maxStringLength: 100))
    }

    func testGeneratedValuesAreURLSafeAndUnique() {
        let a = RelayRandom.generate()
        let b = RelayRandom.generate()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testNativeMessageFramerAccumulatesAndParsesFrames() throws {
        let first = Data(#"{"type":"ping"}"#.utf8)
        let second = Data(#"{"type":"identify"}"#.utf8)
        let encoded = try NativeMessageFramer.encode(first, maxMessageBytes: 64 * 1024)
            + NativeMessageFramer.encode(second, maxMessageBytes: 64 * 1024)
        var framer = NativeMessageFramer(maxMessageBytes: 64 * 1024)

        XCTAssertTrue(try framer.append(encoded.prefix(6)).isEmpty)
        XCTAssertEqual(try framer.append(encoded.dropFirst(6)), [first, second])
    }

    func testNativeMessageFramerRejectsOversizedFrame() {
        var length = UInt32(65 * 1024).littleEndian
        let prefix = withUnsafeBytes(of: &length) { Data($0) }
        var framer = NativeMessageFramer(maxMessageBytes: 64 * 1024)

        XCTAssertThrowsError(try framer.append(prefix)) { error in
            XCTAssertEqual(error as? NativeMessageFramingError, .oversizedFrame(65 * 1024))
        }
    }
}
