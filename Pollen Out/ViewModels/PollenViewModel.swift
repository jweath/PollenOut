import Foundation
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class PollenViewModel: ObservableObject {
    @Published private(set) var report: PollenReport?
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingCachedData = false
    @Published var errorMessage: String?

    private let service: PollenReportProviding
    private let cache: PollenCache

    init(
        service: PollenReportProviding = AtlantaAllergyPollenService(),
        cache: PollenCache = PollenCache()
    ) {
        self.service = service
        self.cache = cache
        self.report = cache.load()
        self.isShowingCachedData = report != nil
    }

    func loadInitialData() async {
        if report == nil {
            await refresh()
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await service.fetchLatestReport()
            report = fetched
            errorMessage = nil
            isShowingCachedData = false
            cache.save(report: fetched)
            reloadWidgetTimelines()
        } catch {
            errorMessage = error.localizedDescription
            if let cached = cache.load() {
                report = cached
                isShowingCachedData = true
            }
        }
    }

    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
