import Foundation
import ImageIO

/// The UI supplies a fresh PNG thumbnail, not original image files or metadata.
public enum ProjectIconLimits {
    public static let maximumImageBytes = 128 * 1_024
    public static let maximumPixelDimension = 128
    public static let maximumSymbolLength = 80

    public static func validate(symbol: String, imageData: Data?) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.")
        guard !symbol.isEmpty, symbol.utf8.count <= maximumSymbolLength,
              symbol.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PulseError.invalidConfiguration("Choose a valid symbol for this connection.")
        }
        guard let imageData else { return }
        guard !imageData.isEmpty, imageData.count <= maximumImageBytes else {
            throw PulseError.invalidConfiguration("Choose an icon smaller than 128 KB.")
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(imageData as CFData, options),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...maximumPixelDimension).contains(width), (1...maximumPixelDimension).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, options) != nil else {
            throw PulseError.invalidConfiguration("Choose a PNG icon no larger than 128 × 128 pixels.")
        }
    }
}
