import SwiftUI

/// Full tag management view for creating, editing, and deleting tags
struct TagManagementView: View {
    @State private var tags: [(tag: Tag, count: Int)] = []
    @State private var newTagName = ""
    @State private var editingTag: Tag? = nil
    @State private var editName = ""
    @State private var tagPendingDeletion: Tag?
    @State private var tagPendingMCPHide: Tag?

    private let tagRepo = GRDBTagRepository()
    private let presetColors = ["#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FFEAA7", "#DDA0DD", "#98D8C8", "#F7DC6F"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tags")
                .font(.title2)
                .fontWeight(.semibold)

            // Create new tag
            HStack {
                TextField("New tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createTag() }

                Button("Create") { createTag() }
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            if tags.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No tags yet")
                        .foregroundColor(.secondary)
                    Text("Create tags to organize your recordings")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                List {
                    ForEach(tags, id: \.tag.id) { item in
                        HStack {
                            Circle()
                                .fill(Color(hex: item.tag.color ?? ""))
                                .frame(width: 12, height: 12)

                            if editingTag?.id == item.tag.id {
                                TextField("Tag name", text: $editName)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { saveEdit(item.tag) }

                                Button("Save") { saveEdit(item.tag) }
                                Button("Cancel") { editingTag = nil }
                            } else {
                                Text(item.tag.name)
                                    .font(.body)

                                if item.tag.hidesRecordingsFromMCP {
                                    Image(systemName: "network.slash")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .help("This tag hides its recordings from MCP")
                                }

                                Spacer()

                                Text("\(item.count) recordings")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Toggle(
                                    "Hide from MCP",
                                    isOn: Binding(
                                        get: { item.tag.hidesRecordingsFromMCP },
                                        set: {
                                            if $0 {
                                                tagPendingMCPHide = item.tag
                                            } else {
                                                setMCPPrivacy(for: item.tag, hides: false)
                                            }
                                        }
                                    )
                                )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("Treat every recording with this tag as nonexistent to MCP clients")

                                Button(action: { startEdit(item.tag) }) {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)

                                Button(action: { tagPendingDeletion = item.tag }) {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Delete tag")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding()
        .onAppear { loadTags() }
        .alert(
            "Delete tag?",
            isPresented: Binding(
                get: { tagPendingDeletion != nil },
                set: { if !$0 { tagPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { tagPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let tag = tagPendingDeletion else { return }
                tagPendingDeletion = nil
                deleteTag(tag)
            }
        } message: {
            let count = tags.first { $0.tag.id == tagPendingDeletion?.id }?.count ?? 0
            Text("“\(tagPendingDeletion?.name ?? "This tag")” will be removed from \(count) recording\(count == 1 ? "" : "s"). This cannot be undone.")
        }
        .alert(
            "Hide tagged recordings from MCP?",
            isPresented: Binding(
                get: { tagPendingMCPHide != nil },
                set: { if !$0 { tagPendingMCPHide = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { tagPendingMCPHide = nil }
            Button("Hide from MCP", role: .destructive) {
                guard let tag = tagPendingMCPHide else { return }
                tagPendingMCPHide = nil
                setMCPPrivacy(for: tag, hides: true)
            }
        } message: {
            let count = tags.first { $0.tag.id == tagPendingMCPHide?.id }?.count ?? 0
            Text("\(count) recording\(count == 1 ? "" : "s") will immediately become unavailable to every MCP client. The recordings remain available inside AlmRecorder.")
        }
    }

    private func loadTags() {
        do {
            tags = try tagRepo.getTagsWithCounts()
        } catch {
            print("[TagManagementView] Failed to load tags: \(error)")
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let color = presetColors.randomElement()
            _ = try tagRepo.createTag(name: name, color: color)
            newTagName = ""
            loadTags()
        } catch {
            print("[TagManagementView] Failed to create tag: \(error)")
        }
    }

    private func startEdit(_ tag: Tag) {
        editingTag = tag
        editName = tag.name
    }

    private func saveEdit(_ tag: Tag) {
        guard let id = tag.id else { return }
        let name = editName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try tagRepo.updateTag(id: id, name: name, color: tag.color)
            editingTag = nil
            loadTags()
        } catch {
            print("[TagManagementView] Failed to update tag: \(error)")
        }
    }

    private func deleteTag(_ tag: Tag) {
        guard let id = tag.id else { return }
        do {
            try tagRepo.deleteTag(id: id)
            loadTags()
        } catch {
            print("[TagManagementView] Failed to delete tag: \(error)")
        }
    }

    private func setMCPPrivacy(for tag: Tag, hides: Bool) {
        guard let id = tag.id else { return }
        do {
            try tagRepo.setHidesRecordingsFromMCP(id: id, hides: hides)
            loadTags()
        } catch {
            print("[TagManagementView] Failed to update MCP privacy: \(error)")
        }
    }

}
