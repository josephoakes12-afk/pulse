import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The same icon treatment is used in the panel, connection list and editor.
@MainActor
struct ConnectionIconView: View {
    let symbol: String
    let imageData: Data?
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
            if let imageData, let image = ConnectionIconImages.image(for: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.1)
            } else {
                Image(nsImage: ConnectionIconImages.symbol(named: symbol))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.23)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var cornerRadius: CGFloat { min(8, size / 4) }
}

@MainActor
struct ConnectionIconButton: View {
    let symbol: String
    let imageData: Data?
    var size: CGFloat = 32
    let onSelect: @MainActor (String, Data?) -> Void
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker.toggle() } label: {
            ConnectionIconView(symbol: symbol, imageData: imageData, size: size)
                .contentShape(RoundedRectangle(cornerRadius: min(8, size / 4)))
        }
        .buttonStyle(.plain)
        .help("Change icon")
        .accessibilityLabel("Change connection icon")
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            ConnectionIconPicker(symbol: symbol, imageData: imageData) { selection, data in
                onSelect(selection, data)
                showingPicker = false
            } chooseImage: {
                // The panel may dismiss the menu-bar popover. Its completion owns
                // the callback, rather than depending on this view remaining alive.
                showingPicker = false
                ConnectionIconImport.chooseImage(symbol: symbol, onSelect: onSelect)
            }
        }
    }
}

