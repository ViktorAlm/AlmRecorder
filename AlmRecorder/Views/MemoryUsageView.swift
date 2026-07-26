import SwiftUI

/// View that displays current memory usage
struct MemoryUsageView: View {
    let memoryUsage: Double // in MB
    
    var body: some View {
        Label {
            Text("\(String(format: "%.1f", memoryUsage)) MB")
                .foregroundColor(.secondary)
        } icon: {
            Image(systemName: "memorychip")
                .foregroundColor(memoryColor)
        }
        .font(.caption2)
    }
    
    private var memoryColor: Color {
        if memoryUsage < 500 {
            return .green
        } else if memoryUsage < 1000 {
            return .orange
        } else {
            return .red
        }
    }
    
}

/// Detailed memory status card
struct MemoryStatusCard: View {
    let memoryUsage: Double
    let context: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Memory Usage", systemImage: "memorychip")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(context)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("\(String(format: "%.1f", memoryUsage)) MB")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(memoryColor)
                
                Spacer()
                
                // Memory bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(memoryColor)
                            .frame(width: min(geometry.size.width * (memoryUsage / 2000), geometry.size.width), height: 8)
                            .animation(.easeInOut(duration: 0.3), value: memoryUsage)
                    }
                }
                .frame(width: 100, height: 8)
            }
            
            if memoryUsage > 1000 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    
                    Text("High memory usage detected")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .cardSurface(cornerRadius: 12)
        .shadow(radius: 2)
    }
    
    private var memoryColor: Color {
        if memoryUsage < 500 {
            return .green
        } else if memoryUsage < 1000 {
            return .orange
        } else {
            return .red
        }
    }
}
