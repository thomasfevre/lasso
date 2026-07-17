import Foundation

/// Builds the paste-ready prompt the Conductor drops on the clipboard after a
/// Capture (SPE-557), so the user pastes one line into their agent instead of
/// hand-typing "go look at the thing I lassoed". Pure and platform-free so it is
/// unit-testable and reused by any surface that needs the same wording.
public enum CapturePrompt {
    /// A one-line instruction referencing the specific Capture id, appending the
    /// user's note when there is one.
    public static func clipboardStub(id: Int64, note: String?) -> String {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return "Check the latest Lasso capture (id \(id)): \(trimmed)"
        }
        return "Check the latest Lasso capture (id \(id))."
    }
}
