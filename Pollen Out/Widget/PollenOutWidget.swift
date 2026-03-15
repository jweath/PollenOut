import WidgetKit
import SwiftUI

struct PollenWidgetEntry: TimelineEntry {
    let date: Date
    let overallCount: Int
}

struct PollenWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PollenWidgetEntry {
        PollenWidgetEntry(date: Date(), overallCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (PollenWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PollenWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> PollenWidgetEntry {
        let defaults = UserDefaults(suiteName: SharedConfig.appGroupID)
        guard let data = defaults?.data(forKey: SharedConfig.widgetDefaultsKey) else {
            return PollenWidgetEntry(date: Date(), overallCount: 0)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let report = try? decoder.decode(PollenReport.self, from: data) {
            return PollenWidgetEntry(date: report.date, overallCount: report.overallCount)
        }

        return PollenWidgetEntry(date: Date(), overallCount: 0)
    }
}

struct PollenOutWidgetEntryView: View {
    var entry: PollenWidgetProvider.Entry

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.1, green: 0.18, blue: 0.12), Color(red: 0.45, green: 0.05, blue: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 6) {
                Text("\(entry.overallCount)")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)

                Text("Pollen Out")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pollen Out. Overall pollen count \(entry.overallCount)")
    }
}

struct PollenOutWidget: Widget {
    let kind: String = "PollenOutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PollenWidgetProvider()) { entry in
            PollenOutWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pollen Out")
        .description("Shows the latest overall pollen count.")
        .supportedFamilies([.systemSmall])
    }
}
