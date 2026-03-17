import Foundation
import SwiftUI

enum PollenSeverity: String, Codable, CaseIterable {
    case absent
    case low
    case moderate
    case high
    case veryHigh
    case unknown

    init(from text: String) {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("very high") || normalized.contains("extremely high") {
            self = .veryHigh
        } else if normalized.contains("high") {
            self = .high
        } else if normalized.contains("moderate") || normalized.contains("medium") {
            self = .moderate
        } else if normalized.contains("low") {
            self = .low
        } else if normalized.contains("absent") || normalized.contains("none") || normalized.contains("zero") {
            self = .absent
        } else {
            self = .unknown
        }
    }

    var numericFallback: Double {
        switch self {
        case .absent: return 0
        case .low: return 25
        case .moderate: return 50
        case .high: return 75
        case .veryHigh: return 100
        case .unknown: return 35
        }
    }

    var displayText: String {
        switch self {
        case .absent: return "Absent"
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .veryHigh: return "Very High"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .absent: return .green
        case .low: return .mint
        case .moderate: return .yellow
        case .high: return .orange
        case .veryHigh: return .red
        case .unknown: return .gray
        }
    }
}

struct PollenCategory: Codable, Identifiable, Hashable {
    let name: String
    let severity: PollenSeverity
    let numericValue: Double?
    let normalizedValue: Double?

    var id: String { name }

    var barValue: Double {
        if let normalizedValue {
            return min(max(normalizedValue, 0), 100)
        }
        if let numericValue {
            return min(max(numericValue, 0), 100)
        }
        return severity.numericFallback
    }

    var accessibilitySummary: String {
        if let numericValue {
            return "\(name), \(severity.displayText), value \(Int(numericValue))"
        }
        return "\(name), \(severity.displayText)"
    }
}

struct DailyPollenPoint: Codable, Identifiable, Hashable {
    let date: Date
    let count: Int

    var id: String { "\(date.timeIntervalSince1970)-\(count)" }
}

struct PollenReport: Codable, Hashable {
    let date: Date
    let sourceURL: URL
    let overallCount: Int
    let categories: [PollenCategory]
    let treeTopContributors: [String]
    let weedTopContributors: [String]
    let moldActivity: String
    let recentTrend: [DailyPollenPoint]

    var severityGradient: LinearGradient {
        let start: Color
        let end: Color
        switch overallCount {
        case ..<100:
            start = .green
            end = .mint
        case 100..<300:
            start = .yellow
            end = .orange
        case 300..<700:
            start = .orange
            end = .red
        default:
            start = .red
            end = .pink
        }
        return LinearGradient(colors: [start, end], startPoint: .leading, endPoint: .trailing)
    }
}
