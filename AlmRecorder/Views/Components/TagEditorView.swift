import SwiftUI

/// Inline tag editor for adding/removing tags on a recording
struct TagEditorView: View {
    let recordingId: Int64
    @State private var tags: [Tag] = []
    @State private var allTags: [Tag] = []
    @State private var showAddPopover = false
    @State private var newTagName = ""
    @State private var editingTag: Tag?
    @State private var editDescription = ""

    private let tagRepo = GRDBTagRepository()
    private let presetColors = ["#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FFEAA7", "#DDA0DD", "#98D8C8", "#F7DC6F"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.headline)

            FlowLayoutSimple(spacing: 6) {
                ForEach(tags, id: \.id) { tag in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorFromHex(tag.color))
                            .frame(width: 8, height: 8)
                        Button(action: { editingTag = tag; editDescription = tag.description ?? "" }) {
                            HStack(spacing: 3) {
                                Text(tag.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                if tag.hidesRecordingsFromMCP {
                                    Image(systemName: "network.slash")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Button(action: { removeTag(tag) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentSurface(in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                    .help((tag.description?.isEmpty == false) ? tag.description! : tag.name)
                }

                Button(action: { showAddPopover = true }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentSurface(in: Circle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: $showAddPopover) {
                    addTagPopover
                }
            }
        }
        .onAppear { loadTags() }
        .popover(item: $editingTag) { tag in
            editTagPopover(tag)
        }
    }

    private func editTagPopover(_ tag: Tag) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(colorFromHex(tag.color)).frame(width: 10, height: 10)
                Text(tag.name).font(.headline)
            }
            Text("Description")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("What this tag means", text: $editDescription)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveDescription(for: tag); editingTag = nil }
            if tag.hidesRecordingsFromMCP {
                Label("Recordings with this tag are hidden from MCP", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Save") {
                    saveDescription(for: tag)
                    editingTag = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func saveDescription(for tag: Tag) {
        guard let id = tag.id else { return }
        let trimmed = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try tagRepo.updateTagDescription(id: id, description: trimmed.isEmpty ? nil : trimmed)
            loadTags()
        } catch {
            print("[TagEditorView] Failed to save tag description: \(error)")
        }
    }

    private var addTagPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Tag")
                .font(.headline)

            HStack {
                TextField("New tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createAndAddTag() }

                Button("Add") { createAndAddTag() }
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !availableTags.isEmpty {
                Divider()
                Text("Existing tags")
                    .font(.caption)
                    .foregroundColor(.secondary)

                FlowLayoutSimple {
                    ForEach(availableTags, id: \.id) { tag in
                        Button(action: { addExistingTag(tag) }) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(colorFromHex(tag.color))
                                    .frame(width: 8, height: 8)
                                Text(tag.name)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var availableTags: [Tag] {
        let assignedIds = Set(tags.compactMap { $0.id })
        return allTags.filter { tag in
            guard let id = tag.id else { return false }
            return !assignedIds.contains(id)
        }
    }

    private func loadTags() {
        do {
            tags = try tagRepo.getTagsForRecording(recordingId: recordingId)
            allTags = try tagRepo.getAllTags()
        } catch {
            print("[TagEditorView] Failed to load tags: \(error)")
        }
    }

    private func removeTag(_ tag: Tag) {
        guard let tagId = tag.id else { return }
        do {
            try tagRepo.removeTagFromRecording(recordingId: recordingId, tagId: tagId)
            tags.removeAll { $0.id == tagId }
        } catch {
            print("[TagEditorView] Failed to remove tag: \(error)")
        }
    }

    private func addExistingTag(_ tag: Tag) {
        guard let tagId = tag.id else { return }
        do {
            try tagRepo.addTagToRecording(recordingId: recordingId, tagId: tagId)
            tags.append(tag)
        } catch {
            print("[TagEditorView] Failed to add tag: \(error)")
        }
    }

    private func createAndAddTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let color = presetColors.randomElement()
            let tagId = try tagRepo.createTag(name: name, color: color)
            let tag = Tag(id: tagId, name: name, color: color)
            try tagRepo.addTagToRecording(recordingId: recordingId, tagId: tagId)
            tags.append(tag)
            allTags.append(tag)
            newTagName = ""
        } catch {
            print("[TagEditorView] Failed to create tag: \(error)")
        }
    }

    private func colorFromHex(_ hex: String?) -> Color {
        guard let hex = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              hex.count == 6,
              let rgb = UInt64(hex, radix: 16) else {
            return .gray
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

/// Simple flow layout for tags
struct FlowLayoutSimple: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
