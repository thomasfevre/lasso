#if os(macOS)
import AppKit
import UserNotifications
import LassoCore
import LassoConductorCore

/// The Conductor's lifecycle owner: installs the global hotkey, keeps a status-bar
/// item, and runs the capture flow (Overlay Gesture -> screenshot -> note -> Store)
/// one at a time.
final class ConductorApp: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var hotkey: GlobalHotkey?
    private var activeHotkey = HotkeyChord.defaultCapture
    private var statusItem: NSStatusItem?
    private var overlay: OverlayController?
    private var isCapturing = false
    private var captureDetail: CaptureDetailController?
    private var captureHistory: CaptureHistoryController?
    private var librarySettings: LibrarySettingsController?
    private var relay: RelayServer?
    private var onboarding: OnboardingController?
    private var requestStore: Store?
    private var requestTimer: Timer?
    private var pendingRequest: CaptureRequest?
    /// The last request id we surfaced a banner for, so a new request notifies
    /// once rather than on every poll tick.
    private var notifiedRequestId: Int64?
    private var postingRequestId: Int64?
    /// The request currently allowed to appear in the menu bar. A different id
    /// waits for the cooldown even though it remains pending in SQLite.
    private var surfacedRequestId: Int64?
    /// Conductor-owned rate limit: dismissing and recreating Store rows cannot
    /// produce banners/sounds more frequently than this interval.
    private var lastRequestNudgeAt: Date?
    private var notificationsReady = false
    /// Caches the built menu-bar image so the 1s status poll doesn't reallocate a
    /// symbol + bitmap every tick when nothing changed.
    private var cachedIconKey: String?
    private var cachedIcon: NSImage?

    // Menu items kept for live updates (SPE-556 feedback / SPE-557 clipboard).
    private var captureItem: NSMenuItem?
    private var showLastCaptureItem: NSMenuItem?
    private var lastCaptureItem: NSMenuItem?
    private var copyRefItem: NSMenuItem?
    private var requestItem: NSMenuItem?
    private var dismissRequestItem: NSMenuItem?
    private var relayStatusItem: NSMenuItem?
    private var revokeRelayItem: NSMenuItem?
    /// The paste-ready stub for the most recent Capture, re-copyable from the menu.
    private var lastCapturePrompt: String?
    /// Tooltip to restore after a pending-request nudge is dismissed, expires,
    /// or is fulfilled.
    private var normalStatusTitle = "Lasso"

    /// Point size of the menu-bar viewfinder glyph — matched to standard menu-bar
    /// icons (a text glyph rendered visibly smaller than its neighbors).
    private static let iconPointSize: CGFloat = 15

    /// Builds the menu-bar icon: a `viewfinder` symbol tinted for the menu bar's
    /// appearance, dimmed when Screen Recording is missing, and badged with a red
    /// dot when an agent has a pending capture request. Recomputed on each status
    /// refresh so it tracks light/dark changes.
    private func statusImage(pending: Bool, blocked: Bool, appearance: NSAppearance?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .regular)
        let glyph = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Lasso")?
            .withSymbolConfiguration(config)
        let isDark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base = isDark ? NSColor.white : NSColor.black
        let ink = blocked ? base.withAlphaComponent(0.35) : base

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let box = NSRect(x: 1, y: 1, width: 16, height: 16)
            glyph?.draw(in: box)
            ink.set()
            box.fill(using: .sourceAtop) // tint the template glyph
            if pending {
                let d: CGFloat = 7
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
            }
            return true
        }
        image.isTemplate = false // manually tinted + colored badge, so not a template
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        setupStatusItem()
        setupRequestNudge()
        setupNotifications()
        activateInitialHotkey()

        do {
            try NativeMessagingHostInstaller.install()
        } catch {
            FileHandle.standardError.write(Data(
                "lasso: could not install Chrome native-messaging host: \(error)\n".utf8))
        }

        // Ask for Screen Recording up front so the capture flow is ready. macOS
        // only shows the system prompt once; the status menu offers the deep link
        // for later.
        Permissions.requestScreenRecording()
        // Accessibility powers the AX Region Context (SPE-546); it is optional
        // (OCR still works without it), so request but never block on it.
        Permissions.requestAccessibility()

        // SPE-548/590: start the native-messaging Relay for the browser extension.
        let server = RelayServer(storeDirectory: Store.defaultDirectory())
        server.start()
        relay = server

        // SPE-552: guided first run, once.
        if !OnboardingController.hasCompleted {
            showOnboarding()
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        requestTimer?.invalidate()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusImage(pending: false, blocked: false,
                                         appearance: item.button?.effectiveAppearance)
        let menu = NSMenu()
        menu.delegate = self // refresh permission-dependent state on open
        menu.autoenablesItems = false // we manage enabled state (disabled header, gated capture)

        // Disabled header showing the latest capture at a glance (SPE-556).
        let last = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)
        lastCaptureItem = last
        menu.addItem(.separator())

        // SPE-565: a request is only a nudge. Clicking this item is a deliberate
        // human trigger of the normal capture path; the Hub never opens Overlay.
        let request = NSMenuItem(title: "An agent is asking you to lasso something",
                                 action: #selector(startCaptureFromMenu), keyEquivalent: "")
        request.target = self
        request.isHidden = true
        // Bold + a viewfinder glyph so the accept action stands out from the
        // ordinary menu items when a request is pending.
        request.attributedTitle = NSAttributedString(
            string: "Capture now for the agent",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        request.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        menu.addItem(request)
        requestItem = request

        let dismiss = NSMenuItem(title: "Dismiss request",
                                 action: #selector(dismissCaptureRequest), keyEquivalent: "")
        dismiss.target = self
        dismiss.isHidden = true
        dismiss.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(dismiss)
        dismissRequestItem = dismiss
        menu.addItem(.separator())

        let capture = NSMenuItem(title: captureMenuTitle(),
                                 action: #selector(startCaptureFromMenu), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        captureItem = capture

        let showLastCapture = NSMenuItem(title: "Show last capture",
                                         action: #selector(showLastCapture), keyEquivalent: "")
        showLastCapture.target = self
        showLastCapture.isEnabled = false
        menu.addItem(showLastCapture)
        showLastCaptureItem = showLastCapture

        let history = NSMenuItem(title: "History…", action: #selector(showCaptureHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showLibrarySettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Re-copy the most recent capture's prompt stub (SPE-557); enabled once
        // there is a capture.
        let copyRef = NSMenuItem(title: "Copy last capture reference",
                                 action: #selector(copyLastCaptureReference), keyEquivalent: "")
        copyRef.target = self
        copyRef.isEnabled = false
        menu.addItem(copyRef)
        copyRefItem = copyRef
        menu.addItem(.separator())
        let permItem = NSMenuItem(title: "Screen Recording permission…",
                                  action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)
        let axItem = NSMenuItem(title: "Accessibility permission…",
                                action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
        let setupItem = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(.separator())
        let relayStatus = NSMenuItem(title: "Browser relay starting…", action: nil, keyEquivalent: "")
        relayStatus.isEnabled = false
        menu.addItem(relayStatus)
        relayStatusItem = relayStatus
        let revokeRelay = NSMenuItem(title: "Revoke all browser pairings…",
                                     action: #selector(revokeAllRelayPairings), keyEquivalent: "")
        revokeRelay.target = self
        menu.addItem(revokeRelay)
        revokeRelayItem = revokeRelay
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lasso", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// Opens the request channel and polls it on the main run loop. SQLite WAL
    /// handles concurrent Hub inserts; polling only updates menu-bar state and
    /// never starts capture on its own.
    private func setupRequestNudge() {
        do {
            requestStore = try Store(directory: Store.defaultDirectory(), access: .requestWriter)
            refreshPendingRequest()
        } catch {
            FileHandle.standardError.write(Data("lasso: request channel unavailable: \(error)\n".utf8))
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPendingRequest()
        }
        RunLoop.main.add(timer, forMode: .common)
        requestTimer = timer
    }

    /// Registers the banner shown when an agent requests a capture. No-op without
    /// a bundle identifier: `UNUserNotificationCenter` requires a real `.app`, so
    /// a bare `swift run` executable relies on the menu-bar badge instead.
    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let capture = UNNotificationAction(identifier: Self.captureActionID,
                                           title: "Capture now", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Self.dismissActionID,
                                           title: "Dismiss", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.requestCategoryID, actions: [capture, dismiss],
            intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notificationsReady = granted }
        }
    }

    /// Re-reads the live authorization state. `notificationsReady` is otherwise
    /// only set at launch, so a permission granted later (in System Settings, or
    /// via a prompt answered after the first poll) would never be picked up by the
    /// running instance without this. Called lazily while a request waits unposted.
    private func refreshNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let ready = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { self?.notificationsReady = ready }
        }
    }

    private static let requestCategoryID = "LASSO_REQUEST"
    private static let captureActionID = "LASSO_CAPTURE"
    private static let dismissActionID = "LASSO_DISMISS"
    private static let minimumRequestNudgeInterval: TimeInterval = 60

    private func refreshPendingRequest() {
        guard let requestStore else { return }
        do {
            let request = try requestStore.pendingRequests().first
            pendingRequest = request
            let now = Date()
            let cooldownElapsed = lastRequestNudgeAt.map {
                now.timeIntervalSince($0) >= Self.minimumRequestNudgeInterval
            } ?? true
            if let request, request.id != surfacedRequestId,
               cooldownElapsed {
                surfacedRequestId = request.id
                lastRequestNudgeAt = now
            }
            let nudgeVisible = request != nil && request?.id == surfacedRequestId
            requestItem?.isHidden = !nudgeVisible
            dismissRequestItem?.isHidden = !nudgeVisible
            if let request, nudgeVisible {
                requestItem?.attributedTitle = NSAttributedString(
                    string: "Capture now for \(request.requester)",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            refreshStatusIcon()
            // Banner once per new request (ids increase monotonically). Only mark
            // the id notified once the banner is actually posted, so a request that
            // arrived before authorization landed (first-launch race, or the user
            // granting permission later in System Settings) still fires once
            // permission is ready rather than being silently swallowed.
            if let request, nudgeVisible {
                if request.id != notifiedRequestId, request.id != postingRequestId {
                    if !postRequestBanner(request: request), !notificationsReady {
                        refreshNotificationAuthorization()
                    }
                }
            } else {
                notifiedRequestId = nil
                if request == nil { surfacedRequestId = nil }
            }
        } catch {
            FileHandle.standardError.write(Data("lasso: request poll failed: \(error)\n".utf8))
        }
    }

    /// Returns whether the banner was actually posted. Authorization and the
    /// Conductor-owned cooldown can both defer it to a later poll tick.
    @discardableResult
    private func postRequestBanner(request: CaptureRequest) -> Bool {
        guard notificationsReady else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Lasso"
        content.body = "\(request.requester) is asking you to lasso something."
        content.categoryIdentifier = Self.requestCategoryID
        content.sound = .default
        // So a delayed Dismiss clears this request, not a newer one.
        content.userInfo = ["requestId": request.id]
        // Reuse the category id as the request id: only one nudge matters at a
        // time, so a second banner deliberately replaces the first.
        postingRequestId = request.id
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.requestCategoryID, content: content, trigger: nil)
        ) { [weak self] error in
            DispatchQueue.main.async {
                guard self?.postingRequestId == request.id else { return }
                self?.postingRequestId = nil
                if error == nil {
                    self?.notifiedRequestId = request.id
                } else {
                    self?.notificationsReady = false
                    self?.refreshNotificationAuthorization()
                }
            }
        }
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let requestId = response.notification.request.content.userInfo["requestId"] as? Int64
        DispatchQueue.main.async { [weak self] in
            switch action {
            case Self.captureActionID, UNNotificationDefaultActionIdentifier:
                self?.startCapture()
            case Self.dismissActionID:
                if let requestId { self?.dismissRequest(id: requestId) } else { self?.dismissCaptureRequest() }
            default:
                break
            }
        }
        completionHandler()
    }

    @objc private func dismissCaptureRequest() {
        guard let pendingRequest else { return }
        dismissRequest(id: pendingRequest.id)
    }

    /// Clears a specific request id. Taken by both the menu Dismiss (current
    /// pending) and a notification action (the id the banner was posted for).
    private func dismissRequest(id: Int64) {
        guard let requestStore else { return }
        do {
            try requestStore.clearRequest(id: id)
            refreshPendingRequest()
        } catch {
            FileHandle.standardError.write(Data("lasso: could not dismiss request: \(error)\n".utf8))
        }
    }

    /// An accessory (`LSUIElement`) app has no menu bar, so text fields never
    /// receive the standard editing shortcuts. Installing a minimal Edit menu
    /// wires ⌘X / ⌘C / ⌘V / ⌘A into the note field (nil-targeted actions travel
    /// the responder chain to the focused control).
    private func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setStatus(title: String) {
        normalStatusTitle = title
        if pendingRequest == nil {
            statusItem?.button?.toolTip = title
        }
    }

    @objc private func startCaptureFromMenu() { startCapture() }

    /// Opens the newest persisted Capture as-is. Unlike the former "Refresh",
    /// this never runs a new screen capture or annotation pass, so the image,
    /// pins, and notes are exactly the record the user previously saved.
    @objc private func showLastCapture() {
        let detail = captureDetail ?? CaptureDetailController()
        captureDetail = detail
        detail.showLatest()
    }

    @objc private func showCaptureHistory() {
        let detail = captureDetail ?? CaptureDetailController()
        captureDetail = detail
        let history = captureHistory ?? CaptureHistoryController(detail: detail)
        captureHistory = history
        history.show()
    }

    @objc private func showLibrarySettings() {
        let settings = librarySettings ?? LibrarySettingsController(
            activeHotkey: { [weak self] in self?.activeHotkey ?? .defaultCapture },
            updateHotkey: { [weak self] chord in self?.updateHotkey(to: chord) ?? false })
        librarySettings = settings
        settings.show()
    }

    @objc private func openScreenRecordingSettings() { Permissions.openScreenRecordingSettings() }

    @objc private func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }

    @objc private func openSetup() { showOnboarding() }

    @objc private func revokeAllRelayPairings() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revoke all browser pairings?"
        alert.informativeText = "Every Lasso extension will need to pair again."
        alert.addButton(withTitle: "Revoke All")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { relay?.revokeAll() }
    }

    private func showOnboarding() {
        let controller = onboarding ?? OnboardingController(
            relay: relay,
            activeHotkey: { [weak self] in self?.activeHotkey ?? .defaultCapture },
            updateHotkey: { [weak self] chord in self?.updateHotkey(to: chord) ?? false })
        onboarding = controller
        controller.show()
    }

    // MARK: - Capture hotkey

    private func activateInitialHotkey() {
        let preferred = HotkeyPreferences.load() ?? .defaultCapture
        do {
            try installHotkey(preferred)
        } catch {
            guard preferred != .defaultCapture else {
                setStatus(title: "Lasso (hotkey unavailable)")
                return
            }
            do {
                try installHotkey(.defaultCapture)
                setStatus(title: "Lasso — saved hotkey unavailable; using \(activeHotkey.description)")
            } catch {
                setStatus(title: "Lasso (hotkey unavailable)")
            }
        }
    }

    /// Registers the replacement before releasing the current registration, so
    /// a rejected chord cannot leave capture without its previous shortcut.
    private func installHotkey(_ chord: HotkeyChord) throws {
        let replacement = try GlobalHotkey(chord: chord) { [weak self] in
            self?.startCapture()
        }
        hotkey = replacement
        activeHotkey = chord
        refreshCaptureMenuItem()
    }

    private func updateHotkey(to chord: HotkeyChord) -> Bool {
        if let validationError = chord.validationError {
            showHotkeyAlert(message: validationError.message)
            return false
        }
        if chord == activeHotkey {
            HotkeyPreferences.save(chord)
            return true
        }
        do {
            try installHotkey(chord)
            HotkeyPreferences.save(chord)
            return true
        } catch {
            showHotkeyAlert(message: error.localizedDescription)
            return false
        }
    }

    private func showHotkeyAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shortcut not available"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func captureMenuTitle(hasScreenRecording: Bool = true) -> String {
        let shortcut = "Capture region  (\(activeHotkey.description))"
        return hasScreenRecording ? shortcut : "\(shortcut) — needs Screen Recording"
    }

    private func refreshCaptureMenuItem() {
        captureItem?.title = captureMenuTitle(
            hasScreenRecording: Permissions.hasScreenRecording)
    }

    // MARK: - Capture flow

    private func startCapture() {
        guard !isCapturing, overlay == nil else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        isCapturing = true

        let controller = OverlayController(screens: screens)
        overlay = controller
        // Snapshot the window z-order *before* the Overlays cover the screens, so
        // routing hit-tests the user's real windows, not our transparent Overlay.
        let windows = WindowEnumerator.onScreenWindows()
        controller.begin { [weak self] globalRect in
            guard let self else { return }
            self.overlay = nil
            guard let rect = globalRect, rect.width > 3, rect.height > 3 else {
                self.isCapturing = false
                return
            }
            // SPE-547: route by where the user pointed. A browser Target Window
            // selects the web Provider (DOM path lands in SPE-549); until then all
            // Providers screen-capture, but a resolved Target Window clips the
            // captured region to that window rather than the raw screen region.
            let decision = GestureRouter.route(gestureBBox: rect, windows: windows)
            let captureRect = decision.targetWindow
                .flatMap { GestureRouter.clip(gestureBBox: rect, to: $0) } ?? rect
            guard let screenIndex = ScreenOwnership.dominantScreenIndex(
                for: captureRect, screenFrames: screens.map(\.frame)) else {
                self.isCapturing = false
                return
            }
            let screen = screens[screenIndex]
            // ScreenCaptureKit captures one physical display at a time. Keep the
            // dominant display's portion so the image and its global rect remain
            // aligned for context extraction and marker resolution.
            let displayRect = captureRect.intersection(screen.frame)
            self.captureAndStore(globalRect: displayRect, screen: screen, routing: decision)
        }
    }

    private func captureAndStore(globalRect: CGRect, screen: NSScreen, routing: RoutingDecision) {
        Task { @MainActor in
            defer { isCapturing = false }
            do {
                let target = routing.targetWindow?.appName ?? "desktop"
                FileHandle.standardError.write(Data(
                    "lasso: routed to \(routing.provider.rawValue) provider (target: \(target))\n".utf8))
                let region = try await RegionCapturer.capture(globalRect: globalRect, screen: screen)
                let regionOCR = try RegionContextExtractor.recognize(region.regionImage)
                var context = await resolveContext(
                    routing: routing, globalRect: globalRect, ocr: regionOCR.selection)
                // SPE-559: tell the Agent what it is looking at (best-effort; the
                // title needs Screen Recording permission and is often absent).
                context.appName = routing.targetWindow?.appName
                context.windowTitle = routing.targetWindow?.windowTitle
                // SPE-555: keyboard-first pin-drop annotate step (skippable).
                let annotation = AnnotationPrompt.run(image: NSImage(data: region.png))
                // SPE-560: resolve each dropped pin to its own element (DOM on web,
                // AX/OCR on screen) so every pin is a precise anchor for the Agent.
                let markers = await resolveMarkers(
                    annotation.markers, routing: routing,
                    globalRect: globalRect, ocr: regionOCR)
                // SPE-562 / SPE-580: redact secrets before anything is written.
                // Text and pixels share one OCR result; pixel failures throw before
                // CaptureWriter can persist the original image.
                let (safeContext, safeMarkers, safeNote) = CaptureRedactor.redact(
                    context: context, markers: markers, note: annotation.note)
                let pixelRedaction = try PixelRedactor.redactSecrets(
                    inPNG: region.png, observations: regionOCR.observations)
                let redactionStatus: RedactionStatus = pixelRedaction.status == .redacted
                    || safeContext != context || safeMarkers != markers || safeNote != annotation.note
                    ? .redacted : .none
                let capture = try CaptureWriter.write(
                    pngData: pixelRedaction.png, note: safeNote,
                    context: safeContext, markers: safeMarkers,
                    tags: annotation.tags,
                    keep: annotation.keep,
                    redactionStatus: redactionStatus)
                didCapture(capture, pins: markers.count)
            } catch {
                report(error)
            }
        }
    }

    /// Resolves the Capture's Region Context. On the web path (SPE-549) the paired
    /// extension resolves the DOM Fingerprint for the gestured region; if that
    /// succeeds the context is `dom`. Otherwise (screen path, or no extension /
    /// timeout) it falls back to OCR + Accessibility (SPE-546).
    @MainActor
    private func resolveContext(routing: RoutingDecision, globalRect: CGRect,
                                ocr: OCRTextSelection) async -> CaptureContext {
        if routing.provider == .web, let relay {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let screenRect = ScreenSpace.topLeftRect(fromBottomLeft: globalRect, primaryHeight: primaryHeight)
            if let json = await relay.resolveFingerprint(screenBBox: screenRect),
               let fingerprint = WebFingerprint.decode(json) {
                return CaptureContext(source: .dom, dom: fingerprint)
            }
        }
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        return RegionContextExtractor.extract(ocr: ocr, gestureCenterGlobal: center)
    }

    /// SPE-560: resolve each pin to the element under it. Pins are normalized to
    /// the captured region image; map each back to its global point and query the
    /// live target — on web the paired extension resolves a per-pin DOM Fingerprint
    /// (a tiny bbox around the pin), on screen the AX element / neighborhood OCR.
    /// Runs after the annotate step, so it reflects the target as it is now; all
    /// resolution is best-effort and a pin with neither is left as-is.
    @MainActor
    private func resolveMarkers(_ markers: [Marker], routing: RoutingDecision,
                               globalRect: CGRect, ocr: RegionOCRResult) async -> [Marker] {
        guard !markers.isEmpty else { return markers }

        // Pin's global point (AppKit, bottom-left). marker.y is top-left
        // normalized, so subtract from the region's top edge (globalRect.maxY).
        // This is exactly the inverse of how the region image was produced — see
        // RegionCapturer.crop and PinCanvasView.normalize (AnnotationPrompt).
        func globalPoint(_ marker: Marker) -> CGPoint {
            CGPoint(x: globalRect.minX + CGFloat(marker.x) * globalRect.width,
                    y: globalRect.maxY - CGFloat(marker.y) * globalRect.height)
        }

        if routing.provider == .web, let relay {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            // A tiny bbox around each pin; resolve them CONCURRENTLY so an absent or
            // slow extension can't stack N per-pin timeouts into one long hang.
            let boxes: [(Int, CGRect)] = markers.enumerated().map { index, marker in
                let sp = ScreenSpace.topLeftPoint(fromBottomLeft: globalPoint(marker), primaryHeight: primaryHeight)
                return (index, CGRect(x: sp.x - 1, y: sp.y - 1, width: 2, height: 2))
            }
            var out = markers
            await withTaskGroup(of: (Int, DOMFingerprint?).self) { group in
                for (index, box) in boxes {
                    group.addTask {
                        guard let json = await relay.resolveFingerprint(screenBBox: box) else { return (index, nil) }
                        return (index, WebFingerprint.decode(json))
                    }
                }
                for await (index, fingerprint) in group { out[index].dom = fingerprint }
            }
            return out
        }

        // Screen path: local AX / OCR, fast and with no network hang, so a simple
        // sequential pass on the main actor is fine.
        var out: [Marker] = []
        for var marker in markers {
            marker.text = RegionContextExtractor.pinText(
                ocr: ocr, normalized: CGPoint(x: marker.x, y: marker.y),
                globalPoint: globalPoint(marker))
            out.append(marker)
        }
        return out
    }

    private func report(_ error: Error) {
        setStatus(title: "Lasso — capture failed")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Lasso could not capture"
        alert.informativeText = "\(error)\n\nLasso needs Screen Recording permission. Open Settings, enable Lasso, then try the capture again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openScreenRecordingSettings()
        }
    }

    // MARK: - Capture feedback (SPE-556) + clipboard handoff (SPE-557)

    /// Runs only on the success path: confirms the capture audibly, refreshes the
    /// menu header, and drops a paste-ready prompt on the clipboard so the user
    /// can hand it straight to their agent.
    private func didCapture(_ capture: Capture, pins: Int) {
        NSSound(named: "Pop")?.play()

        let noun = pins == 1 ? "pin" : "pins"
        lastCaptureItem?.title = "Last: id \(capture.id) · \(pins) \(noun) · \(capture.context.source.rawValue)"

        let stub = CapturePrompt.clipboardStub(id: capture.id, note: capture.note)
        lastCapturePrompt = stub
        copyToClipboard(stub)
        copyRefItem?.isEnabled = true

        // A successful human-triggered Capture fulfills requests that existed
        // when it was written. A request created afterward remains pending.
        if let requestStore {
            do {
                try requestStore.clearRequests(createdThrough: capture.createdAt)
                refreshPendingRequest()
            } catch {
                FileHandle.standardError.write(Data("lasso: could not clear fulfilled request: \(error)\n".utf8))
            }
        }

        setStatus(title: "Lasso — last capture id \(capture.id)")
    }

    /// Writes to the clipboard only — Lasso never sends synthetic keystrokes to
    /// the agent, which would break its passive/pull-based principle (SPE-557).
    private func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    @objc private func copyLastCaptureReference() {
        guard let stub = lastCapturePrompt else { return }
        copyToClipboard(stub)
    }

    // MARK: - NSMenuDelegate

    /// Reflects live permission state each time the menu opens (SPE-556): a
    /// missing Screen Recording grant disables capture and flips the menu-bar
    /// glyph to a warning, so the blocked state is obvious before the overlay.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPendingRequest()
        let hasScreen = Permissions.hasScreenRecording
        captureItem?.isEnabled = hasScreen
        captureItem?.title = captureMenuTitle(hasScreenRecording: hasScreen)
        showLastCaptureItem?.isEnabled = hasStoredCapture()
        requestItem?.isEnabled = hasScreen
        relayStatusItem?.title = relay?.statusSummary ?? "Browser relay unavailable"
        revokeRelayItem?.isEnabled = relay != nil
        refreshStatusIcon(hasScreenRecording: hasScreen)
    }

    /// The capture library can be inspected even when Screen Recording is
    /// currently unavailable, so this deliberately uses a reader-only Store and
    /// has no permission gate.
    private func hasStoredCapture() -> Bool {
        guard let store = try? Store(directory: Store.defaultDirectory(), access: .reader) else {
            return false
        }
        return (try? store.latest()) != nil
    }

    private func refreshStatusIcon(hasScreenRecording: Bool = Permissions.hasScreenRecording) {
        guard let button = statusItem?.button else { return }
        // Require a real pending request: `nil == nil` would otherwise read as
        // "pending" and badge the icon red with nothing actually queued.
        let pending = pendingRequest != nil && pendingRequest?.id == surfacedRequestId
        let blocked = !hasScreenRecording
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(pending)-\(blocked)-\(isDark)"
        if key != cachedIconKey {
            cachedIcon = statusImage(pending: pending, blocked: blocked,
                                     appearance: button.effectiveAppearance)
            cachedIconKey = key
        }
        button.image = cachedIcon
        if pending, let pendingRequest {
            button.toolTip = "Lasso — \(pendingRequest.requester) is asking for a capture"
        } else {
            button.toolTip = normalStatusTitle
        }
    }
}
#endif
