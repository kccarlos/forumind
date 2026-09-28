import SwiftUI

/// Settings › Forums: reorder and unpin pinned forums, pin or remove the
/// others, add a forum by address.
struct SettingsForumsPage: View {
    @ObservedObject var app: AppModel
    @State private var removing: Forum?
    @State private var address = ""
    @State private var pinNew = true
    @State private var adding = false
    @State private var addError: String?
    @State private var addedName: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        List {
            Section {
                if app.pinnedForums.isEmpty {
                    Text("Pin forums to keep them at the top of the Forums screen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.pinnedForums) { forum in
                        forumRow(forum)
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) { removing = forum }
                                Button("Unpin") { withAnimation { app.unpin(forum) } }
                                    .tint(.orange)
                            }
                    }
                    .onMove { source, destination in
                        app.movePinned(fromOffsets: source, toOffset: destination)
                    }
                }
            } header: {
                Text("Pinned")
            } footer: {
                if app.pinnedForums.count > 1 {
                    Text("Tap Edit to change the order.")
                }
            }

            if !app.recentForums.isEmpty {
                Section {
                    ForEach(app.recentForums) { forum in
                        forumRow(forum)
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) { removing = forum }
                                Button("Pin") { withAnimation { app.pin(forum) } }
                                    .tint(DCTheme.brandBlue)
                            }
                    }
                } header: {
                    Text("Other forums")
                } footer: {
                    Text("Forums you’ve visited. Swipe left to pin or remove.")
                }
            }

            if !app.suggestedForumsToOffer.isEmpty {
                Section("Suggested") {
                    ForEach(app.suggestedForumsToOffer) { suggested in
                        HStack(spacing: DCTheme.spacingM) {
                            OnboardingForumIcon(siteURL: suggested.siteURL, name: suggested.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggested.name).lineLimit(2)
                                Text(suggested.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                            Spacer(minLength: DCTheme.spacingS)
                            Button {
                                DCHaptics.tap()
                                withAnimation { app.pinSuggested(suggested) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "pin")
                                    Text("Pin")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DCTheme.brandBlue)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(DCTheme.brandBlue.opacity(0.12), in: Capsule())
                                .fixedSize()
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Pin \(suggested.name)")
                        }
                    }
                }
            }

            addSection
        }
        .listStyle(.insetGrouped)
        .toolbar {
            if app.pinnedForums.count > 1 {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .confirmationDialog(
            removing.map { String(localized: "Remove \($0.displayName)?", comment: "Confirmation title; the argument is a forum name") } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { forum in
            Button("Remove and delete saved data", role: .destructive) {
                withAnimation { app.removeForum(forum, deleteData: true) }
            }
            Button("Remove, keep saved data") {
                withAnimation { app.removeForum(forum, deleteData: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { forum in
            let count = app.savedItemCount(forSiteURL: forum.siteURL)
            if count > 0 {
                Text("Also delete saved summaries/chats for this forum? It has \(count) saved items.",
                     comment: "Remove forum confirmation; the count is the forum's saved summaries and chats")
            } else {
                Text("Also delete saved summaries/chats for this forum?")
            }
        }
    }

    private func forumRow(_ forum: Forum) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            OnboardingForumIcon(siteURL: forum.siteURL, name: forum.displayName, iconURL: forum.iconURL, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(forum.displayName).lineLimit(2)
                Text(forum.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: DCTheme.spacingS)
            Button {
                DCHaptics.tap()
                withAnimation(DCMotion.quick) { app.togglePin(forum) }
            } label: {
                Image(systemName: forum.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(forum.isPinned ? DCTheme.brandBlue : Color.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(forum.isPinned ? "Unpin \(forum.displayName)" : "Pin \(forum.displayName)")
        }
        .contextMenu {
            Button {
                app.togglePin(forum)
            } label: {
                Label(forum.isPinned ? "Unpin" : "Pin", systemImage: forum.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                // Present after the context menu has dismissed, or the
                // dialog is dropped on iPad.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    removing = forum
                }
            } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
        // A container, so the pin button keeps its own label/identity.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsForum-\(forum.host)")
    }

    private var addSection: some View {
        Section {
            HStack(spacing: DCTheme.spacingS) {
                TextField("forum.example.com", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(add)
                    .accessibilityIdentifier("settingsForumAddress")
                if adding {
                    ProgressView()
                } else {
                    Button("Add", action: add)
                        .fontWeight(.semibold)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("settingsAddForum")
                }
            }
            Toggle("Pin it", isOn: $pinNew)
            if let addError {
                Label(addError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(DCTheme.danger)
            } else if let addedName {
                Label("Added \(addedName).", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(DCTheme.success)
            }
        } header: {
            Text("Add a forum")
        } footer: {
            Text("Enter the address of any Discourse forum, or paste a link to one of its pages.")
        }
    }

    private func add() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !adding else { return }
        adding = true
        addError = nil
        addedName = nil
        Task {
            do {
                let forum = try await app.addForum(fromAddress: trimmed, pin: pinNew)
                withAnimation { addedName = forum.displayName }
                address = ""
                addressFocused = false
                DCHaptics.success()
            } catch {
                withAnimation { addError = error.localizedDescription }
                DCHaptics.warning()
            }
            adding = false
        }
    }
}
