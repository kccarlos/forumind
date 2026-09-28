# Apple Intelligence provider

Forumind can summarize, chat, and run the forum research agent with
Apple's Foundation Models, with no API key and no bill. The provider
is called **Apple Intelligence** in the app and is listed first in every
provider picker.

- **Private Cloud Compute (PCC)**: `PrivateCloudComputeLanguageModel`. Used
  when the build has `PCC_ENABLED`, the device runs iOS 27 or later, and the
  model reports `.available`. Requests go only to Apple's PCC.
- **On-device**: `SystemLanguageModel.default`. The fallback on iOS 26 or
  later, on devices that support Apple Intelligence with it turned on.
  Nothing leaves the device.
- **Unavailable**: every other case, with a clear reason. The user picks a
  bring-your-own-key provider instead.

The deployment target stays **iOS 17**. All FoundationModels code sits behind
`#if canImport(FoundationModels)` and `@available(iOS 26, *)`. The PCC code
also needs `#if PCC_ENABLED` and `@available(iOS 27, *)`.

## Source files

| File | What it holds |
| --- | --- |
| `Forumind/AppleIntelligence.swift` | App-owned types and pure logic, with no FoundationModels import: `AppleIntelligenceBackend`, `AppleIntelligenceStatus`, the `AppleIntelligenceAvailability.resolve` probe mapping, `AppleIntelligenceDefaults` (new-user default), `AppleIntelligenceBudget` (context window to character budgets), `AppleIntelligenceError` (user-facing messages), prompt fitting and rendering, stream-delta logic, the agent-action draft, and the `AppleIntelligenceServing` protocol |
| `Forumind/AppleIntelligenceClient.swift` | `AppleIntelligenceClient` (the real `AppleIntelligenceServing`), `FoundationModelsBridge` (availability, sessions, streaming, error mapping), and the `@Generable` agent-action schema |
| `Forumind/AppleIntelligenceService.swift` | `AIService` extension for summaries, chat, and agent steps, plus `AppleIntelligenceAgentPlanner` |
| `Forumind/AppleIntelligenceViews.swift` | `AppleIntelligenceStatusView`, which shows live status and the "No API key needed · Private" note |
| `ForumindTests/AppleIntelligenceTests.swift` | Unit tests with a fake `AppleIntelligenceServing`, plus opt-in live tests |

`AIService` sends every request through `streamText`, `generateSummary`,
`answer`, and `complete`. Each of these checks
`provider == .appleIntelligence` first and hands the request to the injected
`AIService.appleIntelligence` (by default `AppleIntelligenceClient.shared`).
`PromptAgentPlanner` does the same check for agent steps.

## API used (iOS 27 SDK, Xcode 27.0 / 27A266a)

Interface file:
`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface`
(3,647 lines; the doc comments are in the `.swiftdoc` next to it).

