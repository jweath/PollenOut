//
//  Pollen_OutTests.swift
//  Pollen OutTests
//
//  Created by John Weatherford on 3/14/26.
//

import Foundation
import Testing
@testable import Pollen_Out

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

    private func makeSession(responseByURL: [URL: String]) -> URLSession {
        MockURLProtocol.responseByURL = responseByURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func latestAvailableURLDate() -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2026
        components.month = 3
        components.day = 16
        return components.date!
    }
}

private actor MockPollenService: PollenReportProviding {
    enum Result {
        case success(PollenReport)
        case failure(any Error)
    }

    private var fetchInvocationCount = 0
    private let result: Result

    init(result: Result) {
        self.result = result
    }

    func fetchLatestReport() async throws -> PollenReport {
        fetchInvocationCount += 1
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
    static var responseByURL: [URL: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let body = Self.responseByURL[url],
              let data = body.data(using: .utf8) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
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
