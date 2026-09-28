import SwiftUI

// Settings › Summaries & chat, Ask the forum, Watched topics, Browser
// (bar position, ad and tracker blocking).

/// "55k characters" (shared with the summary batch label, so both read and
/// translate the same way).
private func characters(_ value: Int) -> String {
    SummaryBatchLimit.label(value)
}

/// Plain-language explanation shown above a control.
private struct SettingExplanation: View {
    let title: LocalizedStringKey
    let value: String
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Summaries & chat

struct SettingsSummariesPage: View {
    @ObservedObject var app: AppModel
    @FocusState private var editingInstructions: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                    SettingExplanation(
                        title: "Context per batch",
                        value: SummaryBatchLimit.label(app.settings.summaryBatchLimit),
                        detail: "How much of a long topic is summarized at once."
                    )
                    Slider(
                        value: Binding(
                            get: { Double(app.settings.summaryBatchLimit) },
                            set: { app.settings.summaryBatchLimit = SummaryBatchLimit.normalized(Int($0)) }
                        ),
                        in: Double(SummaryBatchLimit.minimum)...Double(SummaryBatchLimit.maximum),
                        step: Double(SummaryBatchLimit.step)
                    )
                    .accessibilityLabel("Context per summary batch")
                    .tint(DCTheme.summaryTint)
                    .accessibilityValue(SummaryBatchLimit.label(app.settings.summaryBatchLimit))
                    .accessibilityIdentifier("summaryBatchLimit")
                }
                if app.settings.summaryBatchLimit != SummaryBatchLimit.default {
                    Button("Use default (\(SummaryBatchLimit.label(SummaryBatchLimit.default)))") {
                        app.settings.summaryBatchLimit = SummaryBatchLimit.default
                    }
                }
            } header: {
                Text("Summary batching")
            } footer: {
                // One literal (not concatenated) so it's a localizable key.
                Text("Longer discussions are split into batches of this size. Each batch is summarized, then the batch summaries are combined. Use smaller batches for models with small context windows. Hold Create summary to pick a size for one run.")
            }

            Section {
                VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                    SettingExplanation(
                        title: "Topic text per question",
                        value: characters(app.settings.forumContextLimit),
                        detail: "How much of the topic is sent along with each chat question."
                    )
                    Slider(
                        value: Binding(
                            get: { Double(app.settings.forumContextLimit) },
                            set: { app.settings.forumContextLimit = Int($0) }
                        ),
                        in: 5_000...1_000_000,
                        step: 5_000
                    )
                    .accessibilityLabel("Chat context size")
                    .tint(DCTheme.chatTint)
                    .accessibilityValue(characters(app.settings.forumContextLimit))
                    .accessibilityIdentifier("chatContextLimit")
                }
            } header: {
                Text("Chat context")
            } footer: {
                Text("More context gives better answers on long topics but uses more of your provider’s quota.")
            }

            ForumRequestPaceSection(app: app)

            Section {
                TextEditor(text: $app.settings.systemPrompt)
                    .focused($editingInstructions)
                    .frame(minHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if app.settings.systemPrompt.isEmpty {
                            Text("For example: Answer in English. Keep summaries under 200 words.",
                                 comment: "Placeholder for custom AI instructions. Translations may name their own language instead of English.")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Custom instructions")
                    .accessibilityIdentifier("customInstructions")
                if !app.settings.systemPrompt.isEmpty {
                    Button("Use the built-in prompt", role: .destructive) {
                        app.settings.systemPrompt = ""
                        app.saveSettings()
                    }
                }
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("Leave blank to use the built-in structured summary prompt. Custom instructions apply to summaries and chat. A topic’s own instructions (in the assistant’s ⋯ menu) take priority.")
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if editingInstructions {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        editingInstructions = false
                        app.saveSettings()
                    }
                }
            }
        }
        .onChange(of: app.settings.summaryBatchLimit) { app.saveSettings() }
        .onChange(of: app.settings.forumContextLimit) { app.saveSettings() }
        .onDisappear { app.saveSettings() }
    }
}

