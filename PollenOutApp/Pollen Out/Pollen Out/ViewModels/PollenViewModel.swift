import Foundation
import SwiftUI
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class PollenViewModel: ObservableObject {
    @Published private(set) var report: PollenReport?
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingCachedData = false
    @Published var errorMessage: String?
    @Published var diagnosticsText: String = ""
    @Published private(set) var notificationPermissionWarning: String?
    @Published private(set) var shouldShowInitialNotificationPrompt = false

    private let serviceExecutor: ServiceExecutor
    private let cache: PollenCache
    let notificationManager: DailyNotificationManager
    private let lastAccessedKey = "lastAccessedDate"
    private let calendar = Calendar(identifier: .gregorian)
    private let fetchTimeoutSeconds: Double = 75
    private let initialFetchTimeoutSeconds: Double = 75
    private let refreshTimeoutMessage = "Refresh timed out. Please try again."
    private let connectivityMessage = "Couldn't reach the pollen source. Check your connection and try again."
    private var hasAttemptedInitialNotificationRequest = false

    init(
        service: PollenReportProviding? = nil,
        cache: PollenCache? = nil,
        notificationManager: DailyNotificationManager? = nil
    ) {
        self.serviceExecutor = ServiceExecutor(service: service ?? AtlantaAllergyPollenService())
        self.cache = cache ?? PollenCache()
        self.notificationManager = notificationManager ?? DailyNotificationManager()
        self.report = self.cache.load()
        self.isShowingCachedData = report != nil
    }

    func loadInitialData() async {
        guard let report else {
            await refresh()
            return
        }

        let today = calendar.startOfDay(for: Date())
        let reportDay = calendar.startOfDay(for: report.date)
        if reportDay < today {
            await refresh()
        }

        await notificationManager.handleUpdatedReport(report)
    }

    func handleAppBecameActive() async {
        let now = Date()
        defer {
            UserDefaults.standard.set(now, forKey: lastAccessedKey)
        }

        guard let lastAccessed = UserDefaults.standard.object(forKey: lastAccessedKey) as? Date else {
            return
        }

        let nowDay = calendar.startOfDay(for: now)
        let lastDay = calendar.startOfDay(for: lastAccessed)
        if nowDay > lastDay {
            await refresh()
        }
    }

    func refresh() async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        let timeoutSeconds = (report == nil) ? initialFetchTimeoutSeconds : fetchTimeoutSeconds

        do {
            let fetched = try await fetchReportOffMain(timeoutSeconds: timeoutSeconds)
            applyFetchedReport(fetched)
            await notificationManager.handleUpdatedReport(fetched)
        } catch is CancellationError {
            await recoverFromCancellation(timeoutSeconds: timeoutSeconds)
        } catch let urlError as URLError where urlError.code == .cancelled {
            await recoverFromCancellation(timeoutSeconds: timeoutSeconds)
        } catch let nsError as NSError
            where nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            await recoverFromCancellation(timeoutSeconds: timeoutSeconds)
        } catch let urlError as URLError where urlError.code == .timedOut {
            errorMessage = refreshTimeoutMessage
            diagnosticsText = "Fetch timed out:\n\(urlError.localizedDescription)"
            if let cached = cache.load() {
                report = cached
                isShowingCachedData = true
                diagnosticsText += "\n\nUsing cached report: \(cached.sourceURL.absoluteString)"
            }
        } catch let nsError as NSError
            where nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            errorMessage = refreshTimeoutMessage
            diagnosticsText = "Fetch timed out:\n\(nsError.localizedDescription)"
            if let cached = cache.load() {
                report = cached
                isShowingCachedData = true
                diagnosticsText += "\n\nUsing cached report: \(cached.sourceURL.absoluteString)"
            }
        } catch let urlError as URLError
            where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code) {
            errorMessage = connectivityMessage
            diagnosticsText = "Network error (\(urlError.code.rawValue)):\n\(urlError.localizedDescription)"
            if let cached = cache.load() {
                report = cached
                isShowingCachedData = true
                diagnosticsText += "\n\nUsing cached report: \(cached.sourceURL.absoluteString)"
            }
        } catch {
            errorMessage = error.localizedDescription
            diagnosticsText = "Fetch failed:\n\(error.localizedDescription)"
            if let cached = cache.load() {
                report = cached
                isShowingCachedData = true
                diagnosticsText += "\n\nUsing cached report: \(cached.sourceURL.absoluteString)"
            }
        }
    }

    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func fetchReportOffMain(timeoutSeconds: Double) async throws -> PollenReport {
        let executor = serviceExecutor
        return try await Self.fetchReport(executor: executor, timeoutSeconds: timeoutSeconds)
    }

    private func recoverFromCancellation(timeoutSeconds: Double) async {
        diagnosticsText = "Fetch interrupted. Retrying..."

        if Task.isCancelled {
            retryRefreshAfterCancellation(timeoutSeconds: timeoutSeconds)
            return
        }

        do {
            let fetched = try await fetchReportOffMain(timeoutSeconds: timeoutSeconds)
            applyFetchedReport(fetched)
            await notificationManager.handleUpdatedReport(fetched)
        } catch {
            diagnosticsText = "Fetch cancelled."
        }
    }

    private func retryRefreshAfterCancellation(timeoutSeconds: Double) {
        let executor = serviceExecutor
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await Self.fetchReport(executor: executor, timeoutSeconds: timeoutSeconds)
                await MainActor.run {
                    self.applyFetchedReport(fetched)
                    Task {
                        await self.notificationManager.handleUpdatedReport(fetched)
                    }
                }
            } catch {
                await MainActor.run {
                    self.diagnosticsText = "Fetch cancelled."
                }
            }
        }
    }

    private func applyFetchedReport(_ fetched: PollenReport) {
        report = fetched
        errorMessage = nil
        isShowingCachedData = false
        diagnosticsText = """
        Loaded report: \(fetched.sourceURL.absoluteString)
        Report date: \(fetched.date.formatted(date: .abbreviated, time: .omitted))
        Trend points: \(fetched.recentTrend.count)
        Trend values (latest->oldest): \(fetched.recentTrend.sorted(by: { $0.date > $1.date }).map(\.count).map(String.init).joined(separator: ", "))
        """
        cache.save(report: fetched)
        reloadWidgetTimelines()
    }

    private static func fetchReport(executor: ServiceExecutor, timeoutSeconds: Double) async throws -> PollenReport {
        return try await withThrowingTaskGroup(of: PollenReport.self) { group in
            group.addTask(priority: .userInitiated) {
                try await executor.service.fetchLatestReport()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let first = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return first
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        await notificationManager.setEnabled(enabled)
        if enabled && !notificationManager.isEnabled {
            notificationPermissionWarning = "Notifications are blocked in system settings."
        } else {
            notificationPermissionWarning = nil
        }

        if let report {
            await notificationManager.handleUpdatedReport(report)
        }
    }

    func updateNotificationTime(_ value: Date) async {
        notificationManager.updatePreferredTime(value)
        if let report {
            await notificationManager.handleUpdatedReport(report)
        }
    }

    func prepareInitialNotificationPrompt() async {
        shouldShowInitialNotificationPrompt = await notificationManager.shouldShowInitialInstallPrompt()
    }

    func requestInitialNotificationsDuringFirstLoadIfNeeded() async {
        guard !hasAttemptedInitialNotificationRequest else { return }
        hasAttemptedInitialNotificationRequest = true

        let shouldPrompt = await notificationManager.shouldShowInitialInstallPrompt()
        shouldShowInitialNotificationPrompt = shouldPrompt
        guard shouldPrompt else { return }

        let granted = await notificationManager.enableFromInitialInstallPrompt()
        shouldShowInitialNotificationPrompt = false
        notificationPermissionWarning = granted ? nil : "Notifications are blocked in system settings."

        if granted, let report {
            await notificationManager.handleUpdatedReport(report)
        }
    }

    func enableNotificationsFromInitialPrompt() async {
        let granted = await notificationManager.enableFromInitialInstallPrompt()
        shouldShowInitialNotificationPrompt = false
        notificationPermissionWarning = granted ? nil : "Notifications are blocked in system settings."

        if granted, let report {
            await notificationManager.handleUpdatedReport(report)
        }
    }

    func dismissInitialNotificationPrompt() {
        notificationManager.dismissInitialInstallPrompt()
        shouldShowInitialNotificationPrompt = false
    }
}

private final class ServiceExecutor: @unchecked Sendable {
    let service: PollenReportProviding

    init(service: PollenReportProviding) {
        self.service = service
    }
}
