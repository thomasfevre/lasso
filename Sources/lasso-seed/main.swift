import Foundation
import LassoCore

// Dev / verification utility: writes one fixture Capture into the Store so the
// Hub has something to return during end-to-end checks. NOT part of the shipped
// product — the Conductor is the real writer. Keeps `lasso-mcp` a pure reader.
//
// Usage: lasso-seed [--dom] [--pins] [--note "..."]
//   default: a screen Capture (source=none)
//   --dom:   a structured web Capture with a DOM Fingerprint
//   --pins:  attach two numbered pin markers (SPE-554)

let args = CommandLine.arguments
let wantDOM = args.contains("--dom")
let wantPins = args.contains("--pins")
let note: String? = {
    if let i = args.firstIndex(of: "--note"), i + 1 < args.count { return args[i + 1] }
    return nil
}()

// A 1x1 transparent PNG. The contract does not validate pixels; any bytes work.
let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMCAQAB6E+GAAAAAElFTkSuQmCC"
guard let png = Data(base64Encoded: pngBase64) else {
    FileHandle.standardError.write(Data("lasso-seed: bad fixture png\n".utf8))
    exit(1)
}

let context: CaptureContext = wantDOM
    ? CaptureContext(
        source: .dom,
        text: "Save",
        dom: DOMFingerprint(
            selector: "button.primary[data-testid='save']",
            role: "button",
            text: "Save",
            nearbyText: "Cancel",
            componentName: "SaveButton",
            bbox: BBox(x: 120, y: 340, width: 88, height: 32)
        )
    )
    : CaptureContext(source: .none, text: nil, dom: nil)

do {
    let markers: [Marker] = wantPins
        ? [Marker(index: 1, x: 0.25, y: 0.4, note: "this button"),
           Marker(index: 2, x: 0.8, y: 0.6, note: "broken here")]
        : []
    let store = try Store(directory: Store.defaultDirectory())
    let capture = try store.insert(imagePNG: png, context: context, note: note, markers: markers)
    FileHandle.standardError.write(Data("lasso-seed: wrote capture id=\(capture.id) source=\(context.source.rawValue) markers=\(capture.markers.count)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("lasso-seed: \(error)\n".utf8))
    exit(1)
}
