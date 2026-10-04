#!/usr/bin/env swift
// Verify the feed and every local enclosure against the shipped public key.
// No private key or Keychain access is needed.
import CryptoKit
import Foundation

struct VerificationError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationError(description: message) }
}

func verify(app: URL, feedURL: URL) throws {
    let infoData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let encodedKey = info["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: encodedKey),
          let appBuild = info["CFBundleVersion"] as? String else {
        throw VerificationError(description: "Missing update key or build number in the app.")
    }
    for flag in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling"] {
        try require(info[flag] as? Bool == false, "\(flag) must be explicitly disabled.")
    }
    for flag in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
        try require(info[flag] as? Bool == true, "\(flag) must be enabled.")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let feed = try Data(contentsOf: feedURL)
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feed.range(of: marker, options: .backwards),
          let end = feed.range(of: Data("-->".utf8), in: range.upperBound..<feed.count),
          let block = String(data: feed.subdata(in: range.upperBound..<end.lowerBound), encoding: .utf8) else {
        throw VerificationError(description: "The feed has no embedded signature.")
    }
    let content = feed.subdata(in: 0..<range.lowerBound)
    let fields = block.components(separatedBy: "\n")
    func value(_ name: String) -> String? {
        fields.last { $0.hasPrefix(name + ":") }?
            .dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
    }
    let tail = feed.subdata(in: end.upperBound..<feed.count)
    try require(String(data: tail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                "Unexpected content after the feed signature.")
    try require(value("length").flatMap(Int.init) == content.count, "Feed byte length mismatch.")
    guard let signatureText = value("edSignature"), let signature = Data(base64Encoded: signatureText) else {
        throw VerificationError(description: "Malformed feed signature.")
    }
    try require(key.isValidSignature(signature, for: content), "Feed signature does not match the app's public key.")

    let xml = try XMLDocument(data: content, options: [.nodeLoadExternalEntitiesNever])
    let items = try xml.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }
    try require(!items.isEmpty, "The feed has no update entries.")
    var containsCurrentBuild = false
    var archiveCount = 0
    for item in items {
        if item.elements(forName: "sparkle:version").first?.stringValue == appBuild {
            containsCurrentBuild = true
        }
        let enclosures = try item.nodes(forXPath: ".//enclosure").compactMap { $0 as? XMLElement }
        try require(!enclosures.isEmpty, "An update entry has no archive.")
        for enclosure in enclosures {
            guard let urlText = enclosure.attribute(forName: "url")?.stringValue,
                  let url = URL(string: urlText), url.scheme == "https", url.host != nil,
                  let encodedSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
                  let archiveSignature = Data(base64Encoded: encodedSignature),
                  let lengthText = enclosure.attribute(forName: "length")?.stringValue,
                  let length = Int(lengthText) else {
                throw VerificationError(description: "An enclosure needs an HTTPS URL, signature, and length.")
            }
            let filename = url.lastPathComponent
            try require(!filename.isEmpty && filename != "." && filename != "..", "Invalid archive filename.")
            let archiveURL = feedURL.deletingLastPathComponent().appendingPathComponent(filename)
            let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            try require(archive.count == length, "Archive length mismatch: \(filename)")
            try require(key.isValidSignature(archiveSignature, for: archive), "Invalid archive signature: \(filename)")
            archiveCount += 1
        }
    }
    try require(containsCurrentBuild, "The feed does not include the app's build \(appBuild).")
    print("Verified signed feed and \(archiveCount) archive(s) against the shipped app key; build \(appBuild) is present.")
}

do {
    try require(CommandLine.arguments.count == 3, "Usage: xcrun swift Scripts/verify-updates.swift /path/Fennec.app /path/appcast.xml")
    try verify(app: URL(fileURLWithPath: CommandLine.arguments[1]), feedURL: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    fputs("Update verification failed: \(error)\n", stderr)
    exit(1)
}
