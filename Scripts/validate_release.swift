#!/usr/bin/env swift
import Foundation

// Read-only local artifact validation. ShipHook owns signing and publication.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    fputs("Usage: swift Scripts/validate_release.swift /path/Ruru.app [--allow-unconfigured]\n", stderr)
    exit(2)
}
let app = URL(fileURLWithPath: path).standardizedFileURL
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var failures: [String] = []

func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func isMachO(_ url: URL) throws -> Bool {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let magic = Array(try file.read(upToCount: 4) ?? Data())
    return [[0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xfe, 0xed, 0xfa, 0xce],
            [0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf],
            [0xbe, 0xba, 0xfe, 0xca], [0xbf, 0xba, 0xfe, 0xca]].contains(magic.map(Int.init))
}

/// Checks non-system install names against the bundle, including framework runpaths.
/// This is a packaging check, not a substitute for launching the packaged app.
func verifyLinkedLibraries(_ binary: URL, relative: String, architecture: String) throws {
    let linked = try run("/usr/bin/otool", ["-arch", architecture, "-L", binary.path])
    let commands = try run("/usr/bin/otool", ["-arch", architecture, "-l", binary.path])
    guard linked.status == 0, commands.status == 0 else {
        failures.append("\(relative) [\(architecture)]: cannot inspect linked libraries")
        return
    }
    let loader = binary.deletingLastPathComponent()
    var executables = [app.appendingPathComponent("Contents/MacOS"), loader]
    var ancestor = loader
    while ancestor.path.count > app.path.count {
        if ancestor.lastPathComponent == "Contents",
           ["app", "xpc"].contains(ancestor.deletingLastPathComponent().pathExtension) {
            executables.append(ancestor.appendingPathComponent("MacOS"))
        }
        ancestor.deleteLastPathComponent()
    }
    func expand(_ path: String) -> [URL] {
        if path.hasPrefix("@loader_path/") { return [loader.appendingPathComponent(String(path.dropFirst(13)))] }
        if path.hasPrefix("@executable_path/") { return executables.map { $0.appendingPathComponent(String(path.dropFirst(17))) } }
        if path == "@loader_path" { return [loader] }
        if path == "@executable_path" { return executables }
        return path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : []
    }
    var runpaths = [app.appendingPathComponent("Contents/Frameworks")]
    let expression = try NSRegularExpression(pattern: "(?s)cmd LC_RPATH\\s+cmdsize \\d+\\s+path (.*?) \\(offset ")
    for match in expression.matches(in: commands.output, range: NSRange(commands.output.startIndex..., in: commands.output)) {
        if let range = Range(match.range(at: 1), in: commands.output) { runpaths += expand(String(commands.output[range])) }
    }
    for line in linked.output.split(separator: "\n").dropFirst() {
        guard let marker = line.range(of: " (compatibility version") else { continue }
        let name = String(line[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/System/Library/") || name.hasPrefix("/usr/lib/") { continue }
        let candidates = name.hasPrefix("@rpath/")
            ? runpaths.map { $0.appendingPathComponent(String(name.dropFirst(7))) } : expand(name)
        let contained = candidates.contains { candidate in
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved.hasPrefix(app.resolvingSymlinksInPath().path + "/")
                && FileManager.default.fileExists(atPath: resolved)
        }
        if !contained { failures.append("\(relative) [\(architecture)]: linked library is not bundled: \(name)") }
    }
}

do {
    let required = ["Contents/MacOS/Ruru", "Contents/Frameworks/WitnessKit.framework/WitnessKit",
                    "Contents/Frameworks/RuruAlerting.framework/RuruAlerting",
                    "Contents/Frameworks/Sparkle.framework/Sparkle", "Contents/Resources/cloudflared"]
    for relative in required {
        let file = app.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: file.path) {
            failures.append("Missing required binary: \(relative)")
        } else if try !isMachO(file) {
            failures.append("Required binary is not Mach-O: \(relative)")
        }
    }
    guard let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [], errorHandler: { url, error in
        failures.append("Cannot inspect \(url.lastPathComponent): \(error.localizedDescription)")
        return true
    }) else { throw CocoaError(.fileReadNoSuchFile) }
    var checked: Set<String> = []
    for case let file as URL in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try isMachO(file) else { continue }
        let resolved = file.resolvingSymlinksInPath().path
        guard checked.insert(resolved).inserted else { continue }
        let relative = String(file.path.dropFirst(app.path.count + 1))
        let architectures = try run("/usr/bin/lipo", ["-archs", resolved])
        let slices = Set(architectures.output.split(whereSeparator: \.isWhitespace).map(String.init))
        guard architectures.status == 0, slices.isSuperset(of: ["x86_64", "arm64"]) else {
            failures.append("\(relative): missing Intel or Apple silicon slice")
            continue
        }
        for architecture in ["x86_64", "arm64"] {
            try verifyLinkedLibraries(file, relative: relative, architecture: architecture)
            let build = try run("/usr/bin/xcrun", ["vtool", "-arch", architecture, "-show-build", resolved])
            let modern = try NSRegularExpression(pattern: "(?m)^\\s*minos\\s+([0-9.]+)\\s*$")
            let legacy = try NSRegularExpression(pattern: "(?s)LC_VERSION_MIN_MACOSX\\s+cmdsize\\s+\\d+\\s+version\\s+([0-9.]+)")
            let range = NSRange(build.output.startIndex..., in: build.output)
            let match = modern.firstMatch(in: build.output, range: range) ?? legacy.firstMatch(in: build.output, range: range)
            guard build.status == 0, let match, let value = Range(match.range(at: 1), in: build.output),
                  build.output.contains("platform MACOS") || build.output.contains("LC_VERSION_MIN_MACOSX") else {
                failures.append("\(relative) [\(architecture)]: cannot establish macOS deployment target")
                continue
            }
            let minimum = String(build.output[value])
            if minimum.compare("15.0", options: .numeric) == .orderedDescending {
                failures.append("\(relative) [\(architecture)]: requires macOS \(minimum), above Sequoia")
            }
        }
        print("Universal: \(relative)")
    }
    if checked.isEmpty { failures.append("No Mach-O binaries found in app bundle") }
    var sparkleArguments = [root.appendingPathComponent("Scripts/validate_sparkle.swift").path, app.path]
    if arguments.contains("--allow-unconfigured") { sparkleArguments.append("--allow-unconfigured") }
    let sparkle = try run("/usr/bin/swift", sparkleArguments)
    print(sparkle.output, terminator: "")
    if sparkle.status != 0 { failures.append("Sparkle release preflight failed") }
} catch {
    failures.append(error.localizedDescription)
}

if failures.isEmpty {
    print("Release artifact checks passed. Physical Intel execution, ShipHook distribution signing, notarisation and update installation require separate validation.")
} else {
    failures.forEach { fputs("Error: \($0)\n", stderr) }
    exit(1)
}
