import SwiftUI

struct CategoryBarChartView: View {
    let category: PollenCategory
    let detailText: String?
    let layout: LayoutMetrics
    private let scalePalette: [Color] = [
        Color(red: 0.47, green: 0.76, blue: 0.24),
        Color(red: 0.88, green: 0.84, blue: 0.24),
        Color(red: 0.94, green: 0.57, blue: 0.22),
        Color(red: 0.88, green: 0.28, blue: 0.28)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(category.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.leading, 3)
                Spacer()
                Text(severityDisplayText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.trailing, 6)
            }

            unifiedBarAndScale
                .padding(.vertical, 2)

            if let detailText, !detailText.isEmpty {
                Text(detailText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.leading, 3)
            }
        }
        .padding(.bottom, layout.categoryBottomExtraPadding)
        .padding(layout.categoryPadding)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.accessibilitySummary)
    }

    private var unifiedBarAndScale: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.12))
            .overlay {
                VStack(spacing: 0) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            LinearGradient(
                                colors: scalePalette,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .opacity(0.34)

                            RoundedRectangle(cornerRadius: 0, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: fillGradientColors,
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: proxy.size.width * CGFloat(clampedFillRatio))
                        }
                    }
                    .frame(height: layout.categoryBarHeight)

                    HStack(spacing: 0) {
                        ForEach(Array(scaleSegments.enumerated()), id: \.offset) { index, segment in
                            Text(segment)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(maxWidth: .infinity)
                                .frame(height: layout.categoryScaleHeight)
                                .background(scaleColor(index: index).opacity(0.42))
                        }
                    }
                }
            }
            .frame(height: layout.categoryBarHeight + layout.categoryScaleHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var severityDisplayText: String {
        switch category.severity {
        case .moderate:
            return "Medium"
        case .veryHigh:
            return "Extreme"
        default:
            return category.severity.displayText
        }
    }

    private var scaleSegments: [String] {
        switch category.name.lowercased() {
        case "trees":
            return ["0-14", "15-89", "90-1499", "1500+"]
        case "grass":
            return ["0-4", "5-19", "20-199", "200+"]
        case "weeds":
            return ["0-9", "10-49", "50-499", "500+"]
        default:
            return ["Low", "Moderate", "High", "Extreme"]
        }
    }

    private var activeSegmentIndex: Int {
        switch category.severity {
        case .absent, .low:
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

    private func scaleColor(index: Int) -> Color {
        scalePalette[min(max(index, 0), scalePalette.count - 1)]
    }

    private var fillGradientColors: [Color] {
        let active = scaleColor(index: activeSegmentIndex)
        return [active.opacity(0.95), active]
    }

    private var clampedFillRatio: Double {
        let raw = max(0.05, min(category.barValue / 100, 1.0))
        return raw >= 0.95 ? 1.0 : raw
    }
}
