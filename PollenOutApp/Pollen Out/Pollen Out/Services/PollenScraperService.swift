import Foundation
import SwiftSoup

enum PollenServiceError: LocalizedError {
    case noReportsFound(details: String)
    case failedToParseReport(url: URL, details: String)

    var errorDescription: String? {
        switch self {
        case .noReportsFound(let details):
            return "No recent pollen report was found on the source website.\n\(details)"
        case .failedToParseReport(let url, let details):
            return "Could not parse the latest pollen report at \(url.absoluteString).\n\(details)"
        }
    }
}

protocol PollenReportProviding {
    func fetchLatestReport() async throws -> PollenReport
}

final class AtlantaAllergyPollenService: PollenReportProviding {
    private struct AvailableReportRef {
        let date: Date
        let url: URL
        let overallCount: Int
    }

    private let session: URLSession
    private let baseURL = URL(string: "https://www.atlantaallergy.com/pollen_counts")!
    private let calendar = Calendar(identifier: .gregorian)
    private let perRequestTimeoutSeconds: TimeInterval = 12
    private let fetchBudgetSeconds: TimeInterval = 25
    private let maxRequestAttempts = 3
    private let retryBackoffNanoseconds: [UInt64] = [350_000_000, 800_000_000]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatestReport() async throws -> PollenReport {
        let fetchStart = Date()
        let today = calendar.startOfDay(for: Date())
        var attemptDiagnostics: [String] = []
        var candidateLinks: [(date: Date, url: URL)] = []

        do {
            let mainHTML = try await loadHTML(from: baseURL)
            let mainDocument = try SwiftSoup.parse(mainHTML)

            // Fast path: many source pages include the latest report directly on /pollen_counts.
            if let mainCount = parseOverallCountInDocument(mainDocument),
               var report = parseReport(
                    document: mainDocument,
                    sourceURL: baseURL,
                    fallbackDate: today,
                    fallbackOverallCount: mainCount
               ) {
                let trend = parseTrendPoints(
                    in: mainDocument,
                    fallbackDate: report.date,
                    fallbackCount: report.overallCount,
                    limit: 5
                )
                report = PollenReport(
                    date: report.date,
                    sourceURL: baseURL,
                    overallCount: report.overallCount,
                    categories: report.categories,
                    treeTopContributors: report.treeTopContributors,
                    weedTopContributors: report.weedTopContributors,
                    moldActivity: report.moldActivity,
                    recentTrend: trend
                )
                return report
            }

            candidateLinks = extractReportLinks(from: mainDocument, baseURL: baseURL)
        } catch {
            attemptDiagnostics.append("\(baseURL.absoluteString) -> \(compactErrorDescription(error))")
        }

        var latestReport: PollenReport?
        var latestDocument: Document?
        var prioritizedCandidates: [(date: Date, url: URL)] = []

        for dayOffset in 0...10 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            prioritizedCandidates.append((date, reportURLForDate(date)))
        }

        prioritizedCandidates.append(contentsOf: candidateLinks.sorted(by: { $0.date > $1.date }))

        var seenURLs = Set<String>()
        let dedupedCandidates = prioritizedCandidates.filter { candidate in
            seenURLs.insert(candidate.url.absoluteString).inserted
        }
        let parseCandidates = dedupedCandidates.prefix(14)

        for candidate in parseCandidates {
            if Date().timeIntervalSince(fetchStart) >= fetchBudgetSeconds {
                attemptDiagnostics.append("Stopped after exceeding \(Int(fetchBudgetSeconds))s fetch budget.")
                break
            }
            do {
                let reportHTML = try await loadHTML(from: candidate.url)
                let reportDocument = try SwiftSoup.parse(reportHTML)
                let fallbackCount = parseOverallCountInDocument(reportDocument)

                guard let parsed = parseReport(
                    document: reportDocument,
                    sourceURL: candidate.url,
                    fallbackDate: candidate.date,
                    fallbackOverallCount: fallbackCount
                ) else {
                    attemptDiagnostics.append("\(candidate.url.absoluteString) -> parse returned nil")
                    continue
                }

                latestReport = parsed
                latestDocument = reportDocument
                break
            } catch {
                attemptDiagnostics.append("\(candidate.url.absoluteString) -> \(compactErrorDescription(error))")
            }
        }

