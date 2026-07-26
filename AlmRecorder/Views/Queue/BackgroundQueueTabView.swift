import SwiftUI

/// Reusable list UI for the three simple background queues (embedding / insights / cleanup).
/// Unlike the transcription queue these jobs are lightweight — no chunks/ETA/run-settings — so a
/// single row shows everything and there's no separate detail pane.
struct BackgroundQueueTabView<Job: BackgroundQueueJob>: View {
    let emptyIcon: String
    let pending: [Job]
    let active: [Job]
    let failed: [Job]
    let completed: [Job]
    /// Optional extra line under the title (e.g. cleanup's mode + outcome summary).
    var subtitle: (Job) -> String? = { _ in nil }
    var onRetry: ((Job) -> Void)?
    var onCancel: ((Job) -> Void)?
    var onClearCompleted: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            statsBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !active.isEmpty {
                        section(title: "Processing", icon: "gearshape.fill", color: .blue, jobs: active)
                    }
                    if !pending.isEmpty {
                        section(title: "Pending", icon: "clock", color: .secondary, jobs: pending)
                    }
                    if !failed.isEmpty {
                        section(title: "Failed", icon: "xmark.circle", color: .red, jobs: failed)
                    }
                    if !completed.isEmpty {
                        section(title: "Recently Completed", icon: "checkmark.circle", color: .green,
                                jobs: Array(completed.suffix(20)))
                    }
                    if pending.isEmpty && active.isEmpty && failed.isEmpty && completed.isEmpty {
                        emptyState
                    }
                }
                .padding()
            }
            if let onClearCompleted, !completed.isEmpty {
                Divider()
                HStack {
                    Button(action: onClearCompleted) {
                        Label("Clear Completed", systemImage: "trash")
                    }
                    Spacer()
                }
                .padding()
            }
        }
    }

    private var statsBar: some View {
        HStack(spacing: 20) {
            StatItem(label: "Pending", value: "\(pending.count)", color: .secondary)
            StatItem(label: "Active", value: "\(active.count)", color: .blue)
            StatItem(label: "Failed", value: "\(failed.count)", color: .red)
            StatItem(label: "Completed", value: "\(completed.count)", color: .green)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func section(title: String, icon: String, color: Color, jobs: [Job]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                Spacer()
                Text("\(jobs.count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .cornerRadius(4)
            }
            ForEach(jobs) { job in
                row(for: job)
            }
        }
    }

    private func row(for job: Job) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.displayStatus.icon)
                .foregroundColor(job.displayStatus.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.recordingTitle)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                if let subtitle = subtitle(job) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let error = job.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(relativeTime(job))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if job.retryCount > 0 {
                        Text("• \(job.retryCount) retr\(job.retryCount == 1 ? "y" : "ies")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if job.displayStatus == .processing {
                ProgressView().scaleEffect(0.6)
            }

            if job.displayStatus == .failed, let onRetry {
                Button(action: { onRetry(job) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry")
            }

            if (job.displayStatus == .pending || job.displayStatus == .processing), let onCancel {
                Button(action: { onCancel(job) }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .help("Cancel")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 60)
            Image(systemName: emptyIcon)
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.3))
            Text("Nothing queued")
                .font(.body)
                .foregroundColor(.secondary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    private func relativeTime(_ job: Job) -> String {
        let date = job.completedAt ?? job.startedAt ?? job.createdAt
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
