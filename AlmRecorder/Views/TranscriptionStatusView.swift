import SwiftUI

/// Animated pulsing icon for status indication
struct PulsingIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        // Static icon — the surrounding progress bar / spinner already signals activity, so a
        // perpetual pulse here was just noise.
        Image(systemName: systemName)
            .font(.title2)
            .foregroundColor(color)
    }
}

/// A view that shows detailed transcription status
struct TranscriptionStatusView: View {
    let status: String
    let progress: Double
    let isTranscribing: Bool
    let memoryUsage: Double = 0.0 // Optional memory usage in MB
    
    var body: some View {
        VStack(spacing: 12) {
            // Icon based on status
            statusIcon
            
            // Status text
            Text(status)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 200)
            
            // Progress bar
            if isTranscribing && progress > 0 {
                ProgressView(value: progress)
                    .frame(width: 150)
                    .tint(progressColor)
            }
            
            // Memory usage indicator
            if memoryUsage > 0 && isTranscribing {
                MemoryUsageView(memoryUsage: memoryUsage)
            }
        }
        .padding()
        .cardSurface(cornerRadius: 12)
        .shadow(radius: 4)
        .animation(.easeInOut(duration: 0.3), value: status)
    }
    
    private var statusIcon: some View {
        Group {
            if status.contains("Error") {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.red)
            } else if status.contains("Completed") {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
            } else if status.contains("Converting") {
                PulsingIcon(systemName: "waveform.badge.magnifyingglass", color: .blue)
            } else if status.contains("Running AI") {
                PulsingIcon(systemName: "brain", color: .purple)
            } else if status.contains("Checking") || status.contains("Validating") {
                PulsingIcon(systemName: "checkmark.shield", color: .orange)
            } else if status.contains("Processing") {
                PulsingIcon(systemName: "doc.text.magnifyingglass", color: .indigo)
            } else if status.contains("embedding") || status.contains("Embedding") {
                PulsingIcon(systemName: "brain", color: .orange)
            } else if status.contains("utterance") || status.contains("Utterance") {
                PulsingIcon(systemName: "text.alignleft", color: .cyan)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
    
    private var progressColor: Color {
        if progress < 0.3 {
            return .orange
        } else if progress < 0.7 {
            return .blue
        } else {
            return .green
        }
    }
}

/// Inline transcription status for list rows
struct InlineTranscriptionStatus: View {
    let status: String
    let progress: Double
    
    var body: some View {
        HStack(spacing: 6) {
            // Mini progress indicator
            if progress > 0 && progress < 1.0 {
                CircularProgressView(progress: progress)
                    .frame(width: 16, height: 16)
            } else if status.contains("Error") {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            } else if status.contains("Completed") {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            
            // Status text
            Text(status)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

/// Circular progress indicator
struct CircularProgressView: View {
    let progress: Double
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)
            
            Circle()
                .trim(from: 0, to: progress)
                .stroke(progressColor, lineWidth: 2)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
    
    private var progressColor: Color {
        if progress < 0.3 {
            return .orange
        } else if progress < 0.7 {
            return .blue
        } else {
            return .green
        }
    }
}
