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

    private let fileName = "latest_pollen_report.json"

    func save(report: PollenReport) {
        do {
            let data = try encoder.encode(report)
            try data.write(to: cacheFileURL(), options: [.atomic])
            UserDefaults(suiteName: SharedConfig.appGroupID)?.set(data, forKey: SharedConfig.widgetDefaultsKey)
        } catch {
            print("Failed to save cache: \(error)")
        }
    }

    func load() -> PollenReport? {
        if let data = try? Data(contentsOf: cacheFileURL()),
           let report = try? decoder.decode(PollenReport.self, from: data) {
            return report
        }

        if let data = UserDefaults(suiteName: SharedConfig.appGroupID)?.data(forKey: SharedConfig.widgetDefaultsKey),
           let report = try? decoder.decode(PollenReport.self, from: data) {
            return report
        }

        return nil
    }

    private func cacheFileURL() -> URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.appGroupID) {
            return groupURL.appendingPathComponent(fileName)
        }

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent(fileName)
    }
}
