import SwiftUI
import AlmRecorderEvaluationKit
import UniformTypeIdentifiers

struct PromptLabView: View {
    @ObservedObject private var labState = PromptLabState.shared
    @ObservedObject private var tester = VoxtralPromptTester.shared
    @ObservedObject private var appState = AppState.shared
    
    var body: some View {
        HSplitView {
            // Left panel - Controls and config list
            controlPanel
                .frame(minWidth: 300, maxWidth: 400)
            
            // Right panel - Results
            if labState.comparisonMode && !tester.results.isEmpty {
                comparisonView
            } else {
                resultsView
            }
        }
    }
    
    private var controlPanel: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Label("Prompt Lab", systemImage: "flask.fill")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Test different prompt strategies")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let configurationError = tester.configurationError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(configurationError)
                            .font(.caption)
                            .foregroundColor(.orange)
                        Button("Reload local configurations") {
                            tester.reloadLocalConfigurations()
                        }
                        .buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Audio file selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test Audio")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text(audioFileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button("Select") {
                            labState.showingFilePicker = true
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
                
                // Chunk settings
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max Chunks")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if labState.maxChunks == 0 {
                            Text("All")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                        } else {
                            Text("\(labState.maxChunks)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Button("1") {
                            labState.maxChunks = 1
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(labState.maxChunks == 1 ? .blue : .primary)
                        
                        Button("3") {
                            labState.maxChunks = 3
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(labState.maxChunks == 3 ? .blue : .primary)
                        
                        Button("5") {
                            labState.maxChunks = 5
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(labState.maxChunks == 5 ? .blue : .primary)
                        
                        Button("All") {
                            labState.maxChunks = 0
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(labState.maxChunks == 0 ? .blue : .primary)
                        
                        Spacer()
                        
                        Stepper("", value: $labState.maxChunks, in: 0...20)
                            .labelsHidden()
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    
                    Text(labState.maxChunks == 0 ? "Process all audio chunks" : 
                         labState.maxChunks == 1 ? "Process first chunk only" :
                         "Process first \(labState.maxChunks) chunks")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Model selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Model", selection: $labState.selectedModel) {
                        ForEach(Array(VoxtralConfiguration.models.keys.sorted()), id: \.self) { modelKey in
                            if let model = VoxtralConfiguration.models[modelKey] {
                                Text(model.name)
                                    .tag(modelKey)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    
                    // Show model size
                    if let model = VoxtralConfiguration.models[labState.selectedModel] {
                        Text("\(String(format: "%.1f", model.sizeGB)) GB")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Advanced Settings Toggle
                DisclosureGroup(
                    isExpanded: $labState.showAdvancedSettings,
                    content: {
                        VStack(alignment: .leading, spacing: 12) {
                            // Temperature
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Temperature")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.2f", labState.temperature))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundColor(.blue)
                                }
                                Slider(value: $labState.temperature, in: 0...1, step: 0.05)
                                Text("Controls randomness (0=deterministic, 1=creative)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Top-K
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Top-K")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(labState.topK)")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundColor(.blue)
                                }
                                Slider(value: Binding(
                                    get: { Double(labState.topK) },
                                    set: { labState.topK = Int($0) }
                                ), in: 1...100, step: 1)
                                Text("Number of top tokens to consider")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Top-P (optional)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Toggle("Top-P", isOn: $labState.useTopP)
                                        .font(.caption)
                                    if labState.useTopP {
                                        Spacer()
                                        Text(String(format: "%.2f", labState.topP ?? 0.9))
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundColor(.blue)
                                    }
                                }
                                if labState.useTopP {
                                    Slider(value: Binding(
                                        get: { labState.topP ?? 0.9 },
                                        set: { labState.topP = $0 }
                                    ), in: 0...1, step: 0.05)
                                    Text("Cumulative probability cutoff")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            // Seed (optional)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Toggle("Seed", isOn: $labState.useSeed)
                                        .font(.caption)
                                    if labState.useSeed {
                                        Spacer()
                                        TextField("Seed", value: Binding(
                                            get: { labState.seed ?? 42 },
                                            set: { labState.seed = $0 }
                                        ), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    }
                                }
                                if labState.useSeed {
                                    Text("For reproducible results")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            // Max Tokens
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Max Tokens")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    TextField("", value: $labState.maxTokens, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                                Text("Maximum output length")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Reset to defaults button
                            Button(action: {
                                labState.temperature = 0.0
                                labState.topK = 1
                                labState.useTopP = false
                                labState.topP = nil
                                labState.useSeed = false
                                labState.seed = nil
                                labState.maxTokens = 15000
                                labState.contextKeep = 512
                            }) {
                                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 8)
                    },
                    label: {
                        HStack {
                            Label("Advanced Settings", systemImage: "slider.horizontal.3")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            // Show compact settings display
                            if !labState.showAdvancedSettings {
                                Text(labState.createRunSettings().compactDisplay)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                    }
                )
                .padding(.vertical, 4)
                
                // Action buttons
                HStack(spacing: 8) {
                    Button(action: runAllTests) {
                        Label("Queue All Tests", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tester.selectedAudioPath.isEmpty)
                    
                    Button(action: runSelectedTest) {
                        Label("Queue Selected", systemImage: "play")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(labState.selectedConfig == nil || tester.selectedAudioPath.isEmpty)
                }
                
                // Queue status
                if !labState.testJobIds.isEmpty {
                    let pendingCount = labState.testJobIds.filter { jobId in
                        appState.queueManager.jobs.first(where: { $0.id == jobId })?.status == .pending
                    }.count
                    
                    let processingCount = labState.testJobIds.filter { jobId in
                        appState.queueManager.jobs.first(where: { $0.id == jobId })?.status == .processing
                    }.count
                    
                    let completedCount = labState.testJobIds.filter { jobId in
                        appState.queueManager.jobs.first(where: { $0.id == jobId })?.status == .completed
                    }.count
                    
                    HStack(spacing: 12) {
                        if pendingCount > 0 {
                            Label("\(pendingCount) pending", systemImage: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if processingCount > 0 {
                            Label("\(processingCount) processing", systemImage: "gearshape.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        if completedCount > 0 {
                            Button(action: { checkForCompletedResults() }) {
                                Label("\(completedCount) completed", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                            .help("Click to check for completed results")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
                
                // View queue button
                if !labState.testJobIds.isEmpty {
                    Button(action: { appState.showQueuePanel = true }) {
                        Label("View Queue", systemImage: "tray.full")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            
            Divider()
            
            // Configuration list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(PromptTestConfig.TestGroup.allCases, id: \.self) { group in
                        Section {
                            ForEach(tester.testConfigs.filter { $0.group == group }, id: \.id) { config in
                                ConfigRow(
                                    config: config,
                                    isSelected: labState.selectedConfig?.id == config.id,
                                    result: tester.results.first { $0.configId == config.id }
                                ) {
                                    labState.selectedConfig = config
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.rawValue)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            
            Divider()
            
            // Bottom toolbar
            HStack {
                Toggle("Compare", isOn: $labState.comparisonMode)
                    .toggleStyle(.button)
                    .disabled(tester.results.count < 2)
                
                Spacer()
                
                Menu {
                    Button("Export as CSV") {
                        exportResults(format: .csv)
                    }
                    Button("Export as Markdown") {
                        exportResults(format: .markdown)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(tester.results.isEmpty)
                
                Button(action: clearResults) {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(tester.results.isEmpty)
            }
            .padding()
        }
        .fileImporter(
            isPresented: $labState.showingFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result,
               let url = urls.first {
                tester.selectedAudioPath = url.path
            }
        }
    }
    
    private var resultsView: some View {
        VStack(spacing: 0) {
            // Results header
            HStack {
                Text("Results")
                    .font(.headline)
                
                Spacer()
                
                if let selected = labState.selectedConfig,
                   let result = tester.results.first(where: { $0.configId == selected.id }) {
                    HStack(spacing: 12) {
                        Label("\(result.wordCount) words", systemImage: "text.word.spacing")
                        Label(String(format: "%.2fs", result.processingTime), systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            
            Divider()
            
            // Results content
            if let selected = labState.selectedConfig,
               let result = tester.results.first(where: { $0.configId == selected.id }) {
                resultDetailView(result)
            } else if !tester.results.isEmpty {
                // Show summary
                resultsSummaryView
            } else {
                // Empty state
                VStack {
                    Spacer()
                    Image(systemName: "flask")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("Run tests to see results")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }
    
    private func resultDetailView(_ result: PromptTestResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Test Configuration Info
                if let config = tester.testConfigs.first(where: { $0.id == result.configId }) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Test Configuration", systemImage: "gearshape.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                // Group badge
                                Text(config.group.rawValue)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(groupColor(for: config.group).opacity(0.2))
                                    .foregroundColor(groupColor(for: config.group))
                                    .cornerRadius(4)
                                
                                if config.isSpecialToken {
                                    Text("SPECIAL TOKEN")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.2))
                                        .foregroundColor(.purple)
                                        .cornerRadius(4)
                                }
                            }
                            
                            Text(config.description)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .padding(.vertical, 2)
                        }
                    }
                }
                
                // Chat-style interaction view
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Interaction", systemImage: "bubble.left.and.bubble.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // System/Prompt message
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "cpu")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    Text("System Prompt")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.blue)
                                }
                                
                                Text(result.prompt.isEmpty ? "[Empty Prompt]" : result.prompt)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            Spacer()
                        }
                        
                        // Audio input indicator
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text("[Audio Input]")
                                    .font(.caption)
                                    .italic()
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)
                            Spacer()
                        }
                        
                        // Model response
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack {
                                    Text("Model Response")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.green)
                                    Image(systemName: "brain")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                
                                if let error = result.error {
                                    HStack {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                        Text(error)
                                            .foregroundColor(.red)
                                    }
                                    .padding(10)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                    )
                                } else {
                                    Text(result.transcript.isEmpty ? "[No Output]" : result.transcript)
                                        .textSelection(.enabled)
                                        .padding(10)
                                        .background(Color.green.opacity(0.1))
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                                        )
                                        .frame(maxWidth: 500, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
                
                // Metrics
                GroupBox {
                    HStack(spacing: 20) {
                        MetricView(label: "Words", value: "\(result.wordCount)")
                        MetricView(label: "Characters", value: "\(result.characterCount)")
                        MetricView(label: "Time", value: String(format: "%.2fs", result.processingTime))
                        if result.tokenSequence != nil {
                            MetricView(label: "Tokens", value: "\(result.tokenCount)")
                        }
                    }
                }
                
                // Token sequence if available
                if let tokenSeq = result.tokenSequence {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Token Sequence", systemImage: "number")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                // Check for special tokens
                                if tokenSeq.contains("[TRANSCRIBE]") || 
                                   tokenSeq.contains("[INST]") || 
                                   tokenSeq.contains("[BOS]") {
                                    Label("Contains special tokens", systemImage: "star.fill")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            
                            ScrollView(.horizontal) {
                                Text(tokenSeq)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(4)
                            }
                            
                            // Token statistics
                            HStack(spacing: 16) {
                                if let tokenCount = countTokens(in: tokenSeq) {
                                    Label("\(tokenCount) tokens", systemImage: "number.square")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                
                                if tokenSeq.contains("lang:") {
                                    Label("Language tag present", systemImage: "globe")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private var resultsSummaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Test Summary")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal)
                    .padding(.top)
                
                // Statistics
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Total Tests", systemImage: "flask")
                            Spacer()
                            Text("\(tester.results.count)")
                                .fontWeight(.medium)
                        }
                        
                        HStack {
                            Label("Successful", systemImage: "checkmark.circle")
                                .foregroundColor(.green)
                            Spacer()
                            Text("\(tester.results.filter { $0.error == nil }.count)")
                                .fontWeight(.medium)
                        }
                        
                        HStack {
                            Label("Failed", systemImage: "xmark.circle")
                                .foregroundColor(.red)
                            Spacer()
                            Text("\(tester.results.filter { $0.error != nil }.count)")
                                .fontWeight(.medium)
                        }
                        
                        Divider()
                        
                        if let fastest = tester.results.filter({ $0.error == nil }).min(by: { $0.processingTime < $1.processingTime }) {
                            HStack {
                                Label("Fastest", systemImage: "hare")
                                    .foregroundColor(.blue)
                                Spacer()
                                Text("\(fastest.configName) (\(String(format: "%.2fs", fastest.processingTime)))")
                                    .font(.caption)
                            }
                        }
                        
                        if let mostWords = tester.results.max(by: { $0.wordCount < $1.wordCount }) {
                            HStack {
                                Label("Most Words", systemImage: "text.word.spacing")
                                    .foregroundColor(.purple)
                                Spacer()
                                Text("\(mostWords.configName) (\(mostWords.wordCount))")
                                    .font(.caption)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                
                // Results by group
                ForEach(PromptTestConfig.TestGroup.allCases, id: \.self) { group in
                    let groupResults = tester.results.filter { result in
                        tester.testConfigs.first { $0.id == result.configId }?.group == group
                    }
                    
                    if !groupResults.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(group.rawValue, systemImage: groupIcon(for: group))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(groupColor(for: group))
                                    
                                    Spacer()
                                    
                                    Text("\(groupResults.filter { $0.error == nil }.count)/\(groupResults.count) passed")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                
                                Divider()
                                
                                ForEach(groupResults, id: \.id) { result in
                                    HStack {
                                        if let config = tester.testConfigs.first(where: { $0.id == result.configId }) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(config.name)
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                
                                                Text("Prompt: \(config.prompt.isEmpty ? "[empty]" : String(config.prompt.prefix(50)))")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 8) {
                                            Text("\(result.wordCount) words")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            
                                            Text(String(format: "%.1fs", result.processingTime))
                                                .font(.caption2)
                                                .monospacedDigit()
                                                .foregroundColor(.secondary)
                                            
                                            Image(systemName: result.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundColor(result.error == nil ? .green : .red)
                                                .font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Results table
                GroupBox {
                    Table(tester.results) {
                        TableColumn("Config") { result in
                            Text(result.configName)
                                .fontWeight(result.error == nil ? .regular : .light)
                                .foregroundColor(result.error == nil ? .primary : .secondary)
                        }
                        .width(min: 120)
                        
                        TableColumn("Words") { result in
                            Text("\(result.wordCount)")
                                .monospacedDigit()
                        }
                        .width(60)
                        
                        TableColumn("Time") { result in
                            Text(String(format: "%.2fs", result.processingTime))
                                .monospacedDigit()
                        }
                        .width(60)
                        
                        TableColumn("Status") { result in
                            Image(systemName: result.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result.error == nil ? .green : .red)
                        }
                        .width(50)
                    }
                    .frame(minHeight: 200)
                }
                .padding(.horizontal)
            }
        }
    }
    
    private var comparisonView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Comparison View")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal)
                    .padding(.top)
                
                // Select baseline
                if labState.baselineResult == nil {
                    GroupBox {
                        Picker("Baseline", selection: $labState.baselineResult) {
                            Text("Select baseline").tag(nil as PromptTestResult?)
                            ForEach(tester.results.filter { $0.error == nil }) { result in
                                Text(result.configName).tag(result as PromptTestResult?)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                
                if let baseline = labState.baselineResult {
                    // Show comparisons
                    ForEach(tester.results.filter { $0.id != baseline.id }) { result in
                        ComparisonRow(baseline: baseline, result: result)
                            .padding(.horizontal)
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Views
    
    private var audioFileName: String {
        if tester.selectedAudioPath.isEmpty {
            return "No file selected"
        }
        return URL(fileURLWithPath: tester.selectedAudioPath).lastPathComponent
    }
    
    // Helper function to count tokens in a sequence string
    private func countTokens(in sequence: String) -> Int? {
        // Try to parse token sequence - could be in various formats:
        // "[1, 2, 3]" or "1 2 3" or "1,2,3"
        let cleaned = sequence.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let components = cleaned.components(separatedBy: CharacterSet(charactersIn: ", "))
        let tokens = components.compactMap { Int($0) }
        return tokens.isEmpty ? nil : tokens.count
    }
    
    // Helper function to get color for test group
    private func groupColor(for group: PromptTestConfig.TestGroup) -> Color {
        switch group {
        case .specialTokens:
            return .purple
        case .textPrompts:
            return .blue
        case .instructionFormat:
            return .orange
        case .verbatimVariants:
            return .green
        case .contextHistory:
            return .pink
        }
    }
    
    // Helper function to get icon for test group
    private func groupIcon(for group: PromptTestConfig.TestGroup) -> String {
        switch group {
        case .specialTokens:
            return "number.square.fill"
        case .textPrompts:
            return "text.bubble.fill"
        case .instructionFormat:
            return "text.badge.star"
        case .verbatimVariants:
            return "doc.text.fill"
        case .contextHistory:
            return "clock.arrow.circlepath"
        }
    }
    
    // MARK: - Actions
    
    private func runAllTests() {
        labState.isRunningTest = true
        
        Task {
            // Call the async function directly - it will handle the background processing
            let runSettings = labState.createRunSettings()
            let jobIds = await tester.submitAllTestsToQueue(modelKey: labState.selectedModel, runSettings: runSettings)
            
            await MainActor.run {
                labState.testJobIds = Set(jobIds)
                labState.isRunningTest = false
                
                // Start monitoring for results
                startMonitoringJobs()
            }
        }
    }
    
    private func runSelectedTest() {
        guard let config = labState.selectedConfig else { return }
        
        let runSettings = labState.createRunSettings(prompt: config.prompt)
        if let jobId = tester.submitTestToQueue(config, modelKey: labState.selectedModel, runSettings: runSettings) {
            labState.testJobIds.insert(jobId)
            
            // Start monitoring for results
            startMonitoringJobs()
        }
    }
    
    private func startMonitoringJobs() {
        Task {
            // Monitor job completion and update results
            for jobId in labState.testJobIds {
                Task {
                    var checkCount = 0
                    while checkCount < 600 { // Max 5 minutes of checking (600 * 0.5s)
                        checkCount += 1
                        
                        if let job = appState.queueManager.jobs.first(where: { $0.id == jobId }) {
                            if job.status == .completed {
                                print("[PromptLabView] Job completed: \(job.fileName) with ID: \(jobId)")
                                
                                // Extract result from completed job
                                if let config = job.promptConfig,
                                   let transcript = job.transcript {
                                    
                                    print("[PromptLabView] Extracting result for config: \(config.name)")
                                    
                                    // Calculate processing time
                                    let processingTime: TimeInterval
                                    if let startedAt = job.startedAt, let completedAt = job.completedAt {
                                        processingTime = completedAt.timeIntervalSince(startedAt)
                                    } else {
                                        processingTime = 0
                                    }
                                    
                                    let result = PromptTestResult(
                                        configId: config.id,
                                        configName: config.name,
                                        prompt: config.prompt,
                                        transcript: transcript,
                                        processingTime: processingTime,
                                        tokenCount: 0,  // TODO: Extract from job
                                        characterCount: transcript.count,
                                        wordCount: transcript.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
                                        tokenSequence: nil,  // TODO: Extract if available
                                        error: nil,
                                        timestamp: job.completedAt ?? Date()
                                    )
                                    
                                    await MainActor.run {
                                        print("[PromptLabView] Adding result to tester.results for: \(config.name)")
                                        // Replace or add result
                                        if let index = tester.results.firstIndex(where: { $0.configId == config.id }) {
                                            tester.results[index] = result
                                        } else {
                                            tester.results.append(result)
                                        }
                                        print("[PromptLabView] Total results now: \(tester.results.count)")
                                        
                                        // Auto-select the first completed result if nothing is selected
                                        if labState.selectedConfig == nil && tester.results.count == 1 {
                                            labState.selectedConfig = config
                                            print("[PromptLabView] Auto-selected first result: \(config.name)")
                                        }
                                    }
                                } else {
                                    print("[PromptLabView] Warning: Job completed but missing promptConfig or transcript")
                                }
                                break
                            } else if job.status == .failed {
                                print("[PromptLabView] Job failed: \(job.fileName) with ID: \(jobId)")
                                
                                // Handle failed job
                                if let config = job.promptConfig {
                                    print("[PromptLabView] Recording failed result for: \(config.name)")
                                    
                                    // Calculate processing time
                                    let processingTime: TimeInterval
                                    if let startedAt = job.startedAt, let completedAt = job.completedAt {
                                        processingTime = completedAt.timeIntervalSince(startedAt)
                                    } else {
                                        processingTime = 0
                                    }
                                    
                                    let result = PromptTestResult(
                                        configId: config.id,
                                        configName: config.name,
                                        prompt: config.prompt,
                                        transcript: "",
                                        processingTime: processingTime,
                                        tokenCount: 0,
                                        characterCount: 0,
                                        wordCount: 0,
                                        tokenSequence: nil,
                                        error: job.error ?? "Test failed",
                                        timestamp: job.completedAt ?? Date()
                                    )
                                    
                                    await MainActor.run {
                                        print("[PromptLabView] Adding failed result to tester.results for: \(config.name)")
                                        // Replace or add result
                                        if let index = tester.results.firstIndex(where: { $0.configId == config.id }) {
                                            tester.results[index] = result
                                        } else {
                                            tester.results.append(result)
                                        }
                                        print("[PromptLabView] Total results now: \(tester.results.count)")
                                    }
                                }
                                break
                            }
                        } else {
                            print("[PromptLabView] Warning: Job ID \(jobId) not found in queue manager")
                        }
                        
                        try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5 seconds
                    }
                    
                    if checkCount >= 600 {
                        print("[PromptLabView] Warning: Stopped monitoring job \(jobId) after timeout")
                    }
                }
            }
        }
    }
    
    private func clearResults() {
        tester.results.removeAll()
        labState.baselineResult = nil
        labState.testJobIds.removeAll()
    }
    
    private func checkForCompletedResults() {
        // Manually check for any completed jobs that might have been missed
        for jobId in labState.testJobIds {
            if let job = appState.queueManager.jobs.first(where: { $0.id == jobId }),
               job.status == .completed,
               let config = job.promptConfig,
               !tester.results.contains(where: { $0.configId == config.id }) {
                
                // Extract result
                if let transcript = job.transcript {
                    let processingTime: TimeInterval
                    if let startedAt = job.startedAt, let completedAt = job.completedAt {
                        processingTime = completedAt.timeIntervalSince(startedAt)
                    } else {
                        processingTime = 0
                    }
                    
                    let result = PromptTestResult(
                        configId: config.id,
                        configName: config.name,
                        prompt: config.prompt,
                        transcript: transcript,
                        processingTime: processingTime,
                        tokenCount: 0,
                        characterCount: transcript.count,
                        wordCount: transcript.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
                        tokenSequence: nil,
                        error: nil,
                        timestamp: job.completedAt ?? Date()
                    )
                    
                    tester.results.append(result)
                    
                    // Auto-select if this is the first result
                    if labState.selectedConfig == nil && tester.results.count == 1 {
                        labState.selectedConfig = config
                    }
                }
            }
        }
    }
    
    private func exportResults(format: ExportFormat) {
        let content: String
        let filename: String
        
        switch format {
        case .csv:
            content = tester.exportResultsAsCSV()
            filename = "voxtral_prompt_test_\(Date().timeIntervalSince1970).csv"
        case .markdown:
            content = tester.exportResultsAsMarkdown()
            filename = "voxtral_prompt_test_\(Date().timeIntervalSince1970).md"
        }
        
        do {
            let url = try EvaluationWorkspace.current().artifactURL(fileName: filename)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            tester.reportLocalConfigurationError(error)
        }
    }
    
    enum ExportFormat {
        case csv, markdown
    }
}

// MARK: - Supporting Views

struct ConfigRow: View {
    let config: PromptTestConfig
    let isSelected: Bool
    let result: PromptTestResult?
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(config.name)
                            .fontWeight(.medium)
                        
                        if config.isSpecialToken {
                            Text("TOKEN")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                    
                    Text(config.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if let result = result {
                    HStack(spacing: 4) {
                        // HuggingFace compatibility indicator
                        if let tokenSeq = result.tokenSequence,
                           tokenSeq.contains("[TRANSCRIBE]") || 
                           tokenSeq.contains("[BOS]") ||
                           tokenSeq.contains("[INST]") {
                            Image(systemName: "star.fill")
                                .foregroundColor(.orange)
                                .font(.caption2)
                                .help("HuggingFace-compatible tokens detected")
                        }
                        
                        if result.error != nil {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

struct MetricView: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}

struct ComparisonRow: View {
    let baseline: PromptTestResult
    let result: PromptTestResult
    
    private var wordDiff: Int {
        result.wordCount - baseline.wordCount
    }
    
    private var timeDiff: TimeInterval {
        result.processingTime - baseline.processingTime
    }
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(result.configName)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    if result.error != nil {
                        Label("Failed", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                
                HStack(spacing: 20) {
                    // Word count comparison
                    HStack {
                        Text("Words:")
                        Text("\(result.wordCount)")
                            .monospacedDigit()
                        if wordDiff != 0 {
                            Text("(\(wordDiff > 0 ? "+" : "")\(wordDiff))")
                                .font(.caption)
                                .foregroundColor(wordDiff > 0 ? .green : .red)
                        }
                    }
                    
                    // Time comparison
                    HStack {
                        Text("Time:")
                        Text(String(format: "%.2fs", result.processingTime))
                            .monospacedDigit()
                        if abs(timeDiff) > 0.01 {
                            Text(String(format: "(%+.2fs)", timeDiff))
                                .font(.caption)
                                .foregroundColor(timeDiff < 0 ? .green : .red)
                        }
                    }
                }
                .font(.caption)
                
                // Transcript preview
                if result.transcript != baseline.transcript {
                    Text("Different transcript")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                // Token sequence comparison
                if let resultTokens = result.tokenSequence,
                   let baselineTokens = baseline.tokenSequence {
                    if resultTokens != baselineTokens {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Token Sequence Difference")
                                .font(.caption2)
                                .foregroundColor(.purple)
                            
                            // Show first few tokens of each
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Baseline:")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(String(baselineTokens.prefix(100)))
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Current:")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(String(resultTokens.prefix(100)))
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } else {
                        Text("Same token sequence")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                } else if result.tokenSequence != nil || baseline.tokenSequence != nil {
                    Text("Token sequence only in one result")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
        }
    }
}