/// Settings › Summaries & chat › Forum requests: how quickly topics are read.
private struct ForumRequestPaceSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Section {
            Picker(selection: $app.settings.forumRequestPace) {
                ForEach(ForumRequestPace.allCases) { pace in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pace.title)
                        Text(pace.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(pace)
                    .accessibilityIdentifier("forumRequestPace-\(pace.rawValue)")
                }
            } label: {
                Text("Reading pace")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("forumRequestPace")
        } header: {
            Text("Forum requests")
        } footer: {
            Text(footer)
        }
        .onChange(of: app.settings.forumRequestPace) { app.saveSettings() }
    }

    private var footer: String {
        var sentences = [
            String(localized: "Forums are run by people and communities who pay for their servers. Reading a topic one page at a time keeps Forumind a polite visitor and avoids being rate limited.", comment: "Settings › Summaries & chat › Forum requests footer")
        ]
        switch app.settings.forumRequestPace {
        case .gentle:
            sentences.append(String(localized: "Long topics take longer to read: a 2,000-post topic takes about 20 seconds.", comment: "Forum requests footer for the Gentle pace (20 pages of 100 posts at 1 per second)"))
        case .standard:
            sentences.append(String(localized: "A 2,000-post topic takes about 10 seconds.", comment: "Forum requests footer for the Standard pace"))
        case .fast:
            sentences.append(String(localized: "Fast reads long topics quickest but puts the most load on the forum. Use it on forums you run or where you know it’s welcome.", comment: "Forum requests footer for the Fast pace"))
        }
        sentences.append(String(localized: "Work that’s already running keeps its pace.", comment: "Forum requests footer"))
        return sentences.joined(separator: " ")
    }
}

// MARK: Ask the forum

struct SettingsAgentPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: DCTheme.spacingM) {
                    OnboardingIconTile(symbol: "text.magnifyingglass", tint: DCTheme.agentTint, size: 40, filled: true)
                    Text("Ask a question and the assistant searches the forum, reads the most relevant topics, and answers with numbered sources. It only reads — it never posts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, DCTheme.spacingXS)
            }

            Section {
                Stepper(
                    "Max tool steps per run: \(app.settings.agentMaxSteps)",
                    value: Binding(
                        get: { app.settings.agentMaxSteps },
                        set: { app.settings.agentMaxSteps = AgentLimits.clampSteps($0) }
                    ),
                    in: AgentLimits.stepRange
                )
                .accessibilityIdentifier("agentMaxSteps")
            } header: {
                Text("Research steps")
            } footer: {
                Text("Each search or topic read is one step. More steps can find better answers but take longer and cost more. Default: \(AgentLimits.defaultMaxSteps).")
            }

            Section {
                Stepper(
                    "Max topics read per run: \(app.settings.agentMaxTopicReads)",
                    value: Binding(
                        get: { app.settings.agentMaxTopicReads },
                        set: { app.settings.agentMaxTopicReads = AgentLimits.clampTopicReads($0) }
                    ),
                    in: AgentLimits.topicReadRange
                )
                .accessibilityIdentifier("agentMaxTopicReads")
            } header: {
                Text("Topics to read")
            } footer: {
                Text("How many full topics it may open to answer one question. Default: \(AgentLimits.defaultMaxTopicReads).")
            }

