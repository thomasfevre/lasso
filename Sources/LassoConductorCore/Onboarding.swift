import Foundation

// SPE-552: first-run onboarding. This is the pure step-progression logic behind
// the guided flow — which step the user is on given what is already satisfied —
// kept platform-free so it unit-tests without any UI. The macOS
// `OnboardingWindow` renders the current step and feeds live status in.

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case permissions      // Screen Recording (required) + Accessibility (optional)
    case extensionPairing // OPTIONAL browser extension; enables the web/DOM path
    case registerAgents   // copy the MCP registration snippets into each client
    case done
}

/// What the flow knows about the environment right now. All false at first run.
public struct OnboardingState: Sendable, Equatable {
    public var screenRecordingGranted: Bool
    public var accessibilityGranted: Bool
    public var extensionPaired: Bool
    /// The user explicitly moved past the extension step without pairing. The
    /// extension is optional — screen capture works fully without it — so this
    /// (or an actual pairing) lets the flow advance.
    public var extensionSkipped: Bool
    public var agentsAcknowledged: Bool

    public init(screenRecordingGranted: Bool = false,
                accessibilityGranted: Bool = false,
                extensionPaired: Bool = false,
                extensionSkipped: Bool = false,
                agentsAcknowledged: Bool = false) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
        self.extensionPaired = extensionPaired
        self.extensionSkipped = extensionSkipped
        self.agentsAcknowledged = agentsAcknowledged
    }

    /// Screen Recording is required to capture; Accessibility is optional (OCR
    /// still works without it, SPE-546), so it does not gate this step.
    public var permissionsComplete: Bool { screenRecordingGranted }

    /// The extension is a convenience for the web/DOM path, not a requirement.
    /// The step is done once it either pairs or the user chooses to skip it.
    public var extensionStepComplete: Bool { extensionPaired || extensionSkipped }

    public var currentStep: OnboardingStep {
        if !permissionsComplete { return .permissions }
        if !extensionStepComplete { return .extensionPairing }
        if !agentsAcknowledged { return .registerAgents }
        return .done
    }

    public var isComplete: Bool { currentStep == .done }
}
