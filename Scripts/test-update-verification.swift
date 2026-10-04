#!/usr/bin/env swift
// Regression checks for release-signature failures, using ephemeral keys only.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: xcrun swift Scripts/test-update-verification.swift /path/to/compiled-verifier\n", stderr)
    exit(1)
}
let verifier = URL(fileURLWithPath: CommandLine.arguments[1])
let root = FileManager.default.temporaryDirectory.appendingPathComponent("fennec-update-tests-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let app = root.appendingPathComponent("Fennec.app")
let contents = app.appendingPathComponent("Contents")
try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
let key = Curve25519.Signing.PrivateKey()
let archive = Data("Inert test archive; no application or executable.".utf8)
let archiveURL = root.appendingPathComponent("Fennec-1.1-4.zip")
let feedURL = root.appendingPathComponent("appcast.xml")
let infoURL = contents.appendingPathComponent("Info.plist")
let info: [String: Any] = [
    "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
    "CFBundleVersion": "4",
    "SUEnableAutomaticChecks": false,
    "SUAutomaticallyUpdate": false,
    "SUAllowsAutomaticUpdates": false,
    "SUEnableSystemProfiling": false,
    "SURequireSignedFeed": true,
    "SUVerifyUpdateBeforeExtraction": true
]
func writeInfo(_ values: [String: Any]) throws {
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: infoURL)
}
func content(build: String = "4", url: String = "https://example.com/Fennec-1.1-4.zip", length: Int? = nil) throws -> Data {
    let signature = try key.signature(for: archive).base64EncodedString()
    return Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>\(build)</sparkle:version><enclosure url="\(url)" length="\(length ?? archive.count)" sparkle:edSignature="\(signature)"/></item></channel></rss>
    """.utf8)
}
func signed(_ data: Data) throws -> Data {
    let signature = try key.signature(for: data).base64EncodedString()
    return data + Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(data.count)\n-->\n".utf8)
}
let validContent = try content()
let validFeed = try signed(validContent)
var checks = 0
func check(_ name: String, accepts: Bool, feed: Data? = nil, archiveBytes: Data? = nil, values: [String: Any]? = nil) throws {
    try (feed ?? validFeed).write(to: feedURL)
    try (archiveBytes ?? archive).write(to: archiveURL)
    try writeInfo(values ?? info)
    let process = Process()
    process.executableURL = verifier
    process.arguments = [app.path, feedURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard (process.terminationStatus == 0) == accepts else {
        fputs("FAILED: \(name)\n", stderr)
        exit(1)
    }
    checks += 1
    print("Passed: \(name)")
}
try check("valid signed feed and archive", accepts: true)
try check("unsigned feed despite signed enclosure", accepts: false, feed: validContent)
var tamperedFeed = validFeed
tamperedFeed[1] ^= 1
try check("tampered feed", accepts: false, feed: tamperedFeed)
var tamperedArchive = archive
tamperedArchive[0] ^= 1
try check("tampered archive with unchanged byte length", accepts: false, archiveBytes: tamperedArchive)
try check("truncated archive", accepts: false, archiveBytes: archive.dropLast())
var wrongKeyInfo = info
wrongKeyInfo["SUPublicEDKey"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
try check("signature from a different key", accepts: false, values: wrongKeyInfo)
try check("signed feed with wrong archive length", accepts: false, feed: try signed(content(length: archive.count + 1)))
try check("signed feed missing the exported build", accepts: false, feed: try signed(content(build: "3")))
try check("signed feed with insecure download URL", accepts: false, feed: try signed(content(url: "http://example.com/Fennec-1.1-4.zip")))
try check("unterminated signature block", accepts: false, feed: Data(validFeed.dropLast(4)))
try check("unsigned content after signature", accepts: false, feed: validFeed + Data("<rss/>".utf8))
for flag in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling"] {
    var modifiedInfo = info
    modifiedInfo[flag] = true
    try check("reject \(flag)", accepts: false, values: modifiedInfo)
}
for flag in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
    var modifiedInfo = info
    modifiedInfo[flag] = false
    try check("require \(flag)", accepts: false, values: modifiedInfo)
}
print("\(checks) update verification checks passed. No app was launched or installed.")
