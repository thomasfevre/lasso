#if os(macOS)
import AppKit
import LassoConductorCore

/// Owns the system share picker and the temporary archive for its full lifetime.
final class CaptureShareCoordinator: NSObject, NSSharingServicePickerDelegate,
                                     NSSharingServiceDelegate {
    private struct PendingShare {
        var pickerID: ObjectIdentifier?
        let lease: TemporaryArtifactLease
        var retryIndex = 0
    }

    private static let cleanupRetryDelays: [TimeInterval] = [0.25, 1, 4]

    private var pending: [URL: PendingShare] = [:]

    func present(archive: URL, relativeTo rect: NSRect, of view: NSView) {
        let picker = NSSharingServicePicker(items: [archive])
        pending[archive] = PendingShare(
            pickerID: ObjectIdentifier(picker),
            lease: TemporaryArtifactLease(url: archive)
        )
        picker.delegate = self
        picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        let pickerID = ObjectIdentifier(sharingServicePicker)
        guard let url = pending.first(where: { $0.value.pickerID == pickerID })?.key else { return }
        guard service != nil else {
            release(archive: url)
            return
        }
        pending[url]?.pickerID = nil
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        release(items: items)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        release(items: items)
    }

    private func release(items: [Any]) {
        for case let url as URL in items {
            release(archive: url)
        }
    }

    private func release(archive: URL) {
        guard let share = pending[archive] else { return }
        if share.lease.release() {
            pending.removeValue(forKey: archive)
        } else {
            guard share.retryIndex < Self.cleanupRetryDelays.count else {
                pending.removeValue(forKey: archive)
                NSLog("Lasso will retry abandoned share cleanup on the next launch: %@", archive.path)
                return
            }
            let delay = Self.cleanupRetryDelays[share.retryIndex]
            pending[archive]?.retryIndex += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.release(archive: archive)
            }
        }
    }
}
#endif
