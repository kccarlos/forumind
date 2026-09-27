import SwiftUI

// Reusable forum UI: icons, tiles, rows, the forum switcher, the Add forum
// sheet, the pinned-forums editor, and the remove-forum confirmation.

// MARK: - Icon

/// Whether forum icons load from the forum's site. DEBUG builds turn this off
/// with `-dc-no-forum-icons` (implied by `-dc-sample`), so screenshots show
/// letter monograms instead of third-party logos.
enum ForumIconPolicy {
    static let loadsRemoteIcons: Bool = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return !arguments.contains("-dc-no-forum-icons") && !arguments.contains("-dc-sample")
        #else
        return true
        #endif
    }()
}

/// A forum's icon: its touch icon/favicon when it loads, otherwise a monogram
/// on the forum's tint (stable per host).
struct ForumIcon: View {
    let siteURL: String
    let name: String
    var iconURL: URL?
    var size: CGFloat = DCTheme.forumTileIcon

    init(siteURL: String, name: String, iconURL: URL? = nil, size: CGFloat = DCTheme.forumTileIcon) {
        self.siteURL = siteURL
        self.name = name
        self.iconURL = ForumIconPolicy.loadsRemoteIcons ? iconURL : nil
        self.size = size
    }

    init(forum: Forum, size: CGFloat = DCTheme.forumTileIcon) {
        self.init(siteURL: forum.siteURL, name: forum.displayName, iconURL: forum.iconURL, size: size)
    }

    init(suggested: SuggestedForum, size: CGFloat = DCTheme.forumTileIcon) {
        self.init(siteURL: suggested.siteURL, name: suggested.name, iconURL: nil, size: size)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * DCTheme.forumIconCornerRatio, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let iconURL {
                AsyncImage(
                    url: iconURL,
                    transaction: Transaction(animation: .easeOut(duration: 0.2))
                ) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: size, height: size)
                            .background(Color.white)
                            .transition(.opacity)
                    } else {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.08)) }
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        let tint = DCTheme.forumTint(for: siteURL)
        return ZStack {
            LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(Self.initial(of: name, siteURL: siteURL))
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
    }

    /// First letter of the name, skipping a leading "The"; the host otherwise.
    static func initial(of name: String, siteURL: String) -> String {
        var words = name.split(separator: " ")
        if words.count > 1, words.first?.lowercased() == "the" { words.removeFirst() }
        let source = words.first.map(String.init) ?? ForumSite.host(of: siteURL)
        return source.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "#"
    }
}

// MARK: - Tile and rows

/// A pinned forum on the Forums home grid.
struct ForumTile: View {
    let forum: Forum
    var isCurrent = false
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = DCTheme.forumTileIcon

    var body: some View {
        VStack(spacing: DCTheme.spacingS) {
            ForumIcon(forum: forum, size: min(iconSize, 88))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            VStack(spacing: 1) {
                Text(forum.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(forum.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, DCTheme.spacingM)
        .padding(.horizontal, DCTheme.spacingS)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            DCTheme.surface,
            in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.55) : DCTheme.border, lineWidth: isCurrent ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(forum.displayName)
        .accessibilityValue(isCurrent ? "\(forum.host), current forum" : forum.host)
        .accessibilityAddTraits(.isButton)
    }
}

/// A forum in a list (Recent, switcher).
struct ForumRow: View {
    let forum: Forum
    var detail: String?
    var iconSize: CGFloat = 36
    var isCurrent = false

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            ForumIcon(forum: forum, size: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(forum.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail ?? forum.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Forum switcher (browser bar)

/// Favicon + forum name leading the browser bar; opens the switcher panel.
struct ForumSwitcherLabel: View {
    let forum: Forum?
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if let forum {
                ForumIcon(forum: forum, size: 22)
            } else {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.brandGradient)
                    .frame(width: 22, height: 22)
            }
            Text(forum?.displayName ?? "Forums")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(minHeight: compact ? 34 : 38)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Pinned forums, recents, "All forums…", and "Add forum…".
struct ForumSwitcherPanel: View {
    @ObservedObject var app: AppModel
    let onSelect: (Forum) -> Void
    let onAllForums: () -> Void
    let onAddForum: () -> Void

    private var recents: [Forum] { Array(app.recentForums.prefix(5)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !app.pinnedForums.isEmpty {
                    header("Pinned")
                    ForEach(app.pinnedForums) { row($0) }
                }
                if !recents.isEmpty {
                    header("Recent")
                    ForEach(recents) { row($0) }
                }
                if app.forums.isEmpty {
                    Text("No forums yet. Add one, or pick a suggestion on the Forums home.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DCTheme.spacingL)
                        .padding(.vertical, DCTheme.spacingM)
                }
                Divider().padding(.vertical, DCTheme.spacingXS)
                action("All forums…", systemImage: "square.grid.2x2", identifier: "switcherAllForums", perform: onAllForums)
                action("Add forum…", systemImage: "plus", identifier: "switcherAddForum", perform: onAddForum)
            }
            .padding(.vertical, DCTheme.spacingS)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 300, idealWidth: 330, maxWidth: 360)
        .frame(maxHeight: 460)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, DCTheme.spacingL)
            .padding(.top, DCTheme.spacingS)
            .padding(.bottom, DCTheme.spacingXS)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ forum: Forum) -> some View {
        Button { onSelect(forum) } label: {
            ForumRow(forum: forum, iconSize: 30, isCurrent: app.isCurrent(forum))
                .padding(.horizontal, DCTheme.spacingL)
                .frame(minHeight: 48)
        }
        .buttonStyle(DCRowButtonStyle())
        .accessibilityIdentifier("switcherForum-\(forum.host)")
    }

    private func action(
        _ title: String,
        systemImage: String,
        identifier: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: DCTheme.spacingM) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .frame(width: 30)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DCTheme.spacingL)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(DCRowButtonStyle())
        .accessibilityIdentifier(identifier)
    }
}

/// Full-width row button with a pressed highlight (menus and panels).
struct DCRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            .contentShape(.hoverEffect, Rectangle())
            .hoverEffect(.highlight)
            .animation(DCMotion.quick, value: configuration.isPressed)
    }
}

