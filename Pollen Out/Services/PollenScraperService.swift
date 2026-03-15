import Foundation
import SwiftSoup

enum PollenServiceError: LocalizedError {
    case noReportsFound
    case failedToParseReport

    var errorDescription: String? {
        switch self {
        case .noReportsFound:
            return "No recent pollen report was found on the source website."
        case .failedToParseReport:
            return "Could not parse the latest pollen report."
        }
    }
}

protocol PollenReportProviding {
    func fetchLatestReport() async throws -> PollenReport
}

final class AtlantaAllergyPollenService: PollenReportProviding {
    private let session: URLSession
    private let baseURL = URL(string: "https://www.atlantaallergy.com/pollen_counts")!
    private let calendar = Calendar(identifier: .gregorian)

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatestReport() async throws -> PollenReport {
        let mainHTML = try await loadHTML(from: baseURL)
        let mainDocument = try SwiftSoup.parse(mainHTML)

        let candidateLinks = extractReportLinks(from: mainDocument, baseURL: baseURL)
        guard let latestURL = candidateLinks.first?.url ?? try await probeMostRecentURL() else {
            throw PollenServiceError.noReportsFound
        }

        let reportHTML = try await loadHTML(from: latestURL)
        let reportDocument = try SwiftSoup.parse(reportHTML)

        guard var report = parseReport(document: reportDocument, sourceURL: latestURL) else {
            throw PollenServiceError.failedToParseReport
        }

        let trend = try await fetchRecentTrend(primaryCandidates: candidateLinks, reportURL: latestURL)
        if !trend.isEmpty {
            report = PollenReport(
                date: report.date,
                sourceURL: report.sourceURL,
                overallCount: report.overallCount,
                categories: report.categories,
                treeTopContributors: report.treeTopContributors,
                weedTopContributors: report.weedTopContributors,
                moldActivity: report.moldActivity,
                recentTrend: trend
            )
        }

        return report
    }

