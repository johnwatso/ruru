import AppKit
import Foundation
import XCTest

final class ServiceIconTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ruru-icons-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sampleImage(width: CGFloat, height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    func testNormalizesToSquarePNG() throws {
        let data = try RuruServiceIcons.normalizedPNG(from: sampleImage(width: 600, height: 300))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, RuruServiceIcons.pixels)
        XCTAssertEqual(bitmap.pixelsHigh, RuruServiceIcons.pixels)
        // Letterboxed: top-left corner stays transparent, centre is painted.
        XCTAssertEqual(bitmap.colorAt(x: 2, y: 2)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertGreaterThan(bitmap.colorAt(x: 128, y: 128)?.alphaComponent ?? 0, 0.99)
    }

    func testSaveLoadRemoveAndRejectsUnsafeIDs() throws {
        let base = try temporaryDirectory()
        let png = try RuruServiceIcons.normalizedPNG(from: sampleImage(width: 64, height: 64))
        let id = UUID().uuidString.lowercased()
        try RuruServiceIcons.save(png, serviceID: id, in: base)
        XCTAssertNotNil(RuruServiceIcons.load(serviceID: id, in: base))
        RuruServiceIcons.remove(serviceID: id, in: base)
        XCTAssertNil(RuruServiceIcons.load(serviceID: id, in: base))
        XCTAssertThrowsError(try RuruServiceIcons.save(png, serviceID: "../escape", in: base))
        XCTAssertNil(RuruServiceIcons.load(serviceID: "../escape", in: base))
    }

    func testPickRejectsNonImagesAndReadsImages() throws {
        let base = try temporaryDirectory()
        let text = base.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RuruServiceIcons.pick(from: text))

        let png = base.appendingPathComponent("logo.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try RuruServiceIcons.normalizedPNG(from: sampleImage(width: 40, height: 40))))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        let pick = try RuruServiceIcons.pick(from: png)
        XCTAssertNil(pick.suggestedName)
        XCTAssertNotNil(NSImage(data: pick.png))
    }

    func testPickReadsAppBundleIconAndName() throws {
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: app.path))
        let pick = try RuruServiceIcons.pick(from: app)
        XCTAssertEqual(pick.suggestedName, "Calculator")
        XCTAssertNotNil(NSImage(data: pick.png))
    }

    func testWebsiteIconFetchUsesSameOriginFaviconAndNormalizesIt() async throws {
        let favicon = try RuruServiceIcons.normalizedPNG(from: sampleImage(width: 48, height: 48))
        WebsiteIconProtocol.install(status: 200, body: favicon)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebsiteIconProtocol.self]
        let icon = try await RuruServiceIcons.fetchWebsiteIcon(
            for: URL(string: "https://example.com/status/health")!,
            session: URLSession(configuration: configuration)
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: icon))
        XCTAssertEqual(bitmap.pixelsWide, RuruServiceIcons.pixels)
        XCTAssertEqual(bitmap.pixelsHigh, RuruServiceIcons.pixels)
        XCTAssertEqual(WebsiteIconProtocol.lastRequest?.url?.absoluteString, "https://example.com/favicon.ico")
    }

    func testWebsiteIconFetchRejectsOverLimitResponse() async {
        WebsiteIconProtocol.install(status: 200, body: Data(), contentLength: RuruServiceIcons.maxWebsiteIconBytes + 1)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebsiteIconProtocol.self]
        do {
            _ = try await RuruServiceIcons.fetchWebsiteIcon(
                for: URL(string: "https://example.com")!, session: URLSession(configuration: configuration)
            )
            XCTFail("Expected an oversized favicon to be rejected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That website’s favicon could not be downloaded.")
        }
    }
}

private final class WebsiteIconProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply: (status: Int, body: Data, contentLength: Int)?
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    static var lastRequest: URLRequest? { lock.withLock { capturedRequest } }

    static func install(status: Int, body: Data, contentLength: Int? = nil) {
        lock.withLock {
            reply = (status, body, contentLength ?? body.count)
            capturedRequest = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock { Self.capturedRequest = request; return Self.reply }
        guard let reply, let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png", "Content-Length": "\(reply.contentLength)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
