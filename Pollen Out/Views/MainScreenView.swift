import SwiftUI

struct MainScreenView: View {
    @StateObject private var viewModel = PollenViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundView
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        if let report = viewModel.report {
                            overallCard(report)
                            TrendChartView(points: report.recentTrend)
                            categorySection(report)
                            contributorsSection(report)
                        } else if viewModel.isLoading {
                            ProgressView("Loading latest report...")
                                .tint(.white)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            Text("No pollen report available yet.")
                                .foregroundStyle(.white)
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
            .task {
                await viewModel.loadInitialData()
            }
            .navigationTitle("Pollen Out")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                        .accessibilityLabel("Error: \(error)")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who's pollen out today?")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                Text("Last updated: \(formattedDate(viewModel.report?.date))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))

                if let url = viewModel.report?.sourceURL {
                    Link(destination: url) {
                        Image(systemName: "square.and.arrow.up.right")
                            .foregroundStyle(.white)
                            .imageScale(.small)
                    }
                    .accessibilityLabel("Open source report in Safari")
                }

                if viewModel.isShowingCachedData {
                    Text("Showing last known report")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .accessibilityLabel("Showing last known report")
                }
            }
        }
    }

    private func overallCard(_ report: PollenReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(report.overallCount)")
                .font(.system(size: 74, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text("Overall Pollen Count")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            Text("Severity: \(overallSeverityText(for: report.overallCount))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(report.severityGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overall pollen count \(report.overallCount), \(overallSeverityText(for: report.overallCount))")
    }

    private func categorySection(_ report: PollenReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.categories) { category in
                CategoryBarChartView(category: category)
            }
        }
    }

    private func contributorsSection(_ report: PollenReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !report.treeTopContributors.isEmpty {
                contributorCard(title: "Tree Top Contributors", values: report.treeTopContributors)
            }
            if !report.weedTopContributors.isEmpty {
                contributorCard(title: "Weed Top Contributors", values: report.weedTopContributors)
            }

            contributorCard(title: "Mold Activity", values: [report.moldActivity])
        }
    }

    private func contributorCard(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(values.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.10, blue: 0.18), Color(red: 0.45, green: 0.12, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

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
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMMM yyyy"
        return formatter.string(from: date)
    }

    private func overallSeverityText(for count: Int) -> String {
        switch count {
        case ..<100: return "Low"
        case 100..<300: return "Moderate"
        case 300..<700: return "High"
        default: return "Very High"
        }
    }
}

#Preview {
    MainScreenView()
}
