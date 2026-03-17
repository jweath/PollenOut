import Foundation

final class PollenCache {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultCacheFileURL()
    }

    func save(report: PollenReport) {
        do {
            let data = try encoder.encode(report)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("Failed to save cache: \(error)")
        }
    }

    func load() -> PollenReport? {
        if let data = try? Data(contentsOf: fileURL),
           let report = try? decoder.decode(PollenReport.self, from: data) {
            return report
        }

        return nil
    }

    private static func defaultCacheFileURL() -> URL {
        let fileName = "latest_pollen_report.json"
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.appGroupID) {
            return groupURL.appendingPathComponent(fileName)
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent(fileName)
    }
}
