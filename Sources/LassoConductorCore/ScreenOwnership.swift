import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure display-ownership policy for a global capture rectangle. The display
/// with the largest intersecting area owns the capture; ties keep screen order.
public enum ScreenOwnership {
    public static func dominantScreenIndex(for rect: CGRect,
                                           screenFrames: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0

        for (index, frame) in screenFrames.enumerated() {
            let overlap = rect.intersection(frame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }

        return bestIndex
    }
}
