import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGRect.contains/.intersection live here on Apple platforms
#endif

// SPE-547: Gesture-driven window routing. The Conductor chooses what to capture
// by where the user pointed, not by which app is frontmost. This module is the
// pure routing core (ADR 0003): it takes a fixture-friendly window z-order list
// plus a Gesture bbox and returns the Target Window and the Provider. It holds no
// AppKit / CGWindowList types so it builds and unit-tests on every platform; the
// macOS `WindowEnumerator` maps the live window list into these values.

/// Which Provider a Capture should be routed to. `web` when a browser owns the
/// Target Window (the DOM path, SPE-549); `screen` for everything else, including
/// an empty hit (desktop) — the annotated-screenshot path.
public enum Provider: String, Sendable, Equatable {
    case web
    case screen
}

/// One on-screen window as the router needs to see it. `frame` is in the same
/// coordinate space as the Gesture bbox (AppKit global points, bottom-left
/// origin). `zOrder` is front-to-back: 0 is the frontmost window, larger is
/// further back — the order `CGWindowListCopyWindowInfo` already returns.
public struct WindowInfo: Sendable, Equatable {
    public var windowID: Int
    public var frame: CGRect
    public var bundleIdentifier: String?
    public var appName: String?
    public var windowTitle: String?
    public var zOrder: Int

    public init(windowID: Int, frame: CGRect, bundleIdentifier: String?,
                appName: String?, windowTitle: String? = nil, zOrder: Int) {
        self.windowID = windowID
        self.frame = frame
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.zOrder = zOrder
    }
}

/// The routing outcome: the Target Window the Gesture landed on (nil when the
/// Gesture is over the desktop / no window), and the Provider to capture with.
public struct RoutingDecision: Sendable, Equatable {
    public var targetWindow: WindowInfo?
    public var provider: Provider

    public init(targetWindow: WindowInfo?, provider: Provider) {
        self.targetWindow = targetWindow
        self.provider = provider
    }
}

/// Known browser bundle identifiers. A browser-owned Target Window routes to the
/// web Provider; anything else routes to screen capture.
public enum BrowserCatalog {
    public static let defaultBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",   // Arc
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    public static func isBrowser(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier else { return false }
        return defaultBundleIDs.contains(id)
    }
}

public enum GestureRouter {
    /// Hit-tests the Gesture against the window list and picks the Provider.
    ///
    /// The representative point is the Gesture bbox centre: overlapping windows
    /// are disambiguated by *where* the user pointed, never by focus/frontmost.
    /// Among all windows containing that point, the one with the smallest
    /// `zOrder` (frontmost) wins. With no window under the point the Gesture is
    /// over the desktop, so the target is nil and we screen-capture.
    ///
    /// `isBrowser` is injectable so tests can pin the catalog; it defaults to
    /// `BrowserCatalog.isBrowser`.
    public static func route(gestureBBox: CGRect,
                             windows: [WindowInfo],
                             isBrowser: (String?) -> Bool = BrowserCatalog.isBrowser) -> RoutingDecision {
        let point = CGPoint(x: gestureBBox.midX, y: gestureBBox.midY)
        let target = windows
            .filter { $0.frame.contains(point) }
            .min { $0.zOrder < $1.zOrder }

        guard let target else {
            return RoutingDecision(targetWindow: nil, provider: .screen)
        }
        let provider: Provider = isBrowser(target.bundleIdentifier) ? .web : .screen
        return RoutingDecision(targetWindow: target, provider: provider)
    }

    /// Clips a Gesture bbox to the Target Window's frame so a screen Capture
    /// targets the resolved window region, not the raw screen region. Returns nil
    /// when the Gesture lies entirely outside the window (an empty intersection).
    public static func clip(gestureBBox: CGRect, to window: WindowInfo) -> CGRect? {
        let clipped = gestureBBox.intersection(window.frame)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}
