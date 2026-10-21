import SwiftUI

// The voice UI (plan B7): the browser bar's microphone, the consent sheet,
// the voice bar over the page, and Settings › Voice. The session is in
// Voice/VoiceSession.swift, started by `VoiceController`.

// MARK: - Browser bar button

/// The microphone in the browser bar: starts a session on the current page,
/// or ends the running one.
struct VoiceBarButton: View {
    @ObservedObject var voice: VoiceController
    var onTap: () -> Void = {}

    var body: some View {
        Button {
            DCHaptics.tap()
            onTap()
            voice.toggle()
        } label: {
            Image(systemName: voice.isActive ? "mic.fill" : "mic")
                .foregroundStyle(voice.isActive ? AnyShapeStyle(DCTheme.brandGradient) : AnyShapeStyle(.primary))
                .symbolEffect(.pulse, isActive: voice.isActive)
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel(voice.isActive ? Text("End voice") : Text("Talk to Forumind", comment: "Browser bar button: start a live voice session"))
        .accessibilityIdentifier("voiceButton")
    }
}

// MARK: - Consent (App Review 5.1.2)

/// Asked once per provider before its first session: what goes to Google,
/// with whose key, and what Google may do with it.
struct VoiceConsentSheet: View {
    let provider: VoiceProvider
    let settings: VoiceSettings
    let onAgree: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(DCTheme.brandGradient)
                        .accessibilityHidden(true)
                    Text("Voice uses Google Gemini")
                        .font(.title2.weight(.bold))
                    VoiceDisclosure(provider: provider, settings: settings)
                }
                .padding(DCTheme.spacingXL)
                .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: DCTheme.spacingS) {
                    Button(action: onAgree) {
                        Text("Agree and Start")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DCPrimaryButtonStyle())
                    .accessibilityIdentifier("voiceConsentAgree")
                    Button("Cancel", role: .cancel, action: onCancel)
                        .frame(minHeight: DCTheme.controlHeight)
                        .accessibilityIdentifier("voiceConsentCancel")
                }
                .padding(.horizontal, DCTheme.spacingXL)
                .padding(.vertical, DCTheme.spacingM)
                .frame(maxWidth: DCTheme.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("voiceConsentSheet")
    }
}

/// What voice sends where, shared by the consent sheet and Settings › Voice.
struct VoiceDisclosure: View {
    let provider: VoiceProvider
    let settings: VoiceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            point("arrow.up.forward.circle", Text("While you talk, your voice and the page content you ask about are sent to Google (\(provider.displayName)) with your own API key. There is no Forumind server: nothing goes through us.", comment: "Voice consent; the placeholder is Google AI Studio or Google Vertex AI"))
            switch provider {
            case .aiStudio:
                point("person.2", Text("On the free tier of Google AI Studio, Google may use what you send to improve its products, and people may review it. Don’t say or open anything you want to keep private.", comment: "Voice consent: Google's free-tier data use"))
            case .vertex:
                point("building.columns", Text("On Vertex AI, your Google Cloud agreement decides how Google may use what you send.", comment: "Voice consent: data use on Vertex AI"))
            }
            point("creditcard", Text("Every connected minute is billed to your key, or counts against its free quota. \(limitText)", comment: "Voice consent; the placeholder is the cost-guard sentence"))
            Link(destination: termsURL) {
                Label("Google’s terms for this service", systemImage: "arrow.up.right.square")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("voiceTermsLink")
        }
    }

    private var termsURL: URL {
        switch provider {
        case .aiStudio: URL(string: "https://ai.google.dev/gemini-api/terms")!
        case .vertex: URL(string: "https://cloud.google.com/terms/service-terms")!
        }
    }

    private var limitText: String {
        let session = settings.sessionLimitMinutes
        let day = settings.dailyLimitMinutes
        switch (session > 0, day > 0) {
        case (true, true):
            return String(localized: "A session ends after \(session) minutes, and voice stops for the day after \(day) minutes. You can change this in Settings › Voice.", comment: "Voice cost guard; the placeholders are minutes")
        case (true, false):
            return String(localized: "A session ends after \(session) minutes. You can change this in Settings › Voice.", comment: "Voice cost guard; the placeholder is minutes")
        case (false, true):
            return String(localized: "Voice stops for the day after \(day) minutes. You can change this in Settings › Voice.", comment: "Voice cost guard; the placeholder is minutes")
        case (false, false):
            return String(localized: "There is no time limit. You can set one in Settings › Voice.", comment: "Voice cost guard is off")
        }
    }

    private func point(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DCTheme.spacingM) {
            Image(systemName: symbol)
                .foregroundStyle(DCTheme.brandBlue)
                .frame(width: 24)
                .accessibilityHidden(true)
            text
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Voice bar

/// A compact bar over the page while voice runs: the state, the live
/// transcript line, mute and end, and the Health row behind a tap. It sits
/// under the result cards, so both stay visible.
struct VoiceBar: View {
    @ObservedObject var voice: VoiceController

    var body: some View {
        Group {
            if let session = voice.session {
                VoiceSessionBar(voice: voice, session: session)
            } else if let failure = voice.startFailure {
                VoiceBarFrame {
                    HStack(spacing: DCTheme.spacingS) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DCTheme.warning)
                            .accessibilityHidden(true)
                        Text(failure.message)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("voiceBarState")
                        Spacer(minLength: 0)
                        VoiceBarCloseButton(action: voice.dismiss)
                    }
                    .padding(.leading, DCTheme.spacingM)
                    .padding(.vertical, DCTheme.spacingXS)
                }
            }
        }
    }
}

