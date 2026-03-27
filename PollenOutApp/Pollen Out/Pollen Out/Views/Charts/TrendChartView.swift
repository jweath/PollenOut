import SwiftUI
#if canImport(Charts)
import Charts
#endif

struct TrendChartView: View {
    let points: [DailyPollenPoint]
    let layout: LayoutMetrics
    private let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Weekly Trend")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            if points.isEmpty {
                Text("No recent trend data")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                chartBody
                    .frame(height: layout.trendHeight + 20)
                    .accessibilityLabel("Pollen trend chart")
            }
        }
        .padding(layout.trendPadding)
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
        let displayPoints = buildDisplayPoints()
        GeometryReader { proxy in
            let labelYOffset: CGFloat = 16
            let plotHeight = max(20, proxy.size.height - labelYOffset)
            let axisWidth: CGFloat = 34
            let axisGap: CGFloat = 12
            let leftPlotInset: CGFloat = 6
            let rightPlotInset: CGFloat = 16
            let plotWidth = max(40, proxy.size.width - axisWidth - axisGap)
            let chartSize = CGSize(width: plotWidth, height: plotHeight)
            let segments = buildCurveSegments(displayPoints: displayPoints, size: chartSize)
            let yBounds = yBounds(for: displayPoints)
            let ticks = yAxisTicks(maxValue: yBounds.maxValue)

            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { tick in
                        let y = screenPoint(
                            index: 0,
                            total: 2,
                            value: tick,
                            minValue: yBounds.minValue,
                            maxValue: yBounds.maxValue,
                            size: chartSize
                        ).y
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: chartSize.width, y: y))
                        }
                        .stroke(
                            Color.white.opacity(0.22),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                    }

                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Path { path in
                            guard let first = segment.points.first else { return }
                            path.move(to: first)
                            for point in segment.points.dropFirst() {
                                path.addLine(to: point)
                            }
                        }
                        .stroke(
                            segment.color,
                            style: StrokeStyle(
                                lineWidth: 3,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: segment.isDashed ? [6, 4] : []
                            )
                        )
                    }

                    ForEach(Array(displayPoints.enumerated()), id: \.element.id) { index, point in
                        let pointPosition = screenPoint(
                            index: index,
                            total: displayPoints.count,
                            value: point.count,
                            minValue: yBounds.minValue,
                            maxValue: yBounds.maxValue,
                            size: chartSize,
                            leftInset: leftPlotInset,
                            rightInset: rightPlotInset
                        )

                        Group {
                            if point.hasData {
                                Circle()
                                    .fill(Color.yellow)
                                    .frame(width: 7, height: 7)
                            } else {
                                Circle()
                                    .stroke(Color.white.opacity(0.8), lineWidth: 1.4)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .position(pointPosition)

                        Text(labelDate(point.date))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(labelOpacity(for: point)))
                            .offset(x: pointPosition.x - 3, y: plotHeight + 7)
                    }
                }
                .frame(width: chartSize.width, height: plotHeight + labelYOffset, alignment: .topLeading)
                .padding(.trailing, axisGap)

                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { tick in
                        let y = screenPoint(
                            index: 0,
                            total: 2,
                            value: tick,
                            minValue: yBounds.minValue,
                            maxValue: yBounds.maxValue,
                            size: chartSize
                        ).y
                        Text(axisLabel(tick))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: axisWidth, alignment: .leading)
                            .position(x: axisWidth * 0.5, y: y)
                    }
                }
                .frame(width: axisWidth, height: plotHeight, alignment: .topLeading)
            }
        }
    }

    private func labelDate(_ date: Date) -> String {
        Self.labelDateFormatter.string(from: date)
    }

    private func labelOpacity(for point: DisplayPoint) -> Double {
        if calendar.isDateInWeekend(point.date) && !point.hasData { return 0.45 }
        return point.hasData ? 0.9 : 0.6
    }

    private func buildDisplayPoints() -> [DisplayPoint] {
        let sortedKnown = points.sorted { $0.date < $1.date }
        guard let last = sortedKnown.last else { return [] }

        let knownByDay = Dictionary(uniqueKeysWithValues: sortedKnown.map { (calendar.startOfDay(for: $0.date), Double($0.count)) })
        let endDay = calendar.startOfDay(for: last.date)
        guard let startDay = calendar.date(byAdding: .day, value: -6, to: endDay) else { return [] }

        var display: [DisplayPoint] = []
        var day = startDay
        while day <= endDay {
            if let known = knownByDay[day] {
                display.append(DisplayPoint(date: day, count: known, hasData: true))
            } else {
                let estimated = interpolatedCount(for: day, sortedKnown: sortedKnown)
                display.append(DisplayPoint(date: day, count: estimated, hasData: false))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return display
    }

    private func interpolatedCount(for day: Date, sortedKnown: [DailyPollenPoint]) -> Double {
        let known = sortedKnown.map { (date: calendar.startOfDay(for: $0.date), count: Double($0.count)) }
        let previous = known.last { $0.date < day }
        let next = known.first { $0.date > day }

        if let previous, let next {
            let totalDays = max(1, calendar.dateComponents([.day], from: previous.date, to: next.date).day ?? 1)
            let elapsedDays = max(0, calendar.dateComponents([.day], from: previous.date, to: day).day ?? 0)
            let t = Double(elapsedDays) / Double(totalDays)
            return previous.count + ((next.count - previous.count) * t)
        }

        if let previous { return previous.count }
        if let next { return next.count }
        return 0
    }

    private func yBounds(for displayPoints: [DisplayPoint]) -> (minValue: Double, maxValue: Double) {
        let values = displayPoints.map(\.count)
        let maxValue = max(1, values.max() ?? 1)
        let minValue = min(values.min() ?? 0, maxValue)
        if abs(maxValue - minValue) < 0.0001 {
            return (minValue: minValue, maxValue: minValue + 1)
        }
        return (minValue: minValue, maxValue: maxValue)
    }

    private func screenPoint(
        index: Int,
        total: Int,
        value: Double,
        minValue: Double,
        maxValue: Double,
        size: CGSize,
        leftInset: CGFloat = 0,
        rightInset: CGFloat = 0
    ) -> CGPoint {
        let usableWidth = max(1, size.width - leftInset - rightInset)
        let x = leftInset + (usableWidth * CGFloat(index) / CGFloat(max(total - 1, 1)))
        let normalized = (value - minValue) / max(0.0001, (maxValue - minValue))
        let y = size.height * CGFloat(1 - normalized)
        return CGPoint(x: x, y: y)
    }

    private func buildCurveSegments(displayPoints: [DisplayPoint], size: CGSize) -> [CurveSegment] {
        guard displayPoints.count >= 2 else { return [] }

        let bounds = yBounds(for: displayPoints)
        let anchors: [CGPoint] = displayPoints.enumerated().map { index, point in
            screenPoint(
                index: index,
                total: displayPoints.count,
                value: point.count,
                minValue: bounds.minValue,
                maxValue: bounds.maxValue,
                size: size,
                leftInset: 6,
                rightInset: 16
            )
        }

        let samplesPerSegment = 18
        var segments: [CurveSegment] = []

        for i in 0..<(anchors.count - 1) {
            let p0 = anchors[max(i - 1, 0)]
            let p1 = anchors[i]
            let p2 = anchors[i + 1]
            let p3 = anchors[min(i + 2, anchors.count - 1)]

            var sampled: [CGPoint] = []
            for step in 0...samplesPerSegment {
                let t = CGFloat(step) / CGFloat(samplesPerSegment)
                sampled.append(catmullRomPoint(t: t, p0: p0, p1: p1, p2: p2, p3: p3))
            }

            let isDashed = !displayPoints[i].hasData || !displayPoints[i + 1].hasData
            let color = isDashed ? Color.white.opacity(0.45) : Color.white
            segments.append(CurveSegment(points: sampled, isDashed: isDashed, color: color))
        }

        return segments
    }

    private func catmullRomPoint(
        t: CGFloat,
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        p3: CGPoint
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )

        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )

        return CGPoint(x: x, y: y)
    }

    private func axisLabel(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: Int(value.rounded()))) ?? "\(Int(value.rounded()))"
    }

    private func yAxisTicks(maxValue: Double) -> [Double] {
        guard maxValue > 0 else { return [] }

        let roughStep = maxValue / 4.0
        let magnitude = pow(10.0, floor(log10(max(roughStep, 1))))
        let normalized = roughStep / magnitude

        let stepBase: Double
        if normalized <= 1.5 {
            stepBase = 1
        } else if normalized <= 3 {
            stepBase = 2
        } else if normalized <= 7 {
            stepBase = 5
        } else {
            stepBase = 10
        }

        let step = stepBase * magnitude
        guard step > 0 else { return [] }

        let topTick = floor(maxValue / step) * step
        guard topTick >= step else { return [] }

        var ticks: [Double] = []
        var tick = step
        while tick <= topTick + 0.0001 {
            ticks.append(tick)
            tick += step
        }
        return ticks.reversed()
    }
}

private extension TrendChartView {
    static let labelDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()
}

private struct DisplayPoint: Identifiable {
    let date: Date
    let count: Double
    let hasData: Bool

    var id: String { "\(date.timeIntervalSince1970)-\(count)-\(hasData)" }
}

private struct CurveSegment {
    let points: [CGPoint]
    let isDashed: Bool
    let color: Color
}
