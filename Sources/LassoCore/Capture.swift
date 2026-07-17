import Foundation

/// Version of the Capture contract. Bumped independently of Providers when the
/// wire shape changes (ADR 0004: the tool's return signature is versioned).
/// v2 (ADR 0011) added `Capture.markers`; v3 (SPE-560) added per-pin element
/// resolution (`Marker.dom` / `Marker.text`); v4 (SPE-564) added the optional
/// code-aware OCR layout hint (`CaptureContext.layout`); v5 (SPE-580) records
/// the capture redaction outcome; v6 adds library state and user tags.
public let captureSchemaVersion = 6

/// Where the Region Context text came from. `none` means nothing was extractable.
public enum ContextSource: String, Codable, Sendable {
    case dom
    case ocr
    case accessibility
    case none
}

/// Visual layout inferred for OCR text. Prose is the default OCR behavior;
/// `code` tells consumers that identifiers and line structure were preserved.
public enum TextLayout: String, Codable, Sendable {
    case code
    case prose
}

/// Aggregate outcome of the capture redaction gate. `failed` is available for an explicit
/// future store-unredacted override; the Conductor currently fails closed and
/// does not persist that outcome.
public enum RedactionStatus: String, Codable, Sendable {
    case redacted
    case failed
    case none
}

/// Placement inside the local capture library. Recent captures follow normal
/// retention, Kept captures are preserved, and deleted captures stay restorable
/// until their retention window expires.
public enum CaptureLibraryState: String, Codable, Sendable {
    case recent
    case kept
    case recentlyDeleted
}

/// Canonicalizes user-entered labels so filtering and suggestions never split
/// the same tag merely because it was typed with different casing or spacing.
public enum CaptureTag {
    public static func normalize(_ rawTags: [String]) -> [String] {
        var unique: [String: String] = [:]
        for raw in rawTags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if unique[key] == nil { unique[key] = tag }
        }
        return unique.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// A bounding box in the coordinate space of its Provider (screen pixels for the
/// screen Provider, CSS pixels for the web Provider).
public struct BBox: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Structural signals about the web element under the Gesture. The Agent uses
/// this to locate `file:line` in the repo; Lasso never resolves it (ADR 0006).
public struct DOMFingerprint: Codable, Sendable, Equatable {
    public var selector: String
    public var role: String?
    public var text: String?
    public var nearbyText: String?
    public var componentName: String?
    public var bbox: BBox?

    public init(
        selector: String,
        role: String? = nil,
        text: String? = nil,
        nearbyText: String? = nil,
        componentName: String? = nil,
        bbox: BBox? = nil
    ) {
        self.selector = selector
        self.role = role
        self.text = text
        self.nearbyText = nearbyText
        self.componentName = componentName
        self.bbox = bbox
    }
}

/// The single `context` block every Capture carries. No target-specific fields
/// and no file-resolution field (ADR 0004 / 0006).
public struct CaptureContext: Codable, Sendable, Equatable {
    public var source: ContextSource
    public var text: String?
    public var dom: DOMFingerprint?
    /// The target window's owning app (e.g. "Safari", "Code") and window title,
    /// so the Agent knows what it is looking at without guessing from pixels
    /// (SPE-559). Both are best-effort: the title needs Screen Recording
    /// permission and many apps leave it empty.
    public var appName: String?
    public var windowTitle: String?
    /// Present as `code` only when screen OCR chose the identifier-preserving
    /// path. Nil keeps prose and contexts written by older versions unchanged.
    public var layout: TextLayout?

    public init(source: ContextSource = .none, text: String? = nil, dom: DOMFingerprint? = nil,
                appName: String? = nil, windowTitle: String? = nil, layout: TextLayout? = nil) {
        self.source = source
        self.text = text
        self.dom = dom
        self.appName = appName
        self.windowTitle = windowTitle
        self.layout = layout
    }
}

/// A numbered pin the user drops on the capture to hand the Agent structured
/// spatial intent (ADR 0011). `index` is the 1-based pin number; `x`/`y` are
/// normalized to `[0, 1]` relative to the capture image, so any renderer or
/// Agent can place the pin regardless of image size. `note` is an optional short
/// label. `dom` / `text` are the per-pin element resolution (SPE-560): on a web
/// target the pin's DOM fingerprint (a precise `file:line` anchor for that pin),
/// on a screen target the accessibility/OCR text under the pin. Both are
/// best-effort and optional — a pin with neither is still valid.
public struct Marker: Codable, Sendable, Equatable {
    public var index: Int
    public var x: Double
    public var y: Double
    public var note: String?
    public var dom: DOMFingerprint?
    public var text: String?

    public init(index: Int, x: Double, y: Double, note: String? = nil,
                dom: DOMFingerprint? = nil, text: String? = nil) {
        self.index = index
        self.x = x
        self.y = y
        self.note = note
        self.dom = dom
        self.text = text
    }

    /// True when the marker is inside the contract's bounds: a positive pin
    /// number and a normalized point within `[0, 1]` on both axes.
    public var isValid: Bool {
        index >= 1 && (0...1).contains(x) && (0...1).contains(y)
    }
}

/// A single Capture as stored and read back. `imageFile` is the PNG's filename
/// within the Store directory; it is a Store-internal reference, not part of the
/// MCP wire shape (the Hub sends the image bytes as a base64 content block).
public struct Capture: Sendable, Equatable {
    public var id: Int64
    public var createdAt: Date
    public var imageFile: String
    public var note: String?
    public var context: CaptureContext
    public var markers: [Marker]
    public var redactionStatus: RedactionStatus
    public var tags: [String]
    public var libraryState: CaptureLibraryState
    public var deletedAt: Date?
    public var deletedFromState: CaptureLibraryState?

    public init(id: Int64, createdAt: Date, imageFile: String, note: String?,
                context: CaptureContext, markers: [Marker] = [],
                redactionStatus: RedactionStatus = .none, tags: [String] = [],
                libraryState: CaptureLibraryState = .recent, deletedAt: Date? = nil,
                deletedFromState: CaptureLibraryState? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.imageFile = imageFile
        self.note = note
        self.context = context
        self.markers = markers
        self.redactionStatus = redactionStatus
        self.tags = tags
        self.libraryState = libraryState
        self.deletedAt = deletedAt
        self.deletedFromState = deletedFromState
    }

    /// Seconds elapsed since the Capture was written, as of `now`.
    public func age(now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(createdAt))
    }
}