    private func loadHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw URLError(.cannotDecodeRawData)
        }
        return html
    }

    private func parseReport(document: Document, sourceURL: URL) -> PollenReport? {
        let pageText = ((try? document.body()?.text()) ?? "").normalizedWhitespace()
        let lines = extractMeaningfulLines(document: document)

        let overallCount = parseOverallCount(from: pageText, lines: lines)
        guard let reportDate = parseDate(from: sourceURL), let overallCount else {
            return nil
        }

        let trees = parseCategory(named: "Trees", from: lines, pageText: pageText)
        let grass = parseCategory(named: "Grass", from: lines, pageText: pageText)
        let weeds = parseCategory(named: "Weeds", from: lines, pageText: pageText)
        let mold = parseCategory(named: "Mold", from: lines, pageText: pageText)

        let treeContributors = parseTopContributors(type: "tree", lines: lines, pageText: pageText)
        let weedContributors = parseTopContributors(type: "weed", lines: lines, pageText: pageText)
        let moldActivity = parseMoldActivity(lines: lines, pageText: pageText)

        return PollenReport(
            date: reportDate,
            sourceURL: sourceURL,
            overallCount: overallCount,
            categories: [trees, grass, weeds, mold],
            treeTopContributors: treeContributors,
            weedTopContributors: weedContributors,
            moldActivity: moldActivity,
            recentTrend: [DailyPollenPoint(date: reportDate, count: overallCount)]
        )
    }

    private func parseOverallCount(from pageText: String, lines: [String]) -> Int? {
        if let byLabel = parseFirstInteger(in: context(for: "total pollen count", in: lines, radius: 3)) {
            return byLabel
        }

        if let regexMatch = firstMatch(
            in: pageText,
            pattern: "total\\s+pollen\\s+count\\s*[:\\-]?\\s*([0-9][0-9,]*)"
        ) {
            return parseInt(regexMatch)
        }

        return parseFirstInteger(in: pageText)
    }

    private func parseCategory(named category: String, from lines: [String], pageText: String) -> PollenCategory {
        let snippet = context(for: category.lowercased(), in: lines, radius: 2)
        let severityText = parseSeverityText(from: snippet) ?? parseSeverityText(from: pageText, around: category)
        let severity = PollenSeverity(from: severityText ?? "")

        let numeric = parseFirstInteger(in: snippet).map { Double($0) }

        return PollenCategory(name: category, severity: severity, numericValue: numeric)
    }

    private func parseTopContributors(type: String, lines: [String], pageText: String) -> [String] {
        let lookup1 = "top \(type)"
        let lookup2 = "\(type) contributors"

        let contextSnippet = context(forEither: [lookup1, lookup2], in: lines, radius: 2)
        if let parsed = splitContributors(from: contextSnippet), !parsed.isEmpty {
            return parsed
        }

        if let matched = firstMatch(in: pageText, pattern: "\(type)s?[^.]{0,120}?top contributors?[:\\-]?\\s*([A-Za-z ,/&-]+)") {
            let parsed = splitContributors(from: matched)
            if !parsed.isEmpty {
                return parsed
            }
        }

        return []
    }

    private func parseMoldActivity(lines: [String], pageText: String) -> String {
        let snippet = context(for: "mold", in: lines, radius: 2)
        if let severityText = parseSeverityText(from: snippet) {
            return severityText.capitalized
        }

        if let severityText = parseSeverityText(from: pageText, around: "mold") {
            return severityText.capitalized
        }

        return "Unknown"
    }

    private func extractMeaningfulLines(document: Document) -> [String] {
        guard let elements = try? document.select("h1, h2, h3, h4, p, li, td, th, span, strong, b, div") else {
            return []
        }

        var lines = [String]()
        for element in elements.array() {
            if let rawText = try? element.text() {
                let cleaned = rawText.normalizedWhitespace()
                if cleaned.count > 1, cleaned.count < 240 {
                    lines.append(cleaned)
                }
            }
        }

        var deduplicated = [String]()
        var seen = Set<String>()
        for line in lines {
            let key = line.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                deduplicated.append(line)
            }
        }
        return deduplicated
    }

    private func extractReportLinks(from document: Document, baseURL: URL) -> [(date: Date, url: URL)] {
        guard let links = try? document.select("a[href]").array() else {
            return []
        }

        var candidates: [(Date, URL)] = []

        for link in links {
            guard let href = try? link.attr("href"), !href.isEmpty else { continue }
            guard href.contains("/pollen_counts/index/") else { continue }

            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            guard let date = parseDate(from: url) else { continue }

            candidates.append((date, url))
        }

        let unique = Dictionary(grouping: candidates, by: { $0.1.absoluteString })
            .compactMap { _, value in value.max(by: { $0.0 < $1.0 }) }

        return unique.sorted { $0.0 > $1.0 }
    }

    private func fetchRecentTrend(primaryCandidates: [(date: Date, url: URL)], reportURL: URL) async throws -> [DailyPollenPoint] {
        var points: [DailyPollenPoint] = []
        var seenDates = Set<String>()

        func appendIfValid(_ date: Date, _ count: Int) {
            let key = isoDateOnly(date)
            guard !seenDates.contains(key) else { return }
            seenDates.insert(key)
            points.append(DailyPollenPoint(date: date, count: count))
        }

        for candidate in primaryCandidates.prefix(12) {
            if let count = try? await fetchOverallCount(for: candidate.url) {
                appendIfValid(candidate.date, count)
            }
            if points.count >= 5 { break }
        }

        if points.count < 5, let reportDate = parseDate(from: reportURL) {
            for dayOffset in 1...21 {
                guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: reportDate) else { continue }
                let url = reportURLForDate(date)
                if let count = try? await fetchOverallCount(for: url) {
                    appendIfValid(date, count)
                }
                if points.count >= 5 { break }
            }
        }

        return points.sorted { $0.date < $1.date }
    }

    private func fetchOverallCount(for url: URL) async throws -> Int {
        let html = try await loadHTML(from: url)
        let doc = try SwiftSoup.parse(html)
        let lines = extractMeaningfulLines(document: doc)
        let pageText = ((try? doc.body()?.text()) ?? "").normalizedWhitespace()

        if let count = parseOverallCount(from: pageText, lines: lines) {
            return count
        }
        throw PollenServiceError.failedToParseReport
    }

    private func probeMostRecentURL() async throws -> URL? {
        let start = Date()
        for dayOffset in 0...30 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: start) else { continue }
            let url = reportURLForDate(date)
            do {
                _ = try await loadHTML(from: url)
                return url
            } catch {
                continue
            }
        }
        return nil
    }

    private func reportURLForDate(_ date: Date) -> URL {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return URL(string: "https://www.atlantaallergy.com/pollen_counts/index/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")!
    }

    private func parseDate(from url: URL) -> Date? {
        let path = url.path
        guard let match = firstMatch(in: path, pattern: "/pollen_counts/index/([0-9]{4})/([0-9]{2})/([0-9]{2})") else {
            return nil
        }

        let parts = match.split(separator: "/").map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var comps = DateComponents()
        comps.calendar = calendar
        comps.year = year
        comps.month = month
        comps.day = day
        return comps.date
    }

    private func context(for label: String, in lines: [String], radius: Int) -> String {
        guard let index = lines.firstIndex(where: { $0.lowercased().contains(label.lowercased()) }) else {
            return ""
        }

        let lower = max(0, index - radius)
        let upper = min(lines.count - 1, index + radius)
        return lines[lower...upper].joined(separator: " ")
    }

    private func context(forEither labels: [String], in lines: [String], radius: Int) -> String {
        for label in labels {
            let hit = context(for: label, in: lines, radius: radius)
            if !hit.isEmpty { return hit }
        }
        return ""
    }

    private func parseFirstInteger(in text: String) -> Int? {
        guard let raw = firstMatch(in: text, pattern: "([0-9][0-9,]{0,8})") else { return nil }
        return parseInt(raw)
    }

    private func parseInt(_ raw: String) -> Int? {
        Int(raw.replacingOccurrences(of: ",", with: ""))
    }

    private func parseSeverityText(from text: String, around label: String? = nil) -> String? {
        let candidates = ["very high", "high", "moderate", "medium", "low", "absent", "none"]

        let scope: String
        if let label {
            let lowered = text.lowercased()
            if let range = lowered.range(of: label.lowercased()) {
                let after = lowered[range.lowerBound...]
                scope = String(after.prefix(160))
            } else {
                scope = lowered
            }
        } else {
            scope = text.lowercased()
        }

        for item in candidates where scope.contains(item) {
            return item
        }
        return nil
    }

    private func splitContributors(from raw: String) -> [String]? {
        let cleaned = raw
            .replacingOccurrences(of: "Top Contributors", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Top", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "contributors", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ":", with: " ")
            .normalizedWhitespace()

        guard cleaned.count > 3 else { return nil }

        let parts = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ",/;|"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                token.count >= 3 && token.range(of: "[A-Za-z]", options: .regularExpression) != nil
            }

        let unique = Array(NSOrderedSet(array: parts)) as? [String] ?? parts
        return Array(unique.prefix(4))
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        let captureRange = result.numberOfRanges > 1 ? result.range(at: 1) : result.range(at: 0)
        guard let swiftRange = Range(captureRange, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func isoDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private extension String {
    func normalizedWhitespace() -> String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
