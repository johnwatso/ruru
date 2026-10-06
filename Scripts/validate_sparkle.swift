#!/usr/bin/env swift
import Foundation

// Read-only preflight. ShipHook owns archive signing and publication.
let arguments = Array(CommandLine.arguments.dropFirst())
let allowUnconfigured = arguments.contains("--allow-unconfigured")
guard let appPath = arguments.first(where: { !$0.hasPrefix("--") }) else {
    fputs("Usage: swift Scripts/validate_sparkle.swift /path/Ruru.app [--allow-unconfigured]\n", stderr)
    exit(2)
}
var failures: [String] = []
func require(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}
let appURL = URL(fileURLWithPath: appPath)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

final class FeedValidator: NSObject, XMLParserDelegate {
    var failures: [String] = []
    var itemCount = 0
    private var inItem = false
    private var hasEnclosure = false
    private var build = ""
    private var element = ""
    private var hasChannel = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "channel" { hasChannel = true }
        if name == "item" { inItem = true; hasEnclosure = false; build = ""; itemCount += 1 }
        guard inItem, name == "enclosure" else { return }
        hasEnclosure = true
        let signature = attributes["sparkle:edSignature"] ?? ""
        if Data(base64Encoded: signature)?.count != 64 { failures.append("Item \(itemCount) has no valid-length Ed25519 signature.") }
        if Int64(attributes["length"] ?? "") ?? 0 <= 0 { failures.append("Item \(itemCount) has no positive archive length.") }
        if let url = URL(string: attributes["url"] ?? ""), url.scheme == "https",
           url.host != nil, url.user == nil, url.password == nil { }
        else { failures.append("Item \(itemCount) must use an HTTPS archive URL without embedded credentials.") }
        if let version = attributes["sparkle:version"] { build = version }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem && element == "sparkle:version" { build += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" {
            if !hasEnclosure { failures.append("Item \(itemCount) has no archive enclosure.") }
            if build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failures.append("Item \(itemCount) has no build version.") }
            inItem = false
        }
        element = ""
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if !hasChannel { failures.append("Missing RSS channel.") }
    }
}

do {
    let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    require(info["SUFeedURL"] as? String == "https://johnwatso.github.io/ruru/appcast.xml", "Built SUFeedURL does not match Ruru's stable feed.")
    let key = info["SUPublicEDKey"] as? String ?? ""
    if key.isEmpty && allowUnconfigured {
        print("ShipHook public key pending; this development build disables updates.")
    } else {
        require(Data(base64Encoded: key)?.count == 32, "ShipHook's 32-byte Ed25519 public key must be embedded before publishing.")
    }
    require(info["SUEnableAutomaticChecks"] as? Bool == true, "Background checks must default on.")
    require(info["SUAutomaticallyUpdate"] as? Bool == false, "Automatic downloads must default off.")
    let yaml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
    for (setting, plistKey) in [("MARKETING_VERSION", "CFBundleShortVersionString"), ("CURRENT_PROJECT_VERSION", "CFBundleVersion")] {
        let expression = try NSRegularExpression(pattern: "(?m)^\\s*" + setting + ": \\\"([^\\\"]+)\\\"")
        let range = NSRange(yaml.startIndex..., in: yaml)
        if let match = expression.firstMatch(in: yaml, range: range), let valueRange = Range(match.range(at: 1), in: yaml) {
            require(info[plistKey] as? String == String(yaml[valueRange]), "Built \(plistKey) differs from project.yml.")
        } else { failures.append("Missing \(setting) in project.yml.") }
    }
    require(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Sparkle").path), "Sparkle framework is not embedded.")
    for path in ["docs/appcast.xml", "docs/beta/appcast.xml"] {
        let parser = XMLParser(data: try Data(contentsOf: root.appendingPathComponent(path)))
        let validator = FeedValidator()
        parser.delegate = validator
        parser.shouldResolveExternalEntities = false
        require(parser.parse(), "\(path) is invalid XML.")
        failures += validator.failures.map { "\(path): \($0)" }
        print("\(path): \(validator.itemCount) published items.")
    }
} catch { failures.append(error.localizedDescription) }

if failures.isEmpty {
    print("Sparkle configuration preflight passed. Archive signatures, live feeds and installation still require release validation.")
} else {
    failures.forEach { fputs("Error: \($0)\n", stderr) }
    exit(1)
}
