#!/bin/bash
# Check plugin reuse, duplicate rejection, and failed-load caching without cores.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cassowary-plugin-cache.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

cat > "$CHECK_DIR/main.swift" <<'SWIFT'
import Foundation

final class TestPlugin: OEPlugin {
    override class var pluginExtension: String { "oecoreplugin" }
    override class var pluginFolder: String { "unused" }
    static var attempts = 0
    required init(bundleAtURL url: URL, name: String?) throws {
        Self.attempts += 1
        try super.init(bundleAtURL: url, name: name)
    }
}
final class OtherPlugin: OEPlugin {
    override class var pluginExtension: String { "oecoreplugin" }
    override class var pluginFolder: String { "unused" }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
func bundle(_ name: String, identifier: Any?) throws -> URL {
    let url = directory.appendingPathComponent(name + ".oecoreplugin")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleName": name, "CFBundleVersion": "1"]
    info["CFBundleIdentifier"] = identifier
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: url.appendingPathComponent("Info.plist"))
    return url
}
func expect(_ error: OEGameCorePluginError, _ action: () throws -> Void) {
    do {
        try action()
        preconditionFailure("Expected \(error)")
    } catch let actual as OEGameCorePluginError {
        precondition(actual == error)
    } catch {
        preconditionFailure("Unexpected error: \(error)")
    }
}

let valid = try bundle("Valid", identifier: "org.cassowary.check.valid")
let first = try TestPlugin.plugin(bundleAtURL: valid)!
let again = try TestPlugin.plugin(bundleAtURL: valid)
precondition(first === again && TestPlugin.attempts == 1)
expect(.alreadyLoaded) { _ = try TestPlugin(bundleAtURL: valid, name: "Alias") }
let otherPath = try bundle("OtherPath", identifier: "org.cassowary.check.other")
expect(.alreadyLoaded) { _ = try TestPlugin(bundleAtURL: otherPath, name: "Valid") }
let otherType = try OtherPlugin.plugin(bundleAtURL: valid)
precondition(otherType != nil && first !== otherType)

for (name, identifier) in [("MissingID", nil), ("InvalidID", 7 as Any?)] {
    let invalid = try bundle(name, identifier: identifier)
    expect(.invalid) { _ = try TestPlugin.plugin(bundleAtURL: invalid) }
    let attempts = TestPlugin.attempts
    let cachedFailure = try TestPlugin.plugin(bundleAtURL: invalid)
    precondition(cachedFailure == nil && TestPlugin.attempts == attempts)
    precondition(FileManager.default.fileExists(atPath: invalid.path))
}
TestPlugin.registerClass()
precondition(TestPlugin.plugins().count == 1)
print("Plugin cache check passed")
SWIFT

xcrun swiftc "$REPO_ROOT/OpenEmuKit/Source/OEPlugin.swift" "$CHECK_DIR/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check" "$CHECK_DIR"