private struct VoiceSessionBar: View {
    @ObservedObject var voice: VoiceController
    @ObservedObject var session: VoiceSession
    @State private var showsHealth = false
    @State private var draft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VoiceBarFrame {
            VStack(alignment: .leading, spacing: 2) {
                header
                if !transcript.isEmpty {
                    Text(transcript)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, DCTheme.spacingM)
                        .accessibilityIdentifier("voiceTranscript")
                }
                if let engine = voice.audioEngine {
                    VoiceEngineStatus(engine: engine, showsHealth: showsHealth)
                }
                if VoiceDebug.showsTextInput, !session.state.isOver {
                    typeField
                }
            }
            .padding(.bottom, DCTheme.spacingS)
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: showsHealth)
    }

    private var header: some View {
        HStack(spacing: DCTheme.spacingS) {
            Button {
                showsHealth.toggle()
            } label: {
                HStack(spacing: DCTheme.spacingS) {
                    Image(systemName: stateSymbol)
                        .foregroundStyle(stateTint)
                        .symbolEffect(.variableColor.iterative, isActive: session.state == .speaking && !reduceMotion)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(stateText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("voiceBarState")
                    if voice.audioEngine != nil {
                        Image(systemName: showsHealth ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voice.audioEngine == nil)
            .accessibilityHint(Text("Shows the audio health", comment: "Accessibility hint of the voice bar's state"))
            .padding(.leading, DCTheme.spacingM)

            if session.state.isOver {
                VoiceBarCloseButton(action: voice.dismiss)
            } else {
                Button {
                    DCHaptics.tap()
                    session.setMuted(!session.isMuted)
                } label: {
                    Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(session.isMuted ? DCTheme.danger : .primary)
                }
                .buttonStyle(DCIconButtonStyle())
                .accessibilityLabel(session.isMuted ? Text("Unmute") : Text("Mute"))
                .accessibilityIdentifier("voiceMute")
                Button {
                    DCHaptics.tap()
                    voice.end()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(DCTheme.danger, in: Circle())
                }
                .buttonStyle(DCIconButtonStyle())
                .accessibilityLabel(Text("End voice"))
                .accessibilityIdentifier("voiceEnd")
                .padding(.trailing, DCTheme.spacingXS)
            }
        }
    }

    /// Developer path: typed turns instead of speech.
    private var typeField: some View {
        HStack(spacing: DCTheme.spacingS) {
            TextField(text: $draft) {
                Text(verbatim: "Type instead of speaking")
            }
            .textFieldStyle(.roundedBorder)
            .submitLabel(.send)
            .onSubmit(send)
            .accessibilityIdentifier("voiceTextField")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title3)
            }
            .buttonStyle(DCIconButtonStyle())
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !session.state.isActive)
            .accessibilityLabel(Text(verbatim: "Send"))
            .accessibilityIdentifier("voiceTextSend")
        }
        .padding(.horizontal, DCTheme.spacingM)
        .padding(.top, DCTheme.spacingXS)
    }

    private func send() {
        session.sendText(draft)
        draft = ""
    }

    /// The model's line once it answers, else the user's.
    private var transcript: String {
        let model = session.lastModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = session.lastUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch session.state {
        case .speaking: return model
        case .listening, .thinking: return user.isEmpty ? model : user
        default: return model.isEmpty ? user : model
        }
    }

    private var stateText: String {
        switch session.state {
        case .idle, .connecting:
            return String(localized: "Connecting…", comment: "Voice bar state")
        case .listening:
            return session.isMuted
                ? String(localized: "Muted", comment: "Voice bar state: the microphone is muted")
                : String(localized: "Listening", comment: "Voice bar state")
        case .thinking:
            return String(localized: "Thinking…", comment: "Voice bar state")
        case .speaking:
            return String(localized: "Speaking", comment: "Voice bar state")
        case .reconnecting:
            return String(localized: "Reconnecting…", comment: "Voice bar state")
        case .ended(let reason):
            return Self.endText(reason, settings: session.configuration.settings)
        case .failed(let failure):
            return failure.message
        }
    }

    static func endText(_ reason: VoiceSession.EndReason, settings: VoiceSettings) -> String {
        switch reason {
        case .user, .model:
            return String(localized: "Voice ended.", comment: "Voice bar: the session is over")
        case .idle:
            return String(localized: "Voice ended after a quiet moment. Tap the microphone to talk again.", comment: "Voice bar: the idle timeout closed the session")
        case .sessionLimit:
            return String(localized: "Voice ended: this session reached its \(settings.sessionLimitMinutes)-minute limit.", comment: "Voice bar: the cost guard ended the session; the placeholder is minutes")
        case .dailyLimit:
            return String(localized: "Voice ended: today’s \(settings.dailyLimitMinutes) voice minutes are used up. Change the limit in Settings › Voice.", comment: "Voice bar: the daily cost guard; the placeholder is minutes")
        }
    }

    private var stateSymbol: String {
        switch session.state {
        case .idle, .connecting, .reconnecting: "antenna.radiowaves.left.and.right"
        case .listening: session.isMuted ? "mic.slash" : "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .ended: "checkmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var stateTint: Color {
        switch session.state {
        case .failed: DCTheme.warning
        case .ended: .secondary
        case .speaking: DCTheme.brandPurple
        default: DCTheme.brandBlue
        }
    }
}

/// The engine's notice ("Paused for a call or Siri"), tap to resume, and
/// the Health row.
private struct VoiceEngineStatus: View {
    @ObservedObject var engine: VoiceAudioEngine
    let showsHealth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingXS) {
            if engine.needsResume {
                Button {
                    engine.resume()
                } label: {
                    Label("Tap to resume", systemImage: "play.circle.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("voiceResume")
            }
            if let notice = engine.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if engine.health.noMicrophoneSignal {
                Label("The microphone sends silence. Check that no other app is using it.", systemImage: "mic.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(DCTheme.warning)
            }
            if showsHealth {
                VoiceHealthRows(health: engine.health)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DCTheme.spacingM)
    }
}

/// Echo cancellation, underruns, the route and the microphone: where most
/// audio problems show first.
private struct VoiceHealthRows: View {
    let health: VoiceAudioHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(Text("Echo cancellation", comment: "Voice Health row"), echo, ok: health.echoCancellation.isActive)
            row(Text("Underruns", comment: "Voice Health row: audible gaps in the voice's playback"), "\(health.underruns) · \(health.bufferTargetMilliseconds) ms", ok: health.underruns == 0)
            row(Text("Route", comment: "Voice Health row: the audio output and input"), health.route.isEmpty ? "—" : health.route, ok: true)
            row(Text("Microphone", comment: "Voice Health row"), microphone, ok: !health.noMicrophoneSignal)
        }
        .font(.caption.monospacedDigit())
        .padding(.top, DCTheme.spacingXS)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voiceHealth")
    }

    private var echo: String {
        health.echoCancellation.isActive
            ? String(localized: "On")
            : String(localized: "Off") + " (" + health.echoCancellation.missing.joined(separator: ", ") + ")"
    }

    private var microphone: String {
        let rate = health.inputSampleRate > 0 ? String(format: "%.0f kHz", health.inputSampleRate / 1000) : "—"
        let signal = health.noMicrophoneSignal
            ? String(localized: "no signal", comment: "Voice Health row: the microphone delivers only silence")
            : CaptureGate.Diagnostics.format(dBFS: health.gate.levelDBFS)
        return "\(rate) · \(signal)"
    }

    private func row(_ title: Text, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DCTheme.spacingS) {
            Circle()
                .fill(ok ? DCTheme.success : DCTheme.warning)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            title.foregroundStyle(.secondary)
            Spacer(minLength: DCTheme.spacingS)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VoiceBarFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: DCTheme.contentMaxWidth)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                    .stroke(DCTheme.border)
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voiceBar")
    }
}

private struct VoiceBarCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.caption.weight(.bold))
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel("Close")
        .accessibilityIdentifier("voiceBarClose")
        .padding(.trailing, DCTheme.spacingXS)
    }
}

