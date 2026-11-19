import Foundation

enum ShareInbox {
    private static let group = "group.com.example.subscriptionTree"

    private static func directory() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let inbox = container.appendingPathComponent("SubscriptionInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    static func add(_ input: String) throws {
        let text = String(input.prefix(8000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        let destination = try directory().appendingPathComponent(UUID().uuidString + ".txt")
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    static func take() -> [String] {
        guard let inbox = try? directory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              ) else { return [] }
        return urls.filter { $0.pathExtension == "txt" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            do {
                try FileManager.default.removeItem(at: url)
                return text
            } catch {
                return nil
            }
        }
    }
}
