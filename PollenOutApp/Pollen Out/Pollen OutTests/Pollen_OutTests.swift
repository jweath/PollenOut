//
//  Pollen_OutTests.swift
//  Pollen OutTests
//
//  Created by John Weatherford on 3/14/26.
//

import Foundation
import Testing
import UserNotifications
@testable import Pollen_Out

@Suite(.serialized)
struct Pollen_OutTests {
    @Test @MainActor
    func loadInitialData_refreshesWhenCachedReportIsFromPriorDay() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "lastAccessedDate")

        let cache = makeIsolatedCache()
        let now = Date()
        let staleDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: now)!
        cache.save(report: makeReport(date: staleDate, overallCount: 120))

        let service = MockPollenService(result: .success(makeReport(date: now, overallCount: 200)))
        let viewModel = PollenViewModel(service: service, cache: cache)

        await viewModel.loadInitialData()

        #expect(await service.fetchCount() == 1)
        #expect(viewModel.report?.overallCount == 200)
    }

    @Test @MainActor
    func refresh_onTimeoutShowsFriendlyErrorAndKeepsCachedReport() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "lastAccessedDate")

        let cache = makeIsolatedCache()
        let cachedDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Date())!
        cache.save(report: makeReport(date: cachedDate, overallCount: 150))

        let service = MockPollenService(result: .failure(URLError(.timedOut)))
        let viewModel = PollenViewModel(service: service, cache: cache)

        await viewModel.refresh()

        #expect(viewModel.report?.overallCount == 150)
        #expect(viewModel.isShowingCachedData == true)
        #expect(viewModel.errorMessage == "Refresh timed out. Please try again.")
    }

    @Test @MainActor
    func refresh_whenInitialFetchIsCancelled_retriesAndPublishesNewReport() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "lastAccessedDate")

        let cache = makeIsolatedCache()
        let staleDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Date())!
        cache.save(report: makeReport(date: staleDate, overallCount: 150))

        let freshReport = makeReport(date: Date(), overallCount: 420)
        let service = MockPollenService(results: [
            .failure(URLError(.cancelled)),
            .success(freshReport)
        ])
        let viewModel = PollenViewModel(service: service, cache: cache)

        await viewModel.refresh()
        await waitForReportCount(420, in: viewModel)

        #expect(await service.fetchCount() == 2)
        #expect(viewModel.report?.overallCount == 420)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isShowingCachedData == false)
    }

    @Test @MainActor
    func requestInitialNotificationsDuringFirstLoadIfNeeded_requestsAuthorizationWhenEligible() async throws {
        let defaults = UserDefaults(suiteName: "PollenOutTests-\(UUID().uuidString)")!
        let center = MockNotificationCenterClient(status: .notDetermined, requestAuthorizationResult: true)
        let manager = DailyNotificationManager(defaults: defaults, notificationCenter: center)
        let service = MockPollenService(result: .success(makeReport(date: Date(), overallCount: 100)))
        let viewModel = PollenViewModel(service: service, cache: makeIsolatedCache(), notificationManager: manager)

        await viewModel.requestInitialNotificationsDuringFirstLoadIfNeeded()

        #expect(await center.requestAuthorizationCallCount() == 1)
        #expect(viewModel.notificationPermissionWarning == nil)
        #expect(viewModel.shouldShowInitialNotificationPrompt == false)
    }

    @Test @MainActor
    func requestInitialNotificationsDuringFirstLoadIfNeeded_setsWarningWhenDenied() async throws {
        let defaults = UserDefaults(suiteName: "PollenOutTests-\(UUID().uuidString)")!
        let center = MockNotificationCenterClient(status: .notDetermined, requestAuthorizationResult: false)
        let manager = DailyNotificationManager(defaults: defaults, notificationCenter: center)
        let service = MockPollenService(result: .success(makeReport(date: Date(), overallCount: 100)))
        let viewModel = PollenViewModel(service: service, cache: makeIsolatedCache(), notificationManager: manager)

        await viewModel.requestInitialNotificationsDuringFirstLoadIfNeeded()

        #expect(await center.requestAuthorizationCallCount() == 1)
        #expect(viewModel.notificationPermissionWarning == "Notifications are blocked in system settings.")
        #expect(viewModel.shouldShowInitialNotificationPrompt == false)
    }

    @Test
    func fetchLatestReport_whenTodayPageSaysNoData_usesMostRecentAvailableDay() async throws {
        let baseURL = URL(string: "https://www.atlantaallergy.com/pollen_counts")!
        let noDataURL = URL(string: "https://www.atlantaallergy.com/pollen_counts/index/2026/03/17")!
        let latestAvailableURL = URL(string: "https://www.atlantaallergy.com/pollen_counts/index/2026/03/16")!
        let olderURL = URL(string: "https://www.atlantaallergy.com/pollen_counts/index/2026/03/09")!

        let noDataHTML = """
        <html><body>
        <p>There is no pollen data for 03/17/2026</p>
        <a href="/pollen_counts/index/2026/03/17">3</a>
        <a href="/pollen_counts/index/2026/03/16">4650</a>
        <a href="/pollen_counts/index/2026/03/09">3</a>
        </body></html>
        """

        let availableHTML = """
        <html><body>
        <h3>Total Pollen Count for 03/16/2026: 4,650</h3>
        <a href="/pollen_counts/index/2026/03/16">4650</a>
        <a href="/pollen_counts/index/2026/03/14">1200</a>
        </body></html>
        """

        let responseByURL: [URL: String] = [
            baseURL: noDataHTML,
            noDataURL: noDataHTML,
            latestAvailableURL: availableHTML,
            olderURL: """
            <html><body><h3>Total Pollen Count for 03/09/2026: 3</h3></body></html>
            """
        ]

        let session = makeSession(responseByURL: responseByURL)
        let service = AtlantaAllergyPollenService(session: session)

        let report = try await service.fetchLatestReport()

        let calendar = Calendar(identifier: .gregorian)
        let expectedDate = calendar.startOfDay(for: latestAvailableURLDate())
        #expect(calendar.startOfDay(for: report.date) == expectedDate)
        #expect(report.overallCount == 4650)
    }

    @Test
    func fetchLatestReport_whenWeekendHasData_prefersWeekendOverOlderWeekday() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let priorWeekendDay = try #require(mostRecentWeekendDay(before: today, calendar: calendar))
        let priorWeekday = try #require(mostRecentWeekday(before: priorWeekendDay, calendar: calendar))
        let secondWeekendDay = calendar.date(byAdding: .day, value: -1, to: priorWeekendDay)
            .flatMap { calendar.isDateInWeekend($0) ? $0 : nil }

        let baseURL = URL(string: "https://www.atlantaallergy.com/pollen_counts")!
        let todayNoDataURL = reportURL(for: today, calendar: calendar)
        let weekendURL = reportURL(for: priorWeekendDay, calendar: calendar)
        let weekdayURL = reportURL(for: priorWeekday, calendar: calendar)
        let secondWeekendURL = secondWeekendDay.map { reportURL(for: $0, calendar: calendar) }

        let noDataHTML = """
        <html><body>
        <p>There is no pollen data for \(monthDayYearString(today))</p>
        <a href="\(todayNoDataURL.path)">3</a>
        <a href="\(weekendURL.path)">2,792</a>
        \(secondWeekendURL.map { "<a href=\"\($0.path)\">1,876</a>" } ?? "")
        <a href="\(weekdayURL.path)">245</a>
        </body></html>
        """

        let weekendHTML = """
        <html><body>
        <h3>Total Pollen Count for \(monthDayYearString(priorWeekendDay)): 2,792</h3>
        <a href="\(weekendURL.path)">2792</a>
        \(secondWeekendURL.map { "<a href=\"\($0.path)\">1876</a>" } ?? "")
        <a href="\(weekdayURL.path)">245</a>
        </body></html>
        """

        let weekdayHTML = """
        <html><body>
        <h3>Total Pollen Count for \(monthDayYearString(priorWeekday)): 245</h3>
        </body></html>
        """

        var responseByURL: [URL: String] = [
            baseURL: noDataHTML,
            todayNoDataURL: noDataHTML,
            weekendURL: weekendHTML,
            weekdayURL: weekdayHTML
        ]
        if let secondWeekendDay, let secondWeekendURL {
            responseByURL[secondWeekendURL] = """
            <html><body>
            <h3>Total Pollen Count for \(monthDayYearString(secondWeekendDay)): 1,876</h3>
            </body></html>
            """
        }

        let session = makeSession(responseByURL: responseByURL)
        let service = AtlantaAllergyPollenService(session: session)

        let report = try await service.fetchLatestReport()

        let expectedDate = calendar.startOfDay(for: priorWeekendDay)
        #expect(calendar.startOfDay(for: report.date) == expectedDate)
        #expect(report.overallCount == 2792)
    }

    @Test
    func fetchLatestReport_whenBasePageTimesOutOnce_retriesAndSucceeds() async throws {
        let baseURL = URL(string: "https://www.atlantaallergy.com/pollen_counts")!
        let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
        let expectedCount = 2792
        let html = """
        <html><body>
        <h3>Total Pollen Count for \(monthDayYearString(today)): 2,792</h3>
        </body></html>
        """

        let session = makeSession(
            responseByURL: [:],
            scriptedResponsesByURL: [
                baseURL: [
                    .failure(URLError(.timedOut)),
                    .success(html)
                ]
            ]
        )
        let service = AtlantaAllergyPollenService(session: session)

        let report = try await service.fetchLatestReport()

        #expect(report.sourceURL == baseURL)
        #expect(report.overallCount == expectedCount)
    }

    @Test
    func fetchLatestReport_whenBasePageAlwaysTimesOut_fallsBackToDatedURLs() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let baseURL = URL(string: "https://www.atlantaallergy.com/pollen_counts")!
        let todayURL = reportURL(for: today, calendar: calendar)
        let expectedCount = 6563
        let todayHTML = """
        <html><body>
        <h3>Total Pollen Count for \(monthDayYearString(today)): 6,563</h3>
        </body></html>
        """

        let session = makeSession(
            responseByURL: [
                todayURL: todayHTML
            ],
            scriptedResponsesByURL: [
                baseURL: [
                    .failure(URLError(.timedOut)),
                    .failure(URLError(.timedOut)),
                    .failure(URLError(.timedOut))
                ]
            ]
        )
        let service = AtlantaAllergyPollenService(session: session)

        let report = try await service.fetchLatestReport()

        #expect(calendar.startOfDay(for: report.date) == today)
        #expect(report.overallCount == expectedCount)
        #expect(report.sourceURL == todayURL)
    }

    private func makeReport(date: Date, overallCount: Int) -> PollenReport {
        PollenReport(
            date: date,
            sourceURL: URL(string: "https://example.com/report")!,
            overallCount: overallCount,
            categories: [
                PollenCategory(name: "Trees", severity: .moderate, numericValue: 100, normalizedValue: 45)
            ],
            treeTopContributors: [],
            weedTopContributors: [],
            moldActivity: "Low",
            recentTrend: [DailyPollenPoint(date: date, count: overallCount)]
        )
    }

    private func makeIsolatedCache() -> PollenCache {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pollen-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        return PollenCache(fileURL: tempDirectory.appendingPathComponent("latest_pollen_report.json"))
    }

    private func makeSession(
        responseByURL: [URL: String],
        scriptedResponsesByURL: [URL: [MockURLProtocol.MockResponse]] = [:]
    ) -> URLSession {
        MockURLProtocol.responseByURL = responseByURL
        MockURLProtocol.scriptedResponsesByURL = scriptedResponsesByURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    private func waitForReportCount(_ expected: Int, in viewModel: PollenViewModel) async {
        for _ in 0..<100 {
            if viewModel.report?.overallCount == expected {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for report overallCount to become \(expected). Current value: \(String(describing: viewModel.report?.overallCount))")
    }

    private func latestAvailableURLDate() -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2026
        components.month = 3
        components.day = 16
        return components.date!
    }

    private func reportURL(for date: Date, calendar: Calendar) -> URL {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return URL(string: "https://www.atlantaallergy.com/pollen_counts/index/\(year)/\(String(format: "%02d", month))/\(String(format: "%02d", day))")!
    }

    private func monthDayYearString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.string(from: date)
    }

    private func mostRecentWeekendDay(before date: Date, calendar: Calendar) -> Date? {
        for dayOffset in 1...14 {
            guard let candidate = calendar.date(byAdding: .day, value: -dayOffset, to: date) else { continue }
            if calendar.isDateInWeekend(candidate) {
                return calendar.startOfDay(for: candidate)
            }
        }
        return nil
    }

    private func mostRecentWeekday(before date: Date, calendar: Calendar) -> Date? {
        for dayOffset in 1...7 {
            guard let candidate = calendar.date(byAdding: .day, value: -dayOffset, to: date) else { continue }
            if !calendar.isDateInWeekend(candidate) {
                return calendar.startOfDay(for: candidate)
            }
        }
        return nil
    }
}