// MARK: - Settings › Voice

struct SettingsVoicePage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var voice: VoiceController

    private var providers: [VoiceProvider] { app.availableVoiceProviders }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $app.settings.voiceEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Talk to Forumind")
                        Text("A microphone in the browser bar starts a live conversation that can find, open and read posts for you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(DCTheme.brandBlue)
                .accessibilityIdentifier("voiceEnabled")
            } footer: {
                Text("Voice uses Google Gemini Live with your own Google Gemini or Vertex AI key. This setting is kept on this device.")
            }

            if providers.isEmpty {
                Section {
                    NavigationLink(value: SettingsPage.provider) {
                        Label("Add a Google Gemini or Vertex AI key", systemImage: "key")
                    }
                } footer: {
                    Text("The free tier of Google AI Studio includes live voice.")
                }
            } else {
                Section("Provider") {
                    Picker("Provider", selection: providerBinding) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    if app.voiceProvider == .vertex,
                       GeminiLive.Endpoint.vertexProject(fromBaseURL: app.settings.configuration(for: .vertexAI).baseURL) == nil {
                        TextField("Google Cloud project ID", text: $app.settings.voice.vertexProject)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("voiceVertexProject")
                    }
                }
            }

            Section {
                Picker("Voice", selection: $app.settings.voice.voiceName) {
                    ForEach(VoiceCatalog.voices) { item in
                        Text(verbatim: "\(item.name) · \(item.style)").tag(item.name)
                    }
                }
                .accessibilityIdentifier("voiceName")
                Picker("Answer length", selection: $app.settings.voice.answerLength) {
                    ForEach(VoiceAnswerLength.allCases) { length in
                        Text(length.label).tag(length)
                    }
                }
                Picker("Read posts aloud", selection: $app.settings.voice.eyesFree) {
                    ForEach(VoiceEyesFree.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Close when quiet", selection: $app.settings.voice.idleTimeout) {
                    ForEach([30.0, 60, 120, 300], id: \.self) { seconds in
                        Text(Self.duration(seconds)).tag(seconds)
                    }
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("Automatic reads posts aloud while headphones are connected; otherwise the voice points at the screen. Voice names and styles are Google’s.")
            }

            Section {
                Picker("Per session", selection: $app.settings.voice.sessionLimitMinutes) {
                    ForEach(VoiceSettings.sessionLimitChoices, id: \.self) { minutes in
                        Text(Self.limit(minutes)).tag(minutes)
                    }
                }
                .accessibilityIdentifier("voiceSessionLimit")
                Picker("Per day", selection: $app.settings.voice.dailyLimitMinutes) {
                    ForEach(VoiceSettings.dailyLimitChoices, id: \.self) { minutes in
                        Text(Self.limit(minutes)).tag(minutes)
                    }
                }
                .accessibilityIdentifier("voiceDailyLimit")
                LabeledContent("Used today", value: Self.minutes(VoiceUsageStore().seconds(on: Date())))
                LabeledContent(voice.isActive ? "This session" : "Last session", value: Self.minutes(voice.session?.connectedSeconds ?? VoiceUsageStore().lastSessionSeconds))
            } header: {
                Text("Time limit")
            } footer: {
                Text("Every connected minute is billed to your key. At a limit, voice finishes its answer and ends. Minutes are counted on this device.")
            }

            if let provider = app.voiceProvider ?? providers.first {
                Section {
                    VoiceDisclosure(provider: provider, settings: app.settings.voice)
                        .padding(.vertical, DCTheme.spacingXS)
                    ForEach(VoiceProvider.allCases.filter { VoiceConsent.isGranted($0, in: app.settings) }) { granted in
                        Button(role: .destructive) {
                            app.revokeVoiceConsent(granted)
                        } label: {
                            Text("Withdraw consent for \(granted.displayName)", comment: "Settings › Voice; the placeholder is Google AI Studio or Google Vertex AI")
                        }
                    }
                } header: {
                    Text("Privacy")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var providerBinding: Binding<VoiceProvider> {
        Binding(
            get: { app.voiceProvider ?? .aiStudio },
            set: { app.settings.voice.provider = $0 }
        )
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 60 ? [.second] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? "\(Int(seconds))"
    }

    static func limit(_ minutes: Int) -> String {
        minutes > 0 ? duration(Double(minutes) * 60) : String(localized: "No limit", comment: "Settings › Voice: no time limit")
    }

    static func minutes(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: (seconds / 60).rounded(.up) * 60) ?? "0"
    }
}

/// Presents the consent sheet when `VoiceController` asks for it.
struct VoiceConsentPresenter: ViewModifier {
    @ObservedObject var app: AppModel
    @ObservedObject var voice: VoiceController

    func body(content: Content) -> some View {
        content.sheet(item: $voice.consentProvider) { provider in
            VoiceConsentSheet(
                provider: provider,
                settings: app.settings.voice,
                onAgree: { voice.agree(provider) },
                onCancel: { voice.declineConsent() }
            )
        }
    }
}
