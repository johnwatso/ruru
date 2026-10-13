import AppKit
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
}
