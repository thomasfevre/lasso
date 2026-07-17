#if os(macOS)
import Foundation
import LassoCore

/// Writes a Capture through the shared LassoCore write path — the exact call the
/// Store tests already exercise. The Region Context (SPE-546) is resolved by the
/// caller and passed in; it defaults to `none` for callers that have none.
enum CaptureWriter {
    @discardableResult
    static func write(pngData: Data, note: String?,
                      context: CaptureContext = CaptureContext(source: .none),
                      markers: [Marker] = [],
                      tags: [String] = [],
                      keep: Bool = false,
                      redactionStatus: RedactionStatus = .none) throws -> Capture {
        let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
        let capture = try store.insert(imagePNG: pngData, context: context, note: note,
                                markers: markers, redactionStatus: redactionStatus)
        try store.updateTags(tags, id: capture.id)
        try store.setKept(keep, id: capture.id)
        return try store.capture(id: capture.id) ?? capture
    }
}
#endif
