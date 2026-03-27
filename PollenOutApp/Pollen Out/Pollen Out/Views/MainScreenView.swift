import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct MainScreenView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PollenViewModel()
    @State private var didTriggerInitialLoad = false
    @State private var didStartInitialDataLoad = false
    @State private var isShowingSettings = false
    private let pollenPageURL = URL(string: "https://www.atlantaallergy.com/pollen_counts")!

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let layout = LayoutMetrics.forHeight(proxy.size.height)

                ZStack {
                    backgroundView
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                            if let report = viewModel.report {
                                if viewModel.isLoading {
                                    Text("Checking for updated data...")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, 4)
                                }
                                overallCard(report, layout: layout)
                                TrendChartView(points: report.recentTrend, layout: layout)
                                categorySection(report, layout: layout)
                            } else if viewModel.shouldShowInitialNotificationPrompt || viewModel.isLoading {
                                VStack(spacing: 14) {
                                    if viewModel.isLoading {
                                        ProgressView()
                                            .tint(.white)
                                    }

                                    Text(viewModel.isLoading
                                         ? "Fetching pollen report..."
                                         : "While we're preparing your first pollen report...")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .multilineTextAlignment(.center)

                                    Text("Want to receive a single daily notification with the latest overall pollen count and top contributors?")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.85))
                                        .multilineTextAlignment(.center)

                                    if viewModel.shouldShowInitialNotificationPrompt {
                                        VStack(spacing: 24) {
                                            Button {
                                                Task {
                                                    await viewModel.enableNotificationsFromInitialPrompt()
                                                    await startInitialDataLoadIfNeeded()
                                                }
                                            } label: {
                                                Text("Enable Notifications")
                                                    .font(.subheadline.weight(.semibold))
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.horizontal, 18)
                                                    .padding(.vertical, 14)
                                                    .background(.white.opacity(0.2))
                                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            }
                                            .foregroundStyle(.white)

                                            Button {
                                                viewModel.dismissInitialNotificationPrompt()
                                                Task {
                                                    await startInitialDataLoadIfNeeded()
                                                }
                                            } label: {
                                                Text("Don't Enable Notifications")
                                                    .font(.subheadline)
                                                    .multilineTextAlignment(.center)
                                            }
                                            .foregroundStyle(.white.opacity(0.82))
                                        }
                                        .padding(.top, 8)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 220)
                                .padding(.top, 24)
                            } else {
                                VStack(spacing: 12) {
                                    Text(viewModel.errorMessage == nil
                                         ? "Welcome to PollenOut.\nPreparing to fetch initial pollen data."
                                         : "No pollen report available yet.")
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.white)

                                    if viewModel.errorMessage != nil {
                                        Button {
                                            Task {
                                                await viewModel.refresh()
                                            }
                                        } label: {
                                            Text("Try Again")
                                                .font(.subheadline.weight(.semibold))
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(.white.opacity(0.18))
                                                .clipShape(Capsule())
                                        }
                                        .foregroundStyle(.white)
                                        .disabled(viewModel.isLoading)

                                        if !viewModel.diagnosticsText.isEmpty {
                                            Text(viewModel.diagnosticsText)
                                                .font(.caption2)
                                                .multilineTextAlignment(.center)
                                                .foregroundStyle(.white.opacity(0.8))
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                                .padding(.top, 24)
                            }
 
                        }
                        .frame(minHeight: proxy.size.height - (layout.verticalPadding * 2), alignment: .top)
                        .padding(.horizontal, layout.horizontalPadding)
                        .padding(.top, max(4, layout.verticalPadding - 6))
                        .padding(.bottom, layout.verticalPadding)
                    }
                    .tint(.white)
                    .refreshable {
                        triggerRefreshFeedback()
                        await viewModel.refresh()
                    }
                }
                .onAppear {
                    configureRefreshControlAppearance()
                    guard !didTriggerInitialLoad else { return }
                    didTriggerInitialLoad = true
                    Task {
                        await viewModel.prepareInitialNotificationPrompt()
                        guard !viewModel.shouldShowInitialNotificationPrompt else { return }
                        await startInitialDataLoadIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task {
                        await viewModel.handleAppBecameActive()
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .accessibilityLabel("Error: \(error)")
                        }

                        if let warning = viewModel.notificationPermissionWarning {
                            Text(warning)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .accessibilityLabel("Notification warning: \(warning)")
                        }

                        if !viewModel.shouldShowInitialNotificationPrompt {
                            Button {
                                isShowingSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                            }
                            .foregroundStyle(.white)
                            .accessibilityLabel("Open notification settings")
                        }
                    }
                    .padding(.bottom, 12)
                }
                .sheet(isPresented: $isShowingSettings) {
                    NotificationSettingsSheet(
                        manager: viewModel.notificationManager,
                        onToggleNotifications: { enabled in
                            await viewModel.setNotificationsEnabled(enabled)
                        },
                        onTimeChanged: { date in
                            await viewModel.updateNotificationTime(date)
                        }
                    )
                }
            }
        }
    }

    private func overallCard(_ report: PollenReport, layout: LayoutMetrics) -> some View {
        VStack(alignment: .center, spacing: layout.grid * 0.5) {
            VStack(spacing: 0) {
                Text("Last updated")
                    .font(.system(size: layout.updatedFontSize, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.92))
                Text(formattedDate(report.date))
                    .font(.system(size: layout.updatedFontSize, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            VStack(spacing: -2) {
                Text("\(report.overallCount)")
                    .font(.system(size: layout.countFontSize, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("Overall Pollen Count")
                    .font(.system(size: layout.labelFontSize, weight: .bold, design: .default))
                    .foregroundStyle(.white)
            }
            .padding(.top, -layout.grid * 1.5)
            .frame(maxWidth: .infinity)

            Text("Severity: \(overallSeverityText(for: report.overallCount))")
                .font(.system(size: layout.severityFontSize, weight: .semibold, design: .default))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity)
                .padding(.top, -layout.grid * 0.5)

            Link(destination: pollenPageURL) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .foregroundStyle(.white.opacity(0.92))
                        .imageScale(.small)
                    Text("atlantaallergy.com")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.top, layout.grid)
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("Open atlantaallergy.com source report in Safari")
        }
        .padding(layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous)
                .fill(report.severityGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overall pollen count \(report.overallCount), \(overallSeverityText(for: report.overallCount))")
    }

    private func categorySection(_ report: PollenReport, layout: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: layout.categorySpacing) {
            ForEach(report.categories) { category in
                CategoryBarChartView(
                    category: category,
                    detailText: detailText(for: category.name, report: report),
                    layout: layout
                )
            }
        }
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.10, blue: 0.18), Color(red: 0.45, green: 0.12, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .saturation(0.08)

            Circle()
                .fill(.white.opacity(0.1))
                .blur(radius: 35)
                .frame(width: 240)
                .offset(x: 140, y: -280)

            RoundedRectangle(cornerRadius: 60)
                .fill(.white.opacity(0.05))
                .rotationEffect(.degrees(-20))
                .offset(x: -180, y: 280)
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return Self.updatedDateFormatter.string(from: date)
    }

    private func overallSeverityText(for count: Int) -> String {
        switch count {
        case ..<100: return "Low"
        case 100..<300: return "Moderate"
        case 300..<700: return "High"
        default: return "Very High"
        }
    }

    private func detailText(for categoryName: String, report: PollenReport) -> String? {
        switch categoryName.lowercased() {
        case "trees":
            return standardContributorText(report.treeTopContributors)
        case "weeds":
            return standardContributorText(report.weedTopContributors)
        default:
            return nil
        }
    }

    private func standardContributorText(_ contributors: [String]) -> String? {
        let cleaned = contributors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased().localizedCapitalized }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.joined(separator: ", ")
    }

}

@MainActor
private extension MainScreenView {
    func startInitialDataLoadIfNeeded() async {
        guard !didStartInitialDataLoad else { return }
        didStartInitialDataLoad = true
        await viewModel.loadInitialData()
        await viewModel.handleAppBecameActive()
    }
}

private struct NotificationSettingsSheet: View {
    @ObservedObject var manager: DailyNotificationManager
    let onToggleNotifications: @Sendable (Bool) async -> Void
    let onTimeChanged: @Sendable (Date) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { manager.isEnabled },
                        set: { newValue in
                            Task {
                                await onToggleNotifications(newValue)
                            }
                        }
                    )) {
                        Text("Daily Pollen Notifications")
                    }
                }

                if manager.isEnabled {
                    Section("Delivery Time") {
                        DatePicker(
                            "Notify Me",
                            selection: Binding(
                                get: { manager.preferredTime },
                                set: { newValue in
                                    Task {
                                        await onTimeChanged(newValue)
                                    }
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.wheel)

                        Text("Default time is based on 10:00 AM Eastern, converted to your local timezone. Source data usually updates around 9:00 to 9:30 AM Eastern.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private extension MainScreenView {
    static var didConfigureRefreshControlAppearance = false

    func configureRefreshControlAppearance() {
        #if canImport(UIKit)
        guard !Self.didConfigureRefreshControlAppearance else { return }
        UIRefreshControl.appearance().tintColor = .white
        Self.didConfigureRefreshControlAppearance = true
        #endif
    }

    func triggerRefreshFeedback() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}

private extension MainScreenView {
    static let updatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()
}

struct LayoutMetrics {
    let grid: CGFloat
    let sectionSpacing: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let countFontSize: CGFloat
    let labelFontSize: CGFloat
    let severityFontSize: CGFloat
    let updatedFontSize: CGFloat
    let cardInnerSpacing: CGFloat
    let cardPadding: CGFloat
    let cardCornerRadius: CGFloat
    let categorySpacing: CGFloat
    let trendHeight: CGFloat
    let trendPadding: CGFloat
    let categoryBarHeight: CGFloat
    let categoryScaleHeight: CGFloat
    let categoryPadding: CGFloat
    let categoryBottomExtraPadding: CGFloat

    static func forHeight(_ height: CGFloat) -> LayoutMetrics {
        let expanded: CGFloat
        switch height {
        case ..<780: expanded = 1.00
        case 780..<860: expanded = 1.16
        case 860..<940: expanded = 1.30
        default: expanded = 1.42
        }
        return LayoutMetrics(
            grid: 4 * expanded,
            sectionSpacing: max(6, (12 * expanded) - 2),
            horizontalPadding: 12 * expanded,
            verticalPadding: 11 * expanded,
            countFontSize: 60 * expanded,
            labelFontSize: 16 * expanded,
            severityFontSize: 13 * expanded,
            updatedFontSize: 12 * expanded,
            cardInnerSpacing: 6 * expanded,
            cardPadding: 11 * expanded,
            cardCornerRadius: 20 * expanded,
            categorySpacing: max(6, (10 * expanded) - 2),
            trendHeight: 112 * expanded,
            trendPadding: 11 * expanded,
            categoryBarHeight: 20 * expanded,
            categoryScaleHeight: 20 * expanded,
            categoryPadding: 9 * expanded,
            categoryBottomExtraPadding: 4 * expanded
        )
    }
}

#Preview {
    MainScreenView()
}