// MARK: - Add forum

/// Adds a forum by URL or host; validates it (basic-info.json) with inline
/// progress and errors. `onAdded` runs after the sheet dismisses.
struct AddForumSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var app: AppModel
    var initialAddress = ""
    var initialPin = true
    let onAdded: (Forum) -> Void

    @State private var address = ""
    @State private var pin = true
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var addTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: DCTheme.spacingS) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("meta.discourse.org", text: $address)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .focused($focused)
                            .onSubmit(add)
                            .disabled(isAdding)
                            .accessibilityLabel("Forum address")
                            .accessibilityIdentifier("addForumAddress")
                        if isAdding {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .onChange(of: address) { errorMessage = nil }
                } header: {
                    Text("Forum address")
                } footer: {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(DCTheme.danger)
                            .transition(.opacity)
                    } else if isAdding {
                        Text("Checking the forum…")
                    } else {
                        Text("Paste any page of a Discourse forum, or type its address.")
                    }
                }

                Section {
                    Toggle(isOn: $pin) {
                        Label("Pin to Forums home", systemImage: "pin")
                    }
                    .disabled(isAdding)
                }
            }
            .animation(DCMotion.quick, value: errorMessage)
            .navigationTitle("Add Forum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        addTask?.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .fontWeight(.semibold)
                        .disabled(trimmed.isEmpty || isAdding)
                        .accessibilityIdentifier("addForumConfirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .dcFormSheet()
        .interactiveDismissDisabled(isAdding)
        .onAppear {
            address = initialAddress
            pin = initialPin
            focused = true
        }
    }

    private func add() {
        guard !trimmed.isEmpty, !isAdding else { return }
        isAdding = true
        errorMessage = nil
        let address = trimmed
        let pin = pin
        addTask = Task {
            do {
                let forum = try await app.addForum(fromAddress: address, pin: pin)
                DCHaptics.success()
                isAdding = false
                dismiss()
                onAdded(forum)
            } catch is CancellationError {
                isAdding = false
            } catch {
                DCHaptics.warning()
                isAdding = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn’t reach that forum. Check the address and your connection."
            }
        }
    }
}

// MARK: - Pinned editor

/// Reorder or unpin pinned forums (the accessible alternative to dragging tiles).
struct PinnedForumsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.pinnedForums) { forum in
                        ForumRow(forum: forum, iconSize: 32)
                    }
                    .onMove(perform: app.movePinned)
                    .onDelete { offsets in
                        let forums = offsets.map { app.pinnedForums[$0] }
                        forums.forEach(app.unpin)
                    }
                } footer: {
                    Text("Drag to reorder. Unpinned forums stay under Recent.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pinned Forums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .overlay {
                if app.pinnedForums.isEmpty {
                    ContentUnavailableView("No pinned forums", systemImage: "pin.slash")
                }
            }
        }
        .dcFormSheet()
    }
}

// MARK: - Remove confirmation

extension View {
    /// Asks whether to keep or delete a forum's saved data before removing it.
    /// With `target`, only presents for that forum, so on iPad the popover
    /// points at its tile or row instead of the middle of the list.
    func forumRemovalDialog(_ forum: Binding<Forum?>, app: AppModel, for target: Forum? = nil) -> some View {
        confirmationDialog(
            forum.wrappedValue.map { "Remove \($0.displayName)?" } ?? "Remove forum?",
            isPresented: Binding(
                get: { forum.wrappedValue.map { target == nil || $0.siteURL == target?.siteURL } ?? false },
                set: { if !$0 { forum.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: forum.wrappedValue
        ) { target in
            Button("Remove Forum", role: .destructive) {
                withAnimation(DCMotion.smooth) { app.removeForum(target, deleteData: false) }
            }
            Button("Remove and Delete Its Data", role: .destructive) {
                withAnimation(DCMotion.smooth) { app.removeForum(target, deleteData: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its saved summaries, chats, agent runs, and watched topics can be kept or deleted.")
        }
    }
}
