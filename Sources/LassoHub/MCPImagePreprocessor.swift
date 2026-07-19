import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

enum MCPImagePreprocessorError: Error, CustomStringConvertible {
    case invalidPNG
    case invalidMaximumLongSide
    case processingUnavailable
    case thumbnailCreationFailed
    case destinationCreationFailed
    case encodingFailed

    var description: String {
        switch self {
        case .invalidPNG: return "capture PNG could not be decoded"
        case .invalidMaximumLongSide: return "MCP image long-side limit is invalid"
        case .processingUnavailable: return "MCP image resizing is unavailable on this platform"
        case .thumbnailCreationFailed: return "capture PNG thumbnail could not be created"
        case .destinationCreationFailed: return "capture PNG encoder could not be created"
        case .encodingFailed: return "capture PNG thumbnail could not be encoded"
        }
    }
}

/// Prepares stored capture pixels for the MCP wire without touching the
/// full-resolution PNG kept in the Store. Small captures pass through byte for
/// byte; only captures above the long-side budget are decoded and re-encoded.
enum MCPImagePreprocessor {
    static func preparePNG(_ data: Data, maximumLongSide: Int) throws -> Data {
        guard maximumLongSide > 0 else {
            throw MCPImagePreprocessorError.invalidMaximumLongSide
        }
        guard let dimensions = pngDimensions(data) else {
            throw MCPImagePreprocessorError.invalidPNG
        }

#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            throw MCPImagePreprocessorError.invalidPNG
        }

        if max(dimensions.width, dimensions.height) <= maximumLongSide {
            // Force a decode before forwarding the original bytes. The Store's
            // signature check alone cannot distinguish a valid PNG from a
            // truncated or corrupted file.
            guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw MCPImagePreprocessorError.invalidPNG
            }
            return data
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumLongSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw MCPImagePreprocessorError.thumbnailCreationFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw MCPImagePreprocessorError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MCPImagePreprocessorError.encodingFailed
        }
        return output as Data
#else
        guard max(dimensions.width, dimensions.height) <= maximumLongSide else {
            // Never silently bypass the advertised cap on a platform that can
            // compile the Hub but has no native image-resizing implementation.
            throw MCPImagePreprocessorError.processingUnavailable
        }
        return data
#endif
    }

    /// Reads the fixed-width PNG signature and IHDR fields without decoding the
    /// image. This keeps the long-side policy enforceable on every platform the
    /// Swift package can compile for, even where ImageIO is unavailable.
    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let header = [UInt8](data.prefix(24))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard header.count == 24,
              Array(header[0..<8]) == signature,
              header[8...11].elementsEqual([0, 0, 0, 13]),
              header[12...15].elementsEqual([0x49, 0x48, 0x44, 0x52]) else {
            return nil
        }

        func uint32(at offset: Int) -> UInt32 {
            (UInt32(header[offset]) << 24)
                | (UInt32(header[offset + 1]) << 16)
                | (UInt32(header[offset + 2]) << 8)
                | UInt32(header[offset + 3])
        }

        let width = uint32(at: 16)
        let height = uint32(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (Int(width), Int(height))
    }
}