private actor MockPollenService: PollenReportProviding {
    enum Result {
        case success(PollenReport)
        case failure(any Error)
    }

    private var fetchInvocationCount = 0
    private var results: [Result]

    init(result: Result) {
        self.results = [result]
    }

    init(results: [Result]) {
        self.results = results
    }

    func fetchLatestReport() async throws -> PollenReport {
        fetchInvocationCount += 1
        let result = results.isEmpty ? .failure(URLError(.badServerResponse)) : results.removeFirst()
        switch result {
        case .success(let report):
            return report
        case .failure(let error):
            throw error
        }
    }

    func fetchCount() -> Int {
        fetchInvocationCount
    }
}

private final class MockURLProtocol: URLProtocol {
    enum MockResponse {
        case success(String)
        case failure(URLError)
    }

    private static let lock = NSLock()
    static var responseByURL: [URL: String] = [:]
    static var scriptedResponsesByURL: [URL: [MockResponse]] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if let scripted = nextScriptedResponse(for: url) {
            switch scripted {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
                return
            case .success(let body):
                respondWithHTML(body, for: url)
                return
            }
        }

        guard let body = Self.responseByURL[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        respondWithHTML(body, for: url)
    }

    private func nextScriptedResponse(for url: URL) -> MockResponse? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard var queue = Self.scriptedResponsesByURL[url], !queue.isEmpty else {
            return nil
        }
        let first = queue.removeFirst()
        Self.scriptedResponsesByURL[url] = queue
        return first
    }

    private func respondWithHTML(_ body: String, for url: URL) {
        guard let data = body.data(using: .utf8) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeRawData))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockNotificationCenterClient: UserNotificationCenterClient {
    private let lock = NSLock()
    private var status: UNAuthorizationStatus
    private let authorizationResult: Bool
    private var requestCallCount = 0

    init(status: UNAuthorizationStatus, requestAuthorizationResult: Bool) {
        self.status = status
        self.authorizationResult = requestAuthorizationResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        lock.withLock { status }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock {
            requestCallCount += 1
            status = authorizationResult ? .authorized : .denied
        }
        return authorizationResult
    }

    func add(_ request: UNNotificationRequest) async throws {}

    func removePendingRequests(withIdentifiers identifiers: [String]) {}

    func requestAuthorizationCallCount() async -> Int {
        lock.withLock { requestCallCount }
    }
}