            Section {
                VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                    SettingExplanation(
                        title: "Context per topic read",
                        value: characters(app.settings.agentReadLimit),
                        detail: "How much of each topic it reads. Larger reads catch more detail in long threads."
                    )
                    Slider(
                        value: Binding(
                            get: { Double(app.settings.agentReadLimit) },
                            set: { app.settings.agentReadLimit = AgentLimits.clampReadLimit(Int($0)) }
                        ),
                        in: Double(AgentLimits.readLimitRange.lowerBound)...Double(AgentLimits.readLimitRange.upperBound),
                        step: 5_000
                    )
                    .tint(DCTheme.agentTint)
                    .accessibilityLabel("Context per topic read")
                    .accessibilityValue(characters(app.settings.agentReadLimit))
                }
            } header: {
                Text("Read size")
            }

            if app.settings.agentMaxSteps != AgentLimits.defaultMaxSteps
                || app.settings.agentMaxTopicReads != AgentLimits.defaultMaxTopicReads
                || app.settings.agentReadLimit != AgentLimits.defaultReadLimit {
                Section {
                    Button("Restore defaults") {
                        app.settings.agentMaxSteps = AgentLimits.defaultMaxSteps
                        app.settings.agentMaxTopicReads = AgentLimits.defaultMaxTopicReads
                        app.settings.agentReadLimit = AgentLimits.defaultReadLimit
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: app.settings.agentMaxSteps) { app.saveSettings() }
        .onChange(of: app.settings.agentMaxTopicReads) { app.saveSettings() }
        .onChange(of: app.settings.agentReadLimit) { app.saveSettings() }
    }
}

// MARK: Watched topics & notifications

struct SettingsWatchedPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: DCTheme.spacingM) {
                    SettingsIcon(symbol: "bell.badge.fill", tint: SettingsPage.watched.tint)
                    Text("Notifications")
                    Spacer()
                    if app.notificationsAuthorized {
                        Label("On", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(DCTheme.success)
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Button("Turn on") { app.requestNotificationAuthorization() }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("enableNotifications")
                    }
                }
                Toggle(isOn: $app.settings.watchAutoRefreshSummaries) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh summaries of watched topics")
                        Text("Updates the saved summary when new replies arrive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(DCTheme.brandBlue)
                .accessibilityIdentifier("watchAutoRefresh")
            } header: {
                Text("Watched topics & notifications")
            } footer: {
                Text("Watch a topic from the assistant’s ⋯ menu. Watched topics are checked every 30 minutes while the app is open and, when iOS allows, in the background.")
            }

            Section {
                if app.watchedTopics.isEmpty {
                    Text("You’re not watching any topics yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.watchedTopics) { watched in
                        HStack(spacing: DCTheme.spacingM) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(watched.title).lineLimit(2)
                                Text(app.forum(for: watched.siteURL)?.displayName ?? ForumSite.host(of: watched.siteURL))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: DCTheme.spacingS)
                            if watched.newReplies > 0 {
                                DCPill(text: String(localized: "\(watched.newReplies) new", comment: "Badge: number of new replies in a watched topic"), tint: DCTheme.brandBlue)
                            }
                        }
                        .swipeActions {
                            Button("Unwatch", role: .destructive) {
                                withAnimation { app.unwatch(topicKey: watched.topicKey) }
                            }
                        }
                    }
                }
            } header: {
                Text("Watching")
            } footer: {
                if !app.watchedTopics.isEmpty {
                    Text("Swipe left to stop watching.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: app.settings.watchAutoRefreshSummaries) { app.saveSettings() }
    }
}

// MARK: Browser

struct SettingsBrowserPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: DCTheme.spacingXL) {
                    ForEach(BrowserBarPosition.allCases) { position in
                        BrowserBarPreview(
                            position: position,
                            selected: app.settings.browserBarPosition == position
                        ) {
                            DCHaptics.tap()
                            withAnimation(DCMotion.quick) { app.settings.browserBarPosition = position }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DCTheme.spacingS)
                .listRowSeparator(.hidden)

                Picker("Browser bar", selection: $app.settings.browserBarPosition) {
                    ForEach(BrowserBarPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("browserBarPosition")
            } header: {
                Text("Browser bar")
            } footer: {
                Text("The bar shrinks while you scroll down a forum page and comes back when you scroll up or tap it. Bottom keeps it within reach of your thumb.")
            }

            ContentBlockingSettingsSections(app: app, rules: app.contentRules)
        }
        .formStyle(.grouped)
        .onChange(of: app.settings.browserBarPosition) { app.saveSettings() }
    }
}

