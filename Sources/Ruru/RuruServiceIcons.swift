import AppKit
import Foundation
import UniformTypeIdentifiers

/// Display-only icons for guarded services. They live beside, not inside,
/// `configuration.json` as 256 px PNGs named by service ID, so they never affect
/// configuration validity, ownership, or the lease protocol.
enum RuruServiceIcons {
    static let pixels = 256
    static let maxSourceBytes = 20_000_000
    /// A downloaded favicon is intentionally much smaller than a user-chosen
    /// local image. It is display-only and must not turn saving a monitor into
    /// an unbounded network or memory operation.
    static let maxWebsiteIconBytes = 2 * 1024 * 1024
    static let maxWebsiteIconPixels = 4_194_304

    struct Pick {
        let png: Data
        /// The app's display name when the source was an `.app` bundle.
        let suggestedName: String?
    }

    enum IconError: LocalizedError {
        case unreadable, tooLarge, notAnImage, websiteUnavailable
        var errorDescription: String? {
            switch self {
            case .unreadable: "That file could not be read."
            case .tooLarge: "That image is too large. Choose one under 20 MB."
            case .notAnImage: "Choose an app (.app) or an image such as PNG, JPEG or HEIC."
            case .websiteUnavailable: "That website’s favicon could not be downloaded."
            }
        }
    }

    static func directory(in base: URL = WitnessStorage.directory) -> URL {
        base.appendingPathComponent("ServiceIcons", isDirectory: true)
    }

    // MARK: Reading a dropped or chosen file

    static func pick(from url: URL) throws -> Pick {
        guard url.isFileURL else { throw IconError.unreadable }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .fileSizeKey])
        let type = values?.contentType
        if type?.conforms(to: .applicationBundle) == true || url.pathExtension.lowercased() == "app" {
            // The Finder icon, so apps with Icon Composer or asset-catalog icons render correctly.
            let image = NSWorkspace.shared.icon(forFile: url.path)
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return Pick(png: try normalizedPNG(from: image), suggestedName: name)
        }
        guard type?.conforms(to: .image) == true else { throw IconError.notAnImage }
        if let size = values?.fileSize, size > maxSourceBytes { throw IconError.tooLarge }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw IconError.unreadable
        }
        return Pick(png: try normalizedPNG(from: image), suggestedName: nil)
    }

    /// Aspect-fit into a transparent square so every stored icon is the same shape and size.
    static func normalizedPNG(from image: NSImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconError.unreadable }
        let scale = min(CGFloat(pixels) / image.size.width, CGFloat(pixels) / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                          width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconError.unreadable }
        return data
    }

    // MARK: Website favicons

    /// Fetches only the conventional same-origin `/favicon.ico` location. This
    /// deliberately avoids following redirects or parsing arbitrary page HTML.
    /// The result is normalised before it ever reaches the icon store.
    static func fetchWebsiteIcon(for website: URL, session suppliedSession: URLSession? = nil) async throws -> Data {
        guard let faviconURL = sameOriginFaviconURL(for: website) else { throw IconError.websiteUnavailable }
        let ownsSession = suppliedSession == nil
        let session = suppliedSession ?? websiteIconSession()
        defer { if ownsSession { session.invalidateAndCancel() } }

        var request = URLRequest(url: faviconURL)
        request.timeoutInterval = 10
        request.setValue("Ruru", forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  response.url == faviconURL,
                  response.expectedContentLength <= Int64(maxWebsiteIconBytes) || response.expectedContentLength < 0 else {
                throw IconError.websiteUnavailable
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= maxWebsiteIconBytes else { throw IconError.tooLarge }
            }
            return try normalizedWebsiteIcon(data)
        } catch let error as IconError {
            throw error
        } catch {
            throw IconError.websiteUnavailable
        }
    }

    private static func sameOriginFaviconURL(for website: URL) -> URL? {
        guard let scheme = website.scheme?.lowercased(), ["http", "https"].contains(scheme),
              website.host != nil, website.user == nil, website.password == nil else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = website.host
        parts.port = website.port
        parts.path = "/favicon.ico"
        return parts.url
    }

    private static func websiteIconSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static func normalizedWebsiteIcon(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maxWebsiteIconBytes,
              let image = NSImage(data: data),
              let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              bitmap.pixelsWide <= 4_096, bitmap.pixelsHigh <= 4_096,
              bitmap.pixelsWide * bitmap.pixelsHigh <= maxWebsiteIconPixels else {
            throw IconError.notAnImage
        }
        return try normalizedPNG(from: image)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    // MARK: Storage

    private static func url(for serviceID: String, in base: URL) -> URL? {
        // Service IDs are generated UUIDs; refuse anything that could escape the folder.
        guard !serviceID.isEmpty, serviceID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return directory(in: base).appendingPathComponent(serviceID + ".png")
    }

    static func save(_ png: Data, serviceID: String, in base: URL = WitnessStorage.directory) throws {
        guard let file = url(for: serviceID, in: base) else { throw IconError.unreadable }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try png.write(to: file, options: .atomic)
    }

    static func load(serviceID: String, in base: URL = WitnessStorage.directory) -> NSImage? {
        guard let file = url(for: serviceID, in: base), let data = try? Data(contentsOf: file) else { return nil }
        return NSImage(data: data)
    }

    static func remove(serviceID: String, in base: URL = WitnessStorage.directory) {
        guard let file = url(for: serviceID, in: base) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