| Need | API | Availability |
| --- | --- | --- |
| On-device model | `SystemLanguageModel.default`, `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)` | iOS 26.0 |
| On-device availability | `SystemLanguageModel.availability`: `.available` or `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`; `supportsLocale(_:)` | iOS 26.0 |
| On-device context window | `SystemLanguageModel.contextSize: Int`, back-deployed (`@backDeployed(before: iOS 26.4)`). The SDK's inlined fallback body returns 4096 only where the OS framework lacks the symbol. The iOS 26.3 simulator runtime has it and returned **8192** (on a macOS 27 host). The app uses 4096 as its conservative floor. | iOS 26.0 |
| Token counting | `SystemLanguageModel.tokenCount(for:)` | iOS 26.4 (not used; the 26.3 simulator lacks it) |
| **PCC model** | `final class PrivateCloudComputeLanguageModel`, `convenience init()`, conforms to `LanguageModel` | **iOS 27.0** |
| PCC availability | `PrivateCloudComputeLanguageModel.availability`: `.available` or `.unavailable(.deviceNotEligible / .systemNotReady)`; `isAvailable`; `quotaUsage` (`QuotaUsage.status` `.belowLimit(isApproachingLimit:)` / `.limitReached`, `resetDate`) | iOS 27.0 |
| PCC context window | `PrivateCloudComputeLanguageModel.contextSize: Int { get async throws }`, `supportedLanguages`, `supportsLocale(_:) async throws` | iOS 27.0 |
| Session (iOS 26) | `LanguageModelSession(model: SystemLanguageModel = .default, tools:, instructions:)` | iOS 26.0 |
| Session (any model) | `LanguageModelSession(model: some LanguageModel, tools:, instructions:)`. This is the only way to run PCC. | iOS 27.0 |
| Streaming | `session.streamResponse(to:options:)` returns `ResponseStream<String>`, an `AsyncSequence` of `Snapshot` values. `snapshot.content` is the **whole text so far**, not a delta; `AppleIntelligenceStreaming.delta` works out the delta. | iOS 26.0 |
| Options | `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)` | iOS 26.0 |
| Guided generation | `@Generable`, `@Guide(description:_:)`, `GenerationGuide<String>.anyOf([...])`, `session.respond(to:generating:options:)`, `GeneratedContent(json:)` | iOS 26.0 |
| Errors (iOS 26) | `LanguageModelSession.GenerationError`: `.exceededContextWindowSize`, `.assetsUnavailable`, `.guardrailViolation`, `.unsupportedGuide`, `.unsupportedLanguageOrLocale`, `.decodingFailure`, `.rateLimited`, `.concurrentRequests`, `.refusal`. Deprecated in iOS 27. | iOS 26.0 |
| Errors (iOS 27) | `LanguageModelError`: `.contextSizeExceeded`, `.rateLimited(resetDate)`, `.guardrailViolation`, `.refusal`, `.unsupportedCapability`, `.unsupportedTranscriptContent`, `.unsupportedGenerationGuide`, `.unsupportedLanguageOrLocale`, `.timeout`. Also `LanguageModelSession.Error.concurrentRequests`, `SystemLanguageModel.Error.assetsUnavailable`, `GeneratedContent.ParsingError`, and `PrivateCloudComputeLanguageModel.Error`: `.networkFailure`, `.quotaLimitReached(resetDate, limitIncreaseSuggestion)`, `.serviceUnavailable`. | iOS 27.0 |
| Capabilities | `LanguageModel.capabilities.contains(.guidedGeneration / .toolCalling / .reasoning / .vision)` | iOS 27.0 |