@MainActor
private struct ConnectionIconPicker: View {
    let symbol: String
    let imageData: Data?
    let onSelect: @MainActor (String, Data?) -> Void
    let chooseImage: @MainActor () -> Void
    @State private var search = ""

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 6), count: 6)

    var body: some View {
        VStack(spacing: 12) {
            TextField("Search icons", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search icons")
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(filteredIcons) { icon in
                        iconButton(icon)
                    }
                }
                .padding(2)
                .frame(maxWidth: .infinity, alignment: .top)
                if filteredIcons.isEmpty {
                    Text("No icons")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
            .frame(height: 212)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            Button(action: chooseImage) {
                Label("Choose Image…", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .accessibilityLabel("Choose a custom connection image")
        }
        .padding(14)
        .frame(width: 280)
    }

    private var filteredIcons: [ConnectionIconOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ConnectionIconOption.library }
        return ConnectionIconOption.library.filter {
            $0.label.localizedCaseInsensitiveContains(query) ||
                $0.keywords.localizedCaseInsensitiveContains(query) ||
                $0.symbol.localizedCaseInsensitiveContains(query)
        }
    }

    private func iconButton(_ icon: ConnectionIconOption) -> some View {
        let selected = imageData == nil && icon.symbol == symbol
        return Button { onSelect(icon.symbol, nil) } label: {
            Image(nsImage: ConnectionIconImages.symbol(named: icon.symbol))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 36, height: 36)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(icon.label)
        .accessibilityLabel(icon.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ConnectionIconOption: Identifiable, Sendable {
    let symbol: String
    let label: String
    let keywords: String
    var id: String { symbol }

    static let library: [Self] = [
        .init(symbol: "square.stack.3d.up", label: "Project", keywords: "app stack"),
        .init(symbol: "calendar", label: "Calendar", keywords: "booking schedule event"),
        .init(symbol: "gamecontroller", label: "Game", keywords: "play players"),
        .init(symbol: "newspaper", label: "Publication", keywords: "news readers article"),
        .init(symbol: "globe", label: "Website", keywords: "web internet world"),
        .init(symbol: "bag", label: "Shop", keywords: "store shopping retail"),
        .init(symbol: "person.2", label: "People", keywords: "users customers members"),
        .init(symbol: "person.3", label: "Community", keywords: "team group audience"),
        .init(symbol: "building.2", label: "Business", keywords: "company office"),
        .init(symbol: "storefront", label: "Storefront", keywords: "venue shop cafe restaurant"),
        .init(symbol: "cart", label: "Orders", keywords: "sales commerce checkout"),
        .init(symbol: "creditcard", label: "Payments", keywords: "money revenue subscriptions"),
        .init(symbol: "chart.bar", label: "Chart", keywords: "analytics stats numbers"),
        .init(symbol: "chart.line.uptrend.xyaxis", label: "Growth", keywords: "trend analytics"),
        .init(symbol: "heart", label: "Heart", keywords: "health favourites likes"),
        .init(symbol: "star", label: "Star", keywords: "rating favourites"),
        .init(symbol: "sparkles", label: "Sparkles", keywords: "creative magic"),
        .init(symbol: "leaf", label: "Leaf", keywords: "nature environment"),
        .init(symbol: "sun.max", label: "Sun", keywords: "weather day"),
        .init(symbol: "moon", label: "Moon", keywords: "night sleep"),
        .init(symbol: "bolt", label: "Lightning", keywords: "power energy fast"),
        .init(symbol: "cloud", label: "Cloud", keywords: "hosting online"),
        .init(symbol: "server.rack", label: "Server", keywords: "backend infrastructure"),
        .init(symbol: "externaldrive", label: "Storage", keywords: "data files drive"),
        .init(symbol: "cylinder.split.1x2", label: "Database", keywords: "data records"),
        .init(symbol: "desktopcomputer", label: "Desktop", keywords: "computer mac"),
        .init(symbol: "laptopcomputer", label: "Laptop", keywords: "computer macbook"),
        .init(symbol: "iphone", label: "Phone", keywords: "mobile ios"),
        .init(symbol: "app", label: "App", keywords: "application software"),
        .init(symbol: "gearshape", label: "Settings", keywords: "tools automation")
    ]
}

@MainActor
private enum ConnectionIconImages {
    private final class CachedImage: NSObject {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private static let images: NSCache<NSData, CachedImage> = {
        let cache = NSCache<NSData, CachedImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    private static let symbols = NSCache<NSString, NSImage>()

    static func image(for data: Data) -> NSImage? {
        guard data.count <= ConnectionIconImport.maximumEncodedBytes else { return nil }
        let key = data as NSData
        if let cached = images.object(forKey: key) { return cached.image }
        let image = decode(data)
        images.setObject(CachedImage(image), forKey: key, cost: data.count + 128 * 128 * 4)
        return image
    }

    static func symbol(named name: String) -> NSImage {
        let key = name as NSString
        if let image = symbols.object(forKey: key) { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        symbols.setObject(image, forKey: key)
        symbols.countLimit = 128
        return image
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...128).contains(width.intValue), (1...128).contains(height.intValue),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
    }
}

/// Imports only a small, metadata-free first frame. No source path is persisted.
nonisolated enum ConnectionIconImport {
    static let maximumSourceBytes = 10 * 1_024 * 1_024
    static let maximumEncodedBytes = 128 * 1_024
    private static let maximumSourceSide = 16_384
    private static let maximumSourcePixels = 100_000_000

    @MainActor
    static func chooseImage(symbol: String, onSelect: @escaping @MainActor (String, Data?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try normalizedPNG(from: url)
                    }.value
                    onSelect(symbol, data)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t use image"
                    alert.informativeText = (error as? ImportError)?.localizedDescription ?? "This image couldn’t be read."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    static func normalizedPNG(from url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError.unreadable }
        guard let fileSize = values.fileSize, fileSize <= maximumSourceBytes else { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumSourceBytes else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw ImportError.unreadable }
        let sourceWidth = width.intValue
        let sourceHeight = height.intValue
        guard sourceWidth > 0, sourceHeight > 0,
              sourceWidth <= maximumSourceSide, sourceHeight <= maximumSourceSide,
              sourceWidth * sourceHeight <= maximumSourcePixels else { throw ImportError.tooManyPixels }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              (1...128).contains(thumbnail.width), (1...128).contains(thumbnail.height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                                      bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImportError.unreadable }
        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
        guard let cleanImage = context.makeImage() else { throw ImportError.unreadable }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw ImportError.unreadable }
        CGImageDestinationAddImage(destination, cleanImage, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= maximumEncodedBytes else { throw ImportError.unreadable }
        return encoded as Data
    }

    private enum ImportError: LocalizedError {
        case tooLarge, tooManyPixels, unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose an image smaller than 10 MB."
            case .tooManyPixels: "Choose a smaller image."
            case .unreadable: "This image couldn’t be read."
            }
        }
    }
}
