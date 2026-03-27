import Foundation
import Testing
import UserNotifications
@testable import Pollen_Out

struct DailyNotificationManagerTests {
    @Test @MainActor
    func initialInstallPrompt_isShownWhenStatusNotDeterminedAndNotHandled() async {
        let defaults = UserDefaults(suiteName: "DailyNotificationManagerTests-\(UUID().uuidString)")!
        let center = MockUserNotificationCenterClient(status: .notDetermined, requestAuthorizationResult: true)
        let manager = DailyNotificationManager(defaults: defaults, notificationCenter: center)

        let shouldShow = await manager.shouldShowInitialInstallPrompt()

        #expect(shouldShow == true)
    }

    @Test @MainActor
    func initialInstallPrompt_notShownAfterDismissal() async {
        let defaults = UserDefaults(suiteName: "DailyNotificationManagerTests-\(UUID().uuidString)")!
        let center = MockUserNotificationCenterClient(status: .notDetermined, requestAuthorizationResult: true)
        let manager = DailyNotificationManager(defaults: defaults, notificationCenter: center)

        manager.dismissInitialInstallPrompt()
        let shouldShow = await manager.shouldShowInitialInstallPrompt()

        #expect(shouldShow == false)
    }

    @Test @MainActor
    func enableFromInitialInstallPrompt_requestsAuthorizationAndEnablesWhenGranted() async {
        let defaults = UserDefaults(suiteName: "DailyNotificationManagerTests-\(UUID().uuidString)")!
        let center = MockUserNotificationCenterClient(status: .notDetermined, requestAuthorizationResult: true)
        let manager = DailyNotificationManager(defaults: defaults, notificationCenter: center)

        let granted = await manager.enableFromInitialInstallPrompt()

        #expect(granted == true)
        #expect(manager.isEnabled == true)
        #expect(await center.requestAuthorizationCallCount() == 1)
        #expect(await manager.shouldShowInitialInstallPrompt() == false)
    }

    @Test
    func defaultLocalTimeComponents_convertsTenAmEasternToLocal() {
        var calendar = Calendar(identifier: .gregorian)
        let eastern = TimeZone(identifier: "America/New_York")!
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        calendar.timeZone = eastern

        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 27
        components.hour = 9
        components.minute = 0
        let now = calendar.date(from: components)!

        let converted = DailyNotificationManager.defaultLocalTimeComponents(
            now: now,
            easternTimeZone: eastern,
            localTimeZone: pacific
        )

        #expect(converted.hour == 7)
        #expect(converted.minute == 0)
    }

    @Test
    func shouldNotify_skipsWhenReportIsNotTodayInEasternTime() {
        let eastern = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern

        var nowComponents = DateComponents()
        nowComponents.year = 2026
        nowComponents.month = 3
        nowComponents.day = 27
        nowComponents.hour = 10
        nowComponents.minute = 15
        let now = calendar.date(from: nowComponents)!

        var reportComponents = DateComponents()
        reportComponents.year = 2026
        reportComponents.month = 3
        reportComponents.day = 26
        reportComponents.hour = 12
        reportComponents.minute = 0
        let staleReportDate = calendar.date(from: reportComponents)!

        let shouldNotify = DailyNotificationManager.shouldNotify(
            reportDate: staleReportDate,
            now: now,
            lastNotifiedDayKey: nil,
            easternTimeZone: eastern
        )

        #expect(shouldNotify == false)
    }

    @Test
    func shouldNotify_skipsWhenAlreadyNotifiedForEasternReportDay() {
        let eastern = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern

        var dayComponents = DateComponents()
        dayComponents.year = 2026
        dayComponents.month = 3
        dayComponents.day = 27
        dayComponents.hour = 10
        dayComponents.minute = 0
        let now = calendar.date(from: dayComponents)!

        var reportComponents = dayComponents
        reportComponents.hour = 9
        let reportDate = calendar.date(from: reportComponents)!

        let dayKey = DailyNotificationManager.easternDayKey(for: reportDate, easternTimeZone: eastern)

        let shouldNotify = DailyNotificationManager.shouldNotify(
            reportDate: reportDate,
            now: now,
            lastNotifiedDayKey: dayKey,
            easternTimeZone: eastern
        )

        #expect(shouldNotify == false)
    }

    @Test
    func shouldNotify_allowsNewReportForTodayInEasternTime() {
        let eastern = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern

        var dayComponents = DateComponents()
        dayComponents.year = 2026
        dayComponents.month = 3
        dayComponents.day = 27
        dayComponents.hour = 10
        dayComponents.minute = 0
        let now = calendar.date(from: dayComponents)!

        var reportComponents = dayComponents
        reportComponents.hour = 9
        let reportDate = calendar.date(from: reportComponents)!

        let shouldNotify = DailyNotificationManager.shouldNotify(
            reportDate: reportDate,
            now: now,
            lastNotifiedDayKey: nil,
            easternTimeZone: eastern
        )

        #expect(shouldNotify == true)
    }
}

private final class MockUserNotificationCenterClient: UserNotificationCenterClient {
    private let lock = NSLock()
    private let status: UNAuthorizationStatus
    private let authorizationResult: Bool
    private var requestCallCount = 0

    init(status: UNAuthorizationStatus, requestAuthorizationResult: Bool) {
        self.status = status
        self.authorizationResult = requestAuthorizationResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock {
            requestCallCount += 1
        }
        return authorizationResult
    }

    func add(_ request: UNNotificationRequest) async throws {}

    func removePendingRequests(withIdentifiers identifiers: [String]) {}

    func requestAuthorizationCallCount() -> Int {
        lock.withLock { requestCallCount }
    }
}