/// Block ads / Block trackers and the sites allowed to show ads.
private struct ContentBlockingSettingsSections: View {
    @ObservedObject var app: AppModel
    @ObservedObject var rules: ContentRuleLibrary

    var body: some View {
        Section {
            Toggle(isOn: $app.settings.contentBlockingEnabled) {
                Label {
                    Text("Block ads")
                } icon: {
                    SettingsIcon(symbol: "shield.lefthalf.filled", tint: DCTheme.brandBlue)
                }
            }
            .accessibilityIdentifier("blockAdsToggle")
            Toggle(isOn: $app.settings.blockTrackers) {
                Label {
                    Text("Block trackers")
                } icon: {
                    SettingsIcon(symbol: "eye.slash.fill", tint: Color(light: 0x4B5563, dark: 0x8E96A3))
                }
            }
            .accessibilityIdentifier("blockTrackersToggle")
        } header: {
            Text("Ads & trackers")
        } footer: {
            Text(footer)
                .accessibilityIdentifier("contentBlockingFootnote")
        }
        // The lists' date, without looking up or compiling anything.
        .onAppear { rules.loadManifestIfNeeded() }

        Section {
            if app.settings.adBlockAllowedSites.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.settings.adBlockAllowedSites, id: \.self) { host in
                    Label(host, systemImage: "shield.slash")
                        .accessibilityIdentifier("allowedSite-\(host)")
                }
                .onDelete { offsets in
                    withAnimation { app.removeAllowedSites(atOffsets: offsets) }
                }
            }
        } header: {
            Text("Allowed sites")
        } footer: {
            Text(
                app.settings.adBlockAllowedSites.isEmpty
                    ? "To let a site show ads, open it and tap the shield in the address bar."
                    : "Ads and trackers aren’t blocked on these sites. Swipe left to remove one."
            )
        }
    }

    /// Whole sentences, each its own localizable string, joined by spaces.
    private var footer: String {
        var sentences = [
            String(localized: "Off by default, out of respect for forum owners who rely on ads. Turn either switch on to block them in the built-in browser.", comment: "Settings › Browser: why ad and tracker blocking starts off"),
            String(localized: "Uses EasyList and EasyPrivacy filter lists.")
        ]
        if let date = rules.manifest?.generatedDate {
            let day = date.formatted(date: .abbreviated, time: .omitted)
            sentences.append(String(localized: "Lists from \(day).", comment: "Filter lists' date"))
        } else if let version = rules.manifest?.version {
            sentences.append(String(localized: "Lists version \(version)."))
        }
        if rules.phase == .compiling, app.settings.contentBlockingEnabled || app.settings.blockTrackers {
            sentences.append(String(localized: "Preparing the lists…"))
        }
        sentences.append(String(localized: "Forum sign-in pages are never blocked."))
        return sentences.joined(separator: " ")
    }
}

/// Tiny phone mock with the bar at the top or bottom.
private struct BrowserBarPreview: View {
    let position: BrowserBarPosition
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DCTheme.spacingS) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DCTheme.raisedSurface)
                    .frame(width: 70, height: 120)
                    .overlay(alignment: position == .top ? .top : .bottom) {
                        Capsule()
                            .fill(selected ? DCTheme.brandBlue : Color.secondary.opacity(0.5))
                            .frame(width: 52, height: 12)
                            .padding(8)
                    }
                    .overlay {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(0..<4, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: index.isMultiple(of: 2) ? 44 : 34, height: 5)
                            }
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected ? DCTheme.brandBlue : DCTheme.border, lineWidth: selected ? 2 : 1)
                    }
                Text(position.displayName)
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DCTheme.brandBlue : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(position == .top ? "Bar at the top" : "Bar at the bottom")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
