import SwiftUI
import Charts

/// Recordings-per-day bar chart for the dashboard (zero-filled buckets keep the axis
/// continuous even on quiet weeks).
struct DashboardActivityChart: View {
    let data: [GRDBRecordingRepository.DailyActivityBucket]

    private var maxCount: Int { data.map(\.count).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Text("Last 28 days")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            chart
                .frame(height: 120)
                .overlay {
                    if maxCount == 0 {
                        Text("No recordings in this period")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
        }
        .padding(16)
        .cardSurface(cornerRadius: CardRadius.card)
    }

    private var chart: some View {
        Chart(data) { bucket in
            BarMark(
                x: .value("Day", bucket.day, unit: .day),
                y: .value("Recordings", bucket.count)
            )
            .foregroundStyle(Color.blue.gradient)
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Sparse data: keep a stable axis so one recording doesn't render a full-height bar.
        .chartYScale(domain: 0...max(3, maxCount))
    }
}