The `PrivateCloudComputeLanguageModel` doc comment (in the swiftdoc) says:
*"To develop with PCC you must meet certain eligibility requirements. To learn
more and request access to the managed entitlement, see Accessing Private
Cloud Compute (https://developer.apple.com/private-cloud-compute/)."*

## Entitlement

- Key: **`com.apple.developer.private-cloud-compute`**
- Where it was found: the SDK's `.swiftinterface`, `.swiftdoc`, and `.tbd`
  don't contain it, and neither does Xcode's cached portal capability list
  (`DVTPortalCachedPortalCapabilities.json` only has
  `com.apple.developer.foundation-model-adapter`). It shows up as a string in
  the macOS 27 dyld shared cache
  (`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e.52`),
  in the model-catalog code next to `pccGenericInferenceVariant`.
- Value: assumed to be **Boolean `true`**. This is **unverified**. Confirm it
  in Xcode › Signing & Capabilities once Apple grants the capability. It is a
  *managed* entitlement: the provisioning profile must include it, so signing
  fails until Apple assigns it to the team.

```xml
<key>com.apple.developer.private-cloud-compute</key>
<true/>
```

## Enabling PCC in a build (`DC_ENABLE_PCC`)

PCC is off by default, so builds sign without the managed entitlement. Set
`DC_ENABLE_PCC=1` when generating the project:

```sh
DC_ENABLE_PCC=1 ruby scripts/generate_project.rb
```

The generator then:

1. adds `-D PCC_ENABLED` to the app target's `OTHER_SWIFT_FLAGS`, which turns
   on `#if PCC_ENABLED`, and
2. signs with `Forumind/Generated/Forumind.entitlements` (git-ignored),
   which it composes from `Forumind/Forumind.entitlements` plus
   `com.apple.developer.private-cloud-compute = true` (and the iCloud
   entitlements when CloudKit is on; see
   [DEVELOPMENT.md](DEVELOPMENT.md#icloud-sync-cloudkit-and-signing)).

The setting is read when the project is generated; regenerate to change it.

To check that the PCC path compiles without the entitlement (it only compiles,
it doesn't sign):

```sh
xcodebuild build -project Forumind.xcodeproj -scheme Forumind \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  OTHER_SWIFT_FLAGS='$(inherited) -D PCC_ENABLED' CODE_SIGNING_ALLOWED=NO
```

### Requesting the entitlement

1. Enroll in the Apple Developer Program and the **App Store Small Business
   Program**.
2. Request PCC access at
   https://developer.apple.com/contact/request/private-cloud-compute/ (more
   background: https://developer.apple.com/private-cloud-compute/).
3. Once it's granted, turn on the capability for the App ID, regenerate the
   profiles, and build with `DC_ENABLE_PCC=1`.

Eligibility, as the owner understands it (check Apple's current terms):
membership in the Small Business Program, and fewer than 2 million
first-time downloads. An app that goes past that has **6 months to migrate**
off no-cost PCC. PCC needs **iOS 27**. The on-device fallback works on
**iOS 26 and later** with or without the entitlement.

## Behavior matrix

| OS | Build / entitlement | Apple Intelligence on device | Result |
| --- | --- | --- | --- |
| iOS 17–25 | any | n/a | Unavailable: "Requires iOS 26 or later" (FoundationModels is never touched) |
| iOS 26.x | any (PCC needs iOS 27) | on, model ready | **On-device** |
| iOS 26.x | any | off | Unavailable: "Turn on Apple Intelligence in Settings" (with an Open Settings link) |
| iOS 26.x | any | model downloading | Unavailable: "Model downloading…" (updates live; the model is Observable) |
| iOS 26.x | any | unsupported hardware | Unavailable: "Device not supported" |
| iOS 26.x | any | locale unsupported | Unavailable: "Not available in your region or language" |
| iOS 27+ | default build (no `PCC_ENABLED`) | on / off / … | Same as iOS 26 (on-device or the reason) |
| iOS 27+ | `PCC_ENABLED` + entitlement | PCC `.available` | **Private Cloud Compute** (even while the on-device model downloads) |
| iOS 27+ | `PCC_ENABLED` + entitlement | PCC `.unavailable(.deviceNotEligible / .systemNotReady)`, on-device ready | **On-device** fallback |
| iOS 27+ | `PCC_ENABLED` + entitlement | both unavailable | The on-device reason (e.g. "Turn on Apple Intelligence in Settings") |

`supportsLocale()` checks `Locale.current`, which follows the app's language
(Settings › Forumind › Language), so the app in Simplified or Traditional
Chinese asks the model about Chinese. The status texts and errors, including
the unsupported language or region ones, are localized; Apple's name for the
feature is "Apple 智能" in Simplified Chinese and "Apple Intelligence" in
Traditional Chinese.

The backend is chosen before each request. A PCC failure partway through a
request (network, quota) is reported to the user. It does not silently rerun
the request on-device.

## Default provider

`AppleIntelligenceDefaults.shouldSelectAppleIntelligence` selects Apple
Intelligence for **both** model roles (Summaries & chat, and Ask the forum)
when provider setup appears (onboarding step 3, or the "Connect an AI
provider" sheet), but only when all of these hold:

- it's available now,
- the user never configured a provider: stock OpenRouter selection for both
  roles, every provider configuration at its defaults, no API keys, no
  favorites, and
- it hasn't been applied before (`UserDefaults` flag
  `appleIntelligence.defaultApplied`, so switching back to OpenRouter sticks).

Users who already configured a provider keep their selection. When Apple
Intelligence is unavailable, onboarding offers the BYO providers with
OpenRouter selected, as before.

## Context window and batching

`AppleIntelligenceBudget` turns the backend's window (in tokens) into
character budgets:

- characters per token: about 3 for Latin text and about 1 for CJK, estimated
  from the content;
- reply reserve: `min(cap, max(256, window / 4))`, where `cap` is 2,048
  tokens, or 8,192 for windows of 32k tokens and up (PCC). It is also passed
  as `maximumResponseTokens`;
- prompt room: `(window − reserve − 64) × chars/token × 0.9`.

Hierarchical summaries use `summaryBatchCharacters`, which is prompt room
minus the system prompt. It is **not** clamped to
`SummaryBatchLimit.minimum` (20k), and it ignores the user's batch slider.
Folding goes up to 8 levels (hosted providers use 4). If a request still
overflows (`contextExceeded`), the summary is retried with batches about 55%
the size, at most twice.

Chat bounds the forum source to what fits after the instructions, summary,
and the last 6 messages on-device (24 on PCC). One overflow retry halves the
source. Every request also runs through `AppleIntelligencePrompt.fit`, which
keeps the first message (the goal or question) and the newest messages,
trims long ones in the middle, and replaces dropped turns with a marker. This
keeps agent runs with large observations inside the window.

## Agent

`PromptAgentPlanner` hands Apple Intelligence steps to
`AppleIntelligenceAgentPlanner`, which uses guided generation with
`@Generable AppleIntelligenceGeneratedAction` (`thought`, `tool` limited by
`.anyOf` to the agent's tool names, and `arguments` as `[{name, value}]`).
If guided generation fails (`unsupportedGuide`, `decodingFailure`,
`ParsingError`), the step falls back to the existing JSON prompt and
`AgentActionParser`.

## Records

Jobs record the provider as `appleIntelligence` and the model as the backend
they ran on: **"Private Cloud Compute"** or **"On-device"** (from
`RunSettings.resolvingAppleIntelligence`). The UI shows "Apple Intelligence ·
On-device". The stored configuration model is the constant "Automatic", so it
never differs between devices that sync settings. Either model role can use
Apple Intelligence; its stored model is "Automatic" in both.

The context budgets above follow the model a request runs on. With Apple
Intelligence as the Summaries & chat model, summaries (including the agent's
`summarize_topic` tool) use its small batches while an Ask the forum model on
a hosted provider keeps its own limits, and the other way round. When Apple
Intelligence becomes unavailable, only the role that uses it shows as not
ready.

## Tests

`ForumindTests/AppleIntelligenceTests.swift` covers availability
mapping, the default-provider rules, batch derivation, error mapping (including
real `GenerationError` values on iOS 26), prompt fitting, stream deltas, and
agent-action decoding (including `GeneratedContent(json:)` into the
`@Generable` type). It runs on the iOS 26.3 simulator with a fake.

Live tests use the real model and are opt-in:

```sh
xcodebuild test -project Forumind.xcodeproj -scheme Forumind \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:ForumindTests/AppleIntelligenceTests \
  CODE_SIGNING_ALLOWED=NO TEST_RUNNER_DC_LIVE_APPLE_INTELLIGENCE=1
```

The simulator has the on-device model when the Mac runs Apple Intelligence.
These tests skip when the model is unavailable.

DEBUG builds accept `-dc-apple-intelligence pcc|on-device|off|unsupported|downloading|language|old`
to force a status for QA and screenshots. A forced `pcc` only changes the
status: without `PCC_ENABLED`, requests still run on-device but are sized for
the 16k PCC fallback window, so they may overflow and retry.

## Known limitations / open questions

- **Entitlement value type** is unverified (see above).
- **PCC context size** falls back to 16,384 tokens if
  `PrivateCloudComputeLanguageModel.contextSize` throws.
- **Forward compatibility**: `AIProvider` decodes by raw value. An older build
  that receives `"appleintelligence"` (as the synced `selectedProvider`, a
  topic's `provider`, or a favorite) through folder sync or a downgraded
  snapshot fails to decode that record.
- The on-device model is small, so a very long discussion takes many batches
  (and minutes). Guardrails can refuse some forum content; the message
  suggests a hosted provider.
- PCC quota: `quotaUsage` / `LimitIncreaseSuggestion.show()` are not surfaced
  in the UI yet. Hitting the limit shows the reset time.
- `PrivateCloudComputeLanguageModel()` is created for each probe and request,
  and its `contextSize` is read (async) on every request. Caching one instance
  would be a cheap improvement.
- "Open the Settings app" opens this app's page in Settings. iOS has no public
  deep link to Apple Intelligence & Siri, so the text says where to go.
