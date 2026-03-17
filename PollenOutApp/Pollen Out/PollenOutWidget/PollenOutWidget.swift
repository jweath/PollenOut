import WidgetKit
import SwiftUI

private enum WidgetSharedConfig {
    static let appGroupID = "group.doubleux.pollenout.shared"
    static let sharedCacheFileName = "latest_pollen_report.json"
}

private struct WidgetCachedReport: Codable {
    let date: Date
    let overallCount: Int
}

struct PollenWidgetEntry: TimelineEntry {
    let date: Date
    let overallCount: Int
    let reportDate: Date
}

struct PollenWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PollenWidgetEntry {
        PollenWidgetEntry(date: Date(), overallCount: 0, reportDate: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (PollenWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PollenWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let refresh = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func loadEntry() -> PollenWidgetEntry {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSharedConfig.appGroupID) else {
            return PollenWidgetEntry(date: Date(), overallCount: 0, reportDate: Date())
        }

        let fileURL = groupURL.appendingPathComponent(WidgetSharedConfig.sharedCacheFileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return PollenWidgetEntry(date: Date(), overallCount: 0, reportDate: Date())
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode(WidgetCachedReport.self, from: data) {
            return PollenWidgetEntry(date: Date(), overallCount: cached.overallCount, reportDate: cached.date)
        }

        return PollenWidgetEntry(date: Date(), overallCount: 0, reportDate: Date())
    }
}

struct PollenOutWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PollenWidgetProvider.Entry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text("\(entry.overallCount) \(shortRecencyLabel(for: entry.reportDate))")
            case .accessoryCircular:
                ZStack {
                    Circle()
                        .fill(severityGradient(for: entry.overallCount))
                    VStack(spacing: 1) {
                        Text("\(entry.overallCount)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.6)
                        Text(shortSeverityLabel(for: entry.overallCount))
                            .font(.system(size: 6, weight: .semibold, design: .default))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.overallCount)")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text(shortSeverityLabel(for: entry.overallCount))
                        .font(.caption2.weight(.semibold))
                    Text(shortRecencyLabel(for: entry.reportDate))
                        .font(.caption2.weight(.semibold))
                }
            default:
                VStack(spacing: 4) {
                    Text("\(entry.overallCount)")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)

                    Text(recencyLabel(for: entry.reportDate))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(8)
            }
        }
        .containerBackground(for: .widget) {
            switch family {
            case .systemSmall, .systemMedium:
                severityGradient(for: entry.overallCount)
            default:
                Color.clear
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pollen Out. Overall pollen count \(entry.overallCount). \(recencyLabel(for: entry.reportDate))")
    }

    private func recencyLabel(for reportDate: Date) -> String {
        let calendar = Calendar.current
        let md = Self.monthDayFormatter.string(from: reportDate)

        if calendar.isDateInToday(reportDate) {
            return "Today \(md)"
        }

        return "\(Self.fullWeekdayFormatter.string(from: reportDate)) \(md)"
    }

    private func shortRecencyLabel(for reportDate: Date) -> String {
        let calendar = Calendar.current
        let md = Self.monthDayFormatter.string(from: reportDate)
        if calendar.isDateInToday(reportDate) {
            return "Today \(md)"
        }
        return "\(Self.shortWeekdayFormatter.string(from: reportDate)) \(md)"
    }

    private func shortSeverityLabel(for count: Int) -> String {
        switch count {
        case ..<100:
            return "Low"
        case 100..<300:
            return "Med."
        case 300..<700:
            return "High"
        default:
            return "Ext."
        }
    }

    private func severityGradient(for count: Int) -> LinearGradient {
        let colors: [Color]
        switch count {
        case ..<100:
            colors = [.green, .mint]
        case 100..<300:
            colors = [.yellow, .orange]
        case 300..<700:
            colors = [.orange, .red]
        default:
            colors = [.red, .pink]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

private extension PollenOutWidgetEntryView {
    static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    static let fullWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    static let shortWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

struct PollenOutWidget: Widget {
    let kind = "PollenOutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PollenWidgetProvider()) { entry in
            PollenOutWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pollen Out")
        .description("Shows the latest overall pollen count.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
