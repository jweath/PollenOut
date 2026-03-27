import Foundation
import Combine
import UserNotifications

@MainActor
final class DailyNotificationManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var preferredTime: Date

    private let defaults: UserDefaults
    private let notificationCenter: UserNotificationCenterClient
    private let easternTimeZone: TimeZone
    private let calendar: Calendar

    private let enabledKey = "dailyNotificationsEnabled"
    private let preferredHourKey = "dailyNotificationsPreferredHour"
    private let preferredMinuteKey = "dailyNotificationsPreferredMinute"
    private let lastNotifiedEasternDayKey = "dailyNotificationsLastEasternDay"
    private let initialInstallPromptHandledKey = "initialNotificationPromptHandled"
    private let requestIdentifierPrefix = "daily-pollen"

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: UserNotificationCenterClient? = nil,
        easternTimeZone: TimeZone = TimeZone(identifier: "America/New_York")!,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter ?? SystemUserNotificationCenterClient()
        self.easternTimeZone = easternTimeZone
        self.calendar = calendar

        let hasStoredHour = defaults.object(forKey: preferredHourKey) != nil
        let hasStoredMinute = defaults.object(forKey: preferredMinuteKey) != nil

        if hasStoredHour && hasStoredMinute {
            let storedHour = defaults.integer(forKey: preferredHourKey)
            let storedMinute = defaults.integer(forKey: preferredMinuteKey)
            self.preferredTime = Self.dateForLocalTime(hour: storedHour, minute: storedMinute, calendar: calendar, now: Date())
        } else {
            let defaultComponents = Self.defaultLocalTimeComponents(
                now: Date(),
                easternTimeZone: easternTimeZone,
                localTimeZone: calendar.timeZone
            )
            let defaultHour = defaultComponents.hour ?? 10
            let defaultMinute = defaultComponents.minute ?? 0
            defaults.set(defaultHour, forKey: preferredHourKey)
            defaults.set(defaultMinute, forKey: preferredMinuteKey)
            self.preferredTime = Self.dateForLocalTime(hour: defaultHour, minute: defaultMinute, calendar: calendar, now: Date())
        }

        self.isEnabled = defaults.bool(forKey: enabledKey)
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await requestAuthorizationIfNeeded()
            isEnabled = granted
            defaults.set(granted, forKey: enabledKey)
            if !granted {
                notificationCenter.removePendingRequests(withIdentifiers: pendingIdentifiersForTodayAndTomorrow(now: Date()))
            }
            return
        }

        isEnabled = false
        defaults.set(false, forKey: enabledKey)
        notificationCenter.removePendingRequests(withIdentifiers: pendingIdentifiersForTodayAndTomorrow(now: Date()))
    }

    func shouldShowInitialInstallPrompt() async -> Bool {
        guard !defaults.bool(forKey: initialInstallPromptHandledKey) else {
            return false
        }
        return await notificationCenter.authorizationStatus() == .notDetermined
    }

    func dismissInitialInstallPrompt() {
        defaults.set(true, forKey: initialInstallPromptHandledKey)
    }

    func enableFromInitialInstallPrompt() async -> Bool {
        defaults.set(true, forKey: initialInstallPromptHandledKey)
        await setEnabled(true)
        return isEnabled
    }

    func updatePreferredTime(_ newValue: Date) {
        let hour = calendar.component(.hour, from: newValue)
        let minute = calendar.component(.minute, from: newValue)
        defaults.set(hour, forKey: preferredHourKey)
        defaults.set(minute, forKey: preferredMinuteKey)
        preferredTime = Self.dateForLocalTime(hour: hour, minute: minute, calendar: calendar, now: Date())
        notificationCenter.removePendingRequests(withIdentifiers: pendingIdentifiersForTodayAndTomorrow(now: Date()))
    }

    func handleUpdatedReport(_ report: PollenReport, now: Date = Date()) async {
        guard isEnabled else { return }
        guard await isAuthorized() else { return }

        let lastNotifiedDay = defaults.string(forKey: lastNotifiedEasternDayKey)
        guard Self.shouldNotify(
            reportDate: report.date,
            now: now,
            lastNotifiedDayKey: lastNotifiedDay,
            easternTimeZone: easternTimeZone
        ) else {
            return
        }

        let reportDayKey = Self.easternDayKey(for: report.date, easternTimeZone: easternTimeZone)
        let identifier = "\(requestIdentifierPrefix)-\(reportDayKey)"
        notificationCenter.removePendingRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Today's pollen count: \(report.overallCount)"
        content.body = notificationBody(for: report)
        content.sound = .default

        let triggerDate = preferredTriggerDate(now: now)
        let triggerComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await notificationCenter.add(request)
            defaults.set(reportDayKey, forKey: lastNotifiedEasternDayKey)
        } catch {
            // Keep notification failures silent for now to avoid user-facing noise.
        }
    }

    nonisolated static func defaultLocalTimeComponents(
        now: Date,
        easternTimeZone: TimeZone,
        localTimeZone: TimeZone
    ) -> DateComponents {
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = easternTimeZone

        var sourceDay = sourceCalendar.dateComponents([.year, .month, .day], from: now)
        sourceDay.hour = 10
        sourceDay.minute = 0
        sourceDay.second = 0
        let easternTenAM = sourceCalendar.date(from: sourceDay) ?? now

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = localTimeZone
        return localCalendar.dateComponents([.hour, .minute], from: easternTenAM)
    }

    nonisolated static func easternDayKey(for date: Date, easternTimeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = easternTimeZone

        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    nonisolated static func shouldNotify(
        reportDate: Date,
        now: Date,
        lastNotifiedDayKey: String?,
        easternTimeZone: TimeZone
    ) -> Bool {
        let reportDayKey = easternDayKey(for: reportDate, easternTimeZone: easternTimeZone)
        let nowDayKey = easternDayKey(for: now, easternTimeZone: easternTimeZone)

        guard reportDayKey == nowDayKey else {
            return false
        }

        return reportDayKey != lastNotifiedDayKey
    }

    nonisolated private static func dateForLocalTime(hour: Int, minute: Int, calendar: Calendar, now: Date) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: today) ?? now
    }

    private func pendingIdentifiersForTodayAndTomorrow(now: Date) -> [String] {
        let today = Self.easternDayKey(for: now, easternTimeZone: easternTimeZone)
        let tomorrow = Self.easternDayKey(for: now.addingTimeInterval(86_400), easternTimeZone: easternTimeZone)
        return ["\(requestIdentifierPrefix)-\(today)", "\(requestIdentifierPrefix)-\(tomorrow)"]
    }

    private func preferredTriggerDate(now: Date) -> Date {
        let hour = defaults.integer(forKey: preferredHourKey)
        let minute = defaults.integer(forKey: preferredMinuteKey)

        let localPreferred = Self.dateForLocalTime(hour: hour, minute: minute, calendar: calendar, now: now)
        if localPreferred > now {
            return localPreferred
        }

        return now.addingTimeInterval(5)
    }

    private func notificationBody(for report: PollenReport) -> String {
        let contributors = topContributors(for: report)
        if contributors.isEmpty {
            return "Mold activity: \(report.moldActivity)"
        }

        return "Top contributors: \(contributors.joined(separator: ", "))"
    }

    private func topContributors(for report: PollenReport) -> [String] {
        let combined = report.treeTopContributors + report.weedTopContributors
        var seen = Set<String>()
        var result: [String] = []

        for contributor in combined {
            let cleaned = contributor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }

            seen.insert(key)
            result.append(cleaned.localizedCapitalized)

            if result.count == 3 {
                break
            }
        }

        return result
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let status = await notificationCenter.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        default:
            return false
        }
    }

    private func isAuthorized() async -> Bool {
        let status = await notificationCenter.authorizationStatus()
        return status == .authorized || status == .provisional || status == .ephemeral
    }
}

protocol UserNotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String])
}

struct SystemUserNotificationCenterClient: UserNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
