import Foundation

struct ActivityRecord: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case monitorStarted
        case monitorError
        case signal
        case detection
        case repairRequested
        case repairSucceeded
        case repairFailed
        case repairSkipped
        case deviceChanged
        case serviceRestarted
        case suppressed
        case helper
    }

    let id: UUID
    let date: Date
    let kind: Kind
    let summary: String
    let details: [String: String]

    init(kind: Kind, summary: String, details: [String: String] = [:], date: Date = Date()) {
        id = UUID()
        self.date = date
        self.kind = kind
        self.summary = summary
        self.details = details
    }
}

final class EventLogger: @unchecked Sendable {
    let logURL: URL
    private let rotatedLogURL: URL
    private let queue = DispatchQueue(label: "com.ludicrousdesigns.Fennec.event-log")
    private let encoder: JSONEncoder
    private let maximumLogSize: UInt64

    /// The directory Fennec keeps its user-visible files in. Shared with
    /// `RepairHistoryStore` so everything a user might inspect sits together.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = baseURL.appendingPathComponent(AppConstants.supportDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    init(
        directory: URL? = nil,
        maximumLogSize: UInt64 = 5 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        let directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent(AppConstants.eventLogFileName)
        rotatedLogURL = directory.appendingPathComponent("events.previous.jsonl")
        self.maximumLogSize = maximumLogSize

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    /// Runs `completion` once every queued append has hit the disk. Only the
    /// tests need this; the app never waits on its own audit log.
    func flush(completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    func append(_ record: ActivityRecord) {
        queue.async { [encoder, logURL, rotatedLogURL, maximumLogSize] in
            do {
                var data = try encoder.encode(record)
                data.append(0x0A)

                let fileManager = FileManager.default
                if let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
                   let size = attributes[.size] as? NSNumber,
                   size.uint64Value >= maximumLogSize {
                    try? fileManager.removeItem(at: rotatedLogURL)
                    try fileManager.moveItem(at: logURL, to: rotatedLogURL)
                }

                if !fileManager.fileExists(atPath: logURL.path) {
                    try data.write(to: logURL, options: .atomic)
                    return
                }

                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                NSLog("Fennec could not append its event log: %@", error.localizedDescription)
            }
        }
    }
}
