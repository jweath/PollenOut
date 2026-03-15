import SwiftUI
#if canImport(Charts)
import Charts
#endif

struct TrendChartView: View {
    let points: [DailyPollenPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent 5 Reports")
                .font(.headline)
                .foregroundStyle(.white)

            if points.isEmpty {
                Text("No recent trend data")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                chartBody
                    .frame(height: 120)
                    .accessibilityLabel("Pollen trend chart")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.8), Color.blue.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    @ViewBuilder
    private var chartBody: some View {
        #if canImport(Charts)
        Chart(points) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Count", point.count)
            )
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            .foregroundStyle(.white)

            PointMark(
                x: .value("Date", point.date),
                y: .value("Count", point.count)
            )
            .foregroundStyle(.yellow)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) {
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(.white.opacity(0.9))
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks {
                AxisValueLabel()
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        #else
        GeometryReader { proxy in
            let sorted = points.sorted { $0.date < $1.date }
            let maxY = max(1, sorted.map(\.count).max() ?? 1)
            let minY = min(sorted.map(\.count).min() ?? 0, maxY)
            let range = max(1, maxY - minY)

            Path { path in
                for (index, point) in sorted.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(max(sorted.count - 1, 1))
                    let y = proxy.size.height * (1 - CGFloat(point.count - minY) / CGFloat(range))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        #endif
    }
}
