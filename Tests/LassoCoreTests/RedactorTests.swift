import XCTest
@testable import LassoCore

// SPE-562: the text redactor is a pure function — one test per known pattern,
// plus false-positive edges and the "no secrets → unchanged" guarantee.
final class RedactorTests: XCTestCase {
    private func redact(_ s: String, emails: Bool = false) -> SecretRedactor.Result {
        SecretRedactor.redact(s, options: .init(redactEmails: emails))
    }

    func testJWTRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let r = redact("token: \(jwt)")
        XCTAssertFalse(r.text.contains(jwt))
        XCTAssertTrue(r.text.contains(SecretRedactor.placeholder))
        XCTAssertTrue(r.matches.contains { $0.kind == "jwt" })
    }

    func testOpenAIKeyRedacted() {
        let key = "sk-proj-abc123DEF456ghi789JKL012mno"
        let r = redact("OPENAI_API_KEY=\(key)")
        XCTAssertFalse(r.text.contains(key))
        XCTAssertTrue(r.matches.contains { $0.kind == "openai-key" })
    }

    func testGitHubTokenRedacted() {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let r = redact("clone with \(token)")
        XCTAssertFalse(r.text.contains(token))
        XCTAssertTrue(r.matches.contains { $0.kind == "github-token" })
    }

    func testGitHubPATRedacted() {
        let token = "github_pat_11ABCDE0123456789_abcDEFghiJKLmnoPQRstu"
        let r = redact(token)
        XCTAssertFalse(r.text.contains(token))
        XCTAssertTrue(r.matches.contains { $0.kind == "github-pat" })
    }

    func testAWSAccessKeyRedacted() {
        let key = "AKIAIOSFODNN7EXAMPLE"
        let r = redact("aws_access_key_id = \(key)")
        XCTAssertFalse(r.text.contains(key))
        XCTAssertTrue(r.matches.contains { $0.kind == "aws-access-key" })
    }

    func testHighEntropyTokenRedacted() {
        // A random-looking mixed-case+digit token the named patterns don't cover.
        let secret = "Xa7Kd9Qm2Zp5Lb8Rw3Nc6Vt1Yj4"
        let r = redact("SECRET=\(secret)")
        XCTAssertFalse(r.text.contains(secret))
        XCTAssertTrue(r.matches.contains { $0.kind == "high-entropy" })
    }

    // MARK: - No secrets / false-positive edges

    func testPlainProseUnchanged() {
        let text = "The quick brown fox jumps over the lazy dog near the terminal window."
        let r = redact(text)
        XCTAssertEqual(r.text, text)
        XCTAssertFalse(r.didRedact)
    }

    func testFilePathUnchanged() {
        let text = "Open ~/Library/Application Support/Lasso/store.sqlite3 in the editor"
        let r = redact(text)
        XCTAssertEqual(r.text, text)
        XCTAssertFalse(r.didRedact)
    }

    func testGitShaNotTreatedAsSecret() {
        // A 40-char lowercase hex SHA is two character classes only — not redacted.
        let text = "commit e0cd45d5a1b2c3d4e5f60718293a4b5c6d7e8f90 landed"
        let r = redact(text)
        XCTAssertEqual(r.text, text)
        XCTAssertFalse(r.didRedact)
    }

    func testLongLowercaseWordUnchanged() {
        let text = "antidisestablishmentarianism supercalifragilistic"
        let r = redact(text)
        XCTAssertEqual(r.text, text)
    }

    func testEmailOnlyRedactedWhenEnabled() {
        let text = "contact toma@allez.xyz for access"
        XCTAssertFalse(redact(text).didRedact)
        let on = redact(text, emails: true)
        XCTAssertTrue(on.didRedact)
        XCTAssertFalse(on.text.contains("toma@allez.xyz"))
    }

    func testEmptyStringUnchanged() {
        let r = redact("")
        XCTAssertEqual(r.text, "")
        XCTAssertFalse(r.didRedact)
    }

    func testMultipleSecretsAllRedacted() {
        let text = "key sk-abcdefghij0123456789KLMN and AKIAIOSFODNN7EXAMPLE together"
        let r = redact(text)
        XCTAssertFalse(r.text.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertGreaterThanOrEqual(r.matches.count, 2)
        // Surrounding words survive.
        XCTAssertTrue(r.text.contains("key"))
        XCTAssertTrue(r.text.contains("together"))
    }

    // MARK: - CaptureRedactor across the contract

    func testCaptureRedactorCleansContextAndMarkers() {
        let secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let context = CaptureContext(
            source: .ocr, text: "found \(secret) here",
            dom: DOMFingerprint(selector: "#x", text: secret, nearbyText: "near \(secret)"),
            windowTitle: "term — export \(secret)")
        let markers = [Marker(index: 1, x: 0.1, y: 0.2, note: "paste \(secret)", text: secret)]
        let (ctx, out, note) = CaptureRedactor.redact(
            context: context, markers: markers, note: "capture with \(secret)")
        XCTAssertFalse(ctx.text!.contains(secret))
        XCTAssertFalse(ctx.dom!.text!.contains(secret))
        XCTAssertFalse(ctx.dom!.nearbyText!.contains(secret))
        XCTAssertFalse(ctx.windowTitle!.contains(secret))
        XCTAssertFalse(out[0].text!.contains(secret))
        // User-typed notes can carry a pasted credential — they are redacted too.
        XCTAssertFalse(out[0].note!.contains(secret))
        XCTAssertFalse(note!.contains(secret))
    }

    func testCaptureRedactorLeavesSafeStructuralAnchorsIntact() {
        let context = CaptureContext(
            source: .dom,
            dom: DOMFingerprint(selector: "#buy-button", role: "button", componentName: "BuyButton"),
            appName: "Safari")
        let (ctx, _, _) = CaptureRedactor.redact(context: context, markers: [], note: nil)
        XCTAssertEqual(ctx.dom?.selector, "#buy-button")
        XCTAssertEqual(ctx.dom?.role, "button")
        XCTAssertEqual(ctx.dom?.componentName, "BuyButton")
        XCTAssertEqual(ctx.appName, "Safari")
    }

    func testCaptureRedactorCleansEveryDOMStringField() {
        let secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let context = CaptureContext(
            source: .dom,
            dom: DOMFingerprint(selector: "#\(secret)", role: secret,
                                text: secret, nearbyText: secret, componentName: secret))
        let marker = Marker(index: 1, x: 0.5, y: 0.5,
                            dom: DOMFingerprint(selector: "#\(secret)", role: secret,
                                                componentName: secret))
        let (ctx, markers, _) = CaptureRedactor.redact(context: context, markers: [marker], note: nil)

        for dom in [ctx.dom, markers[0].dom].compactMap({ $0 }) {
            XCTAssertFalse(dom.selector.contains(secret))
            XCTAssertFalse(dom.role?.contains(secret) ?? false)
            XCTAssertFalse(dom.componentName?.contains(secret) ?? false)
        }
        XCTAssertFalse(ctx.dom?.text?.contains(secret) ?? false)
        XCTAssertFalse(ctx.dom?.nearbyText?.contains(secret) ?? false)
    }

    func testCaptureRedactorRejectsOversizedOrUnsafeStructuralAnchors() {
        let context = CaptureContext(
            source: .dom,
            dom: DOMFingerprint(selector: "#" + String(repeating: "a", count: 300),
                                role: "button onclick=steal()",
                                componentName: "Secret/Component"))
        let (ctx, _, _) = CaptureRedactor.redact(context: context, markers: [], note: nil)

        XCTAssertEqual(ctx.dom?.selector, SecretRedactor.placeholder)
        XCTAssertEqual(ctx.dom?.role, SecretRedactor.placeholder)
        XCTAssertEqual(ctx.dom?.componentName, SecretRedactor.placeholder)
    }

    func testCaptureRedactorRejectsAttributeSelectorValues() {
        let context = CaptureContext(
            source: .dom,
            dom: DOMFingerprint(selector: "[data-secret='swordfish']"))
        let (ctx, _, _) = CaptureRedactor.redact(context: context, markers: [], note: nil)

        XCTAssertEqual(ctx.dom?.selector, SecretRedactor.placeholder)
    }

    func testCaptureRedactorNoSecretsUnchanged() {
        let context = CaptureContext(source: .ocr, text: "just some ordinary label text")
        let markers = [Marker(index: 1, x: 0.5, y: 0.5, note: "here", text: "Submit")]
        let (ctx, out, note) = CaptureRedactor.redact(
            context: context, markers: markers, note: "a plain note")
        XCTAssertEqual(ctx.text, "just some ordinary label text")
        XCTAssertEqual(out, markers)
        XCTAssertEqual(note, "a plain note")
    }
}