        guard var report = latestReport else {
            let details = """
            Candidate links found: \(candidateLinks.count)
            Attempted URLs: \(parseCandidates.count)
            \(attemptDiagnostics.isEmpty ? "No diagnostics collected." : attemptDiagnostics.prefix(8).joined(separator: "\n"))
            """
            throw PollenServiceError.noReportsFound(details: details)
        }

        // Keep initial-load latency low: trend is extracted from the same page when available.
        let trend = latestDocument.map {
            parseTrendPoints(in: $0, fallbackDate: report.date, fallbackCount: report.overallCount, limit: 5)
        } ?? [DailyPollenPoint(date: report.date, count: report.overallCount)]

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

        return report
    }

    private func parseTrendPoints(
        in document: Document,
        fallbackDate: Date,
        fallbackCount: Int,
        limit: Int
    ) -> [DailyPollenPoint] {
        guard let anchors = try? document.select("a[href*='/pollen_counts/index/']").array() else {
            return [DailyPollenPoint(date: fallbackDate, count: fallbackCount)]
        }

        var byDate: [Date: Int] = [:]
        for anchor in anchors {
            guard let href = try? anchor.attr("href"),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let date = parseDate(from: url),
                  let text = try? anchor.text(),
                  let count = parseInt(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            byDate[calendar.startOfDay(for: date)] = count
        }

        byDate[calendar.startOfDay(for: fallbackDate)] = fallbackCount

        let sorted = byDate
            .map { DailyPollenPoint(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }

        if sorted.isEmpty {
            return [DailyPollenPoint(date: fallbackDate, count: fallbackCount)]
        }

        return Array(sorted.suffix(max(1, limit)))
    }

    private func loadHTML(from url: URL) async throws -> String {
        var lastError: Error?

        for attempt in 0..<maxRequestAttempts {
            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                request.timeoutInterval = perRequestTimeoutSeconds

                let (data, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }

                guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                    throw URLError(.cannotDecodeRawData)
                }
                return html
            } catch {
                lastError = error
                guard let urlError = error as? URLError, isTransientNetworkError(urlError), attempt < (maxRequestAttempts - 1) else {
                    throw error
                }

                if attempt < retryBackoffNanoseconds.count {
                    try await Task.sleep(nanoseconds: retryBackoffNanoseconds[attempt])
                }
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    private func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate:
            return true
        default:
            return false
        }
    }

    private func compactErrorDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue)): \(urlError.localizedDescription)"
        }
        return error.localizedDescription
    }

    private func parseReport(
        document: Document,
        sourceURL: URL,
        fallbackDate: Date? = nil,
        fallbackOverallCount: Int? = nil
    ) -> PollenReport? {
        let pageText = ((try? document.body()?.text()) ?? "").normalizedWhitespace()
        if pageContainsNoDataMessage(pageText) {
            return nil
        }
        let lines = extractMeaningfulLines(document: document)

        let overallCount = parseOverallCount(from: pageText, lines: lines) ?? fallbackOverallCount
        let reportDate = parseDate(from: sourceURL) ?? fallbackDate
        guard let reportDate, let overallCount else {
            return nil
        }

        let treesGauge = parseGaugeCategory(named: "trees", in: document)
        let grassGauge = parseGaugeCategory(named: "grass", in: document)
        let weedsGauge = parseGaugeCategory(named: "weeds", in: document)
        let moldGauge = parseMoldGauge(in: document)

        let trees = treesGauge?.category ?? parseCategory(named: "Trees", from: lines, pageText: pageText)
        let grass = grassGauge?.category ?? parseCategory(named: "Grass", from: lines, pageText: pageText)
        let weeds = weedsGauge?.category ?? parseCategory(named: "Weeds", from: lines, pageText: pageText)
        let mold = moldGauge?.category ?? parseCategory(named: "Mold", from: lines, pageText: pageText)

        let treeContributors = treesGauge?.contributors ?? parseTopContributors(type: "tree", lines: lines, pageText: pageText)
        let weedContributors = weedsGauge?.contributors ?? parseTopContributors(type: "weed", lines: lines, pageText: pageText)
        let moldActivity = moldGauge?.category.severity.displayText ?? parseMoldActivity(lines: lines, pageText: pageText)

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

    private struct GaugeParseResult {
        let category: PollenCategory
        let contributors: [String]
    }

    private func parseGaugeCategory(named key: String, in document: Document) -> GaugeParseResult? {
        guard let gauges = try? document.select(".gauge").array() else { return nil }

        for gauge in gauges {
            guard let heading = try? gauge.select("h3").first()?.text().lowercased(),
                  heading.contains(key) else {
                continue
            }

            let needlePercent = parseNeedlePercent(in: gauge)
            let activeText = (try? gauge.select(".gauge-segments .active").first()?.text()) ?? ""
            let severity = severityFromGaugeSegment(activeText)
            let displayValue = deriveGaugeDisplayValue(
                needlePercent: needlePercent,
                activeSegmentText: activeText,
                severity: severity
            )

            let contributorsText = (try? gauge.select("p").first()?.text()) ?? ""
            let contributors = splitContributors(from: contributorsText) ?? []

            let displayName = key.capitalized
            let category = PollenCategory(
                name: displayName,
                severity: severity,
                numericValue: displayValue,
                normalizedValue: needlePercent
            )
            return GaugeParseResult(category: category, contributors: contributors)
        }
        return nil
    }

    private func parseMoldGauge(in document: Document) -> GaugeParseResult? {
        guard let moldHeading = try? document.select("h4:contains(Mold Activity)").first(),
              let moldContainer = moldHeading.parent(),
              let gauge = try? moldContainer.select(".gauge").first() else {
            return nil
        }

        let needlePercent = parseNeedlePercent(in: gauge)
        let activeText = (try? gauge.select(".gauge-segments .active").first()?.text()) ?? ""
        let severity = severityFromGaugeSegment(activeText)
        let displayValue = deriveGaugeDisplayValue(
            needlePercent: needlePercent,
            activeSegmentText: activeText,
            severity: severity
        )

        let category = PollenCategory(
            name: "Mold",
            severity: severity,
            numericValue: displayValue,
            normalizedValue: needlePercent
        )
        return GaugeParseResult(category: category, contributors: [])
    }

    private func parseNeedlePercent(in element: Element?) -> Double? {
        guard let style = try? element?.select(".needle").first()?.attr("style"),
              let raw = firstMatch(in: style, pattern: "left\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)%") else {
            return nil
        }
        guard let value = Double(raw) else { return nil }
        return min(max(value, 0), 100)
    }

    private func severityFromGaugeSegment(_ text: String) -> PollenSeverity {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("l=") || normalized == "low" { return .low }
        if normalized.hasPrefix("m=") || normalized == "moderate" { return .moderate }
        if normalized.hasPrefix("h=") || normalized == "high" { return .high }
        if normalized.hasPrefix("e=") || normalized.contains("extremely high") { return .veryHigh }
        return PollenSeverity(from: normalized)
    }

    private func parseOverallCount(from pageText: String, lines: [String]) -> Int? {
        if pageContainsNoDataMessage(pageText) {
            return nil
        }

        if let regexMatch = firstMatch(
            in: pageText,
            pattern: "total\\s+pollen\\s+count(?:\\s+for\\s+[0-9]{1,2}/[0-9]{1,2}/[0-9]{4})?\\s*[:\\-]\\s*([0-9][0-9,]*)"
        ) {
            return parseInt(regexMatch)
        }

        let totalContext = context(for: "total pollen count", in: lines, radius: 3)
        if let lastInContext = parseLastInteger(in: totalContext) {
            return lastInContext
        }

        if let byGeneralPollenCount = firstMatch(
            in: pageText,
            pattern: "pollen\\s+count\\s*[:\\-]?\\s*([0-9][0-9,]*)"
        ) {
            return parseInt(byGeneralPollenCount)
        }

        if let lineBased = lines
            .first(where: { line in
                let lowered = line.lowercased()
                return lowered.contains("pollen") && lowered.contains("count")
            })
            .flatMap({ parseFirstInteger(in: $0) }) {
            return lineBased
        }

        return nil
    }

    private func parseCategory(named category: String, from lines: [String], pageText: String) -> PollenCategory {
        let snippet = context(for: category.lowercased(), in: lines, radius: 2)
        let severityText = parseSeverityText(from: snippet) ?? parseSeverityText(from: pageText, around: category)
        let severity = PollenSeverity(from: severityText ?? "")

        let numeric = parseFirstInteger(in: snippet).map { Double($0) }

        return PollenCategory(name: category, severity: severity, numericValue: numeric, normalizedValue: nil)
    }

    private func deriveGaugeDisplayValue(
        needlePercent: Double?,
        activeSegmentText: String,
        severity: PollenSeverity
    ) -> Double? {
        guard let needlePercent else { return nil }
        guard let range = parseRange(from: activeSegmentText) else { return needlePercent }

        let segmentIndex = segmentIndex(for: severity)
        let segmentStart = Double(segmentIndex) * 25.0
        let segmentProgress = min(max((needlePercent - segmentStart) / 25.0, 0), 1)

        if let max = range.max {
            return range.min + ((max - range.min) * segmentProgress)
        }

        // Open-ended ranges like "1500+" are estimated using 50% of the lower bound span.
        return range.min + (range.min * 0.5 * segmentProgress)
    }

    private func segmentIndex(for severity: PollenSeverity) -> Int {
        switch severity {
        case .low, .absent:
            return 0
        case .moderate:
            return 1
        case .high:
            return 2
        case .veryHigh:
            return 3
        case .unknown:
            return 1
        }
    }

    private func parseRange(from activeSegmentText: String) -> (min: Double, max: Double?)? {
        let normalized = activeSegmentText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")

        if let raw = firstMatch(in: normalized, pattern: "=[0-9]+\\+") {
            let number = raw.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "")
            if let min = Double(number) {
                return (min: min, max: nil)
            }
        }

        if let raw = firstMatch(in: normalized, pattern: "=[0-9]+-[0-9]+") {
            let pair = raw.replacingOccurrences(of: "=", with: "").split(separator: "-")
            if pair.count == 2, let min = Double(pair[0]), let max = Double(pair[1]) {
                return (min: min, max: max)
            }
        }

        return nil
    }

    private func parseTopContributors(type: String, lines: [String], pageText: String) -> [String] {
        let lookup1 = "top \(type)"
        let lookup2 = "\(type) contributors"

        let contextSnippet = context(forEither: [lookup1, lookup2], in: lines, radius: 2)
        if let parsed = splitContributors(from: contextSnippet), !parsed.isEmpty {
            return parsed
        }

        if let matched = firstMatch(in: pageText, pattern: "\(type)s?[^.]{0,120}?top contributors?[:\\-]?\\s*([A-Za-z ,/&-]+)") {
            if let parsed = splitContributors(from: matched), !parsed.isEmpty {
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

    private func fetchMostRecentAvailableReports(
        from primaryCandidates: [(date: Date, url: URL)],
        desiredCount: Int
    ) async throws -> ([AvailableReportRef], String) {
        var refs: [AvailableReportRef] = []
        var seenDates = Set<String>()
        var attemptedURLs: [String] = []
        var failures: [String] = []

        func appendIfAvailable(date: Date, url: URL, count: Int) {
            let key = isoDateOnly(date)
            guard !seenDates.contains(key) else { return }
            seenDates.insert(key)
            refs.append(AvailableReportRef(date: date, url: url, overallCount: count))
        }

        for candidate in primaryCandidates.sorted(by: { $0.date > $1.date }) {
            attemptedURLs.append(candidate.url.absoluteString)
            do {
                let count = try await fetchOverallCount(for: candidate.url)
                appendIfAvailable(date: candidate.date, url: candidate.url, count: count)
            } catch {
                failures.append("\(candidate.url.absoluteString) -> \(error.localizedDescription)")
            }
            if refs.count >= desiredCount { break }
        }

        if refs.count < desiredCount {
            let probeStartDate = refs.first?.date ?? Date()
            var fallbackCandidates: [(date: Date, url: URL)] = []
            for dayOffset in 0...60 {
                guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: probeStartDate) else { continue }
                let key = isoDateOnly(date)
                if seenDates.contains(key) { continue }

                let url = reportURLForDate(date)
                fallbackCandidates.append((date, url))
            }

            let maxConcurrentProbes = 4
            let fallbackProbeDeadline = Date().addingTimeInterval(8)

            struct ProbeResult {
                let date: Date
                let url: URL
                let count: Int?
                let errorDescription: String?
            }

            for batchStart in stride(from: 0, to: fallbackCandidates.count, by: maxConcurrentProbes) {
                if Date() >= fallbackProbeDeadline { break }
                let batchEnd = min(batchStart + maxConcurrentProbes, fallbackCandidates.count)
                let batch = fallbackCandidates[batchStart..<batchEnd]

                let results = await withTaskGroup(of: ProbeResult.self, returning: [ProbeResult].self) { group in
                    for candidate in batch {
                        group.addTask {
                            do {
                                let count = try await self.fetchOverallCount(for: candidate.url)
                                return ProbeResult(
                                    date: candidate.date,
                                    url: candidate.url,
                                    count: count,
                                    errorDescription: nil
                                )
                            } catch {
                                return ProbeResult(
                                    date: candidate.date,
                                    url: candidate.url,
                                    count: nil,
                                    errorDescription: error.localizedDescription
                                )
                            }
                        }
                    }

                    var collected: [ProbeResult] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }

                for result in results.sorted(by: { $0.date > $1.date }) {
                    attemptedURLs.append(result.url.absoluteString)
                    if let count = result.count {
                        appendIfAvailable(date: result.date, url: result.url, count: count)
                    } else if let errorDescription = result.errorDescription {
                        failures.append("\(result.url.absoluteString) -> \(errorDescription)")
                    }
                }

                if refs.count >= desiredCount { break }
            }
        }

        let diagnostics = """
        Candidate links found: \(primaryCandidates.count)
        Attempted URLs: \(attemptedURLs.count)
        Available reports parsed: \(refs.count)
        \(failures.isEmpty ? "No parse failures recorded." : "Parse failures:\n" + failures.prefix(8).joined(separator: "\n"))
        """

        return (refs.sorted { $0.date > $1.date }, diagnostics)
    }

    private func fetchOverallCount(for url: URL) async throws -> Int {
        let html = try await loadHTML(from: url)
        let doc = try SwiftSoup.parse(html)

        if let count = parseOverallCountInDocument(doc) {
            return count
        }
        throw PollenServiceError.failedToParseReport(url: url, details: "Total Pollen Count label not found on page.")
    }

    private func parseOverallCountInDocument(_ doc: Document) -> Int? {
        let pageText = ((try? doc.body()?.text()) ?? "").normalizedWhitespace()
        if pageContainsNoDataMessage(pageText) {
            return nil
        }

        // Most reliable source: the report page header line with the total for that date.
        if let heading = try? doc.select("h3:contains(Total Pollen Count)").first(),
           let headingText = try? heading.text(),
           let headingValue = parseLastInteger(in: headingText) {
            return headingValue
        }

        let lines = extractMeaningfulLines(document: doc)

        if let count = parseOverallCount(from: pageText, lines: lines) {
            return count
        }
        return nil
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
        guard let regex = try? NSRegularExpression(
            pattern: "/pollen_counts/index/([0-9]{4})/([0-9]{2})/([0-9]{2})",
            options: []
        ) else {
            return nil
        }

        let range = NSRange(path.startIndex..., in: path)
        guard let match = regex.firstMatch(in: path, options: [], range: range),
              let yearRange = Range(match.range(at: 1), in: path),
              let monthRange = Range(match.range(at: 2), in: path),
              let dayRange = Range(match.range(at: 3), in: path),
              let year = Int(path[yearRange]),
              let month = Int(path[monthRange]),
              let day = Int(path[dayRange]) else {
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

    private func parseLastInteger(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9][0-9,]{0,8})", options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard let last = matches.last, let swiftRange = Range(last.range(at: 1), in: text) else {
            return nil
        }
        return parseInt(String(text[swiftRange]))
    }

    private func parseInt(_ raw: String) -> Int? {
        Int(raw.replacingOccurrences(of: ",", with: ""))
    }

    private func pageContainsNoDataMessage(_ text: String) -> Bool {
        firstMatch(
            in: text,
            pattern: "there\\s+is\\s+no\\s+pollen\\s+data\\s+for\\s+[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}"
        ) != nil
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
