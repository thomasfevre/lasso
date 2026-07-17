#if os(macOS)
import AppKit
import CoreGraphics

/// macOS adapter for SPE-547 routing: snapshots the on-screen window list via
/// `CGWindowListCopyWindowInfo` and maps it into the pure `WindowInfo` values the
/// `GestureRouter` consumes. All CoreGraphics / AppKit specifics live here so the
/// routing core stays platform-free and unit-testable.
///
/// Coordinate spaces: `CGWindowListCopyWindowInfo` reports bounds in Quartz
/// global coordinates (top-left origin), while the Gesture bbox arrives in AppKit
/// global points (bottom-left origin). We flip window bounds into AppKit space so
/// both live in the router's single coordinate system.
import LassoConductorCore

enum WindowEnumerator {
    /// On-screen, normal-layer windows, front-to-back, in AppKit global points.
    /// Menu bar, Dock and other non-zero-layer chrome is excluded, as is Lasso's
    /// own Overlay (it must never be the Target Window).
    static func onScreenWindows(excludingPID ownPID: pid_t = getpid()) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        // AppKit's global origin is the bottom-left of the primary screen; flip
        // Quartz's top-left bounds about that screen's height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        var result: [WindowInfo] = []
        var zOrder = 0
        for entry in raw {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let quartz = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let windowID = entry[kCGWindowNumber as String] as? Int else {
                continue
            }
            let pid = (entry[kCGWindowOwnerPID as String] as? pid_t) ?? -1
            if pid == ownPID { continue } // never route to our own Overlay

            // Quartz bounds (top-left) to AppKit frame (bottom-left) via the shared
            // global flip: the window's Quartz bottom edge (maxY) becomes its
            // AppKit bottom edge (minY). Correct on every display.
            let frame = CGRect(x: quartz.minX,
                               y: ScreenSpace.flipY(quartz.maxY, primaryHeight: primaryHeight),
                               width: quartz.width, height: quartz.height)
            let appName = entry[kCGWindowOwnerName as String] as? String
            // kCGWindowName is often empty (it needs Screen Recording permission
            // and many apps don't set it); treat blank as absent.
            let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let bundleID = pid > 0
                ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                : nil

            result.append(WindowInfo(windowID: windowID, frame: frame,
                                     bundleIdentifier: bundleID, appName: appName,
                                     windowTitle: title, zOrder: zOrder))
            zOrder += 1
        }
        return result
    }
}
#endif
