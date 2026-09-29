# Releasing on the App Store

A checklist for publishing Forumind as a free app. Items marked
**(owner)** need the account holder's decision or login; everything else is
in the repository already.

## 1. Accounts and programs

- [ ] **(owner)** Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/).
- [ ] **(owner)** Accept the latest agreements in App Store Connect ›
      Business. A free app needs only the Apple Developer Program License
      Agreement; the Paid Apps agreement and banking/tax forms are not needed.
- [ ] **(owner)** Join the [App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/).
      The app is free, so the commission rate doesn't matter; the program is
      what makes the app eligible for Apple Foundation Models on Private Cloud
      Compute at no cost (together with the entitlement below).
- [ ] **(owner)** Set up two-factor authentication and decide who else (if
      anyone) gets App Store Connect access.

## 2. Identifiers and the app record

- [ ] Register the identifiers (Certificates, Identifiers & Profiles ›
      Identifiers), or let Xcode/CI create them with automatic signing:

      | Identifier | Value |
      | --- | --- |
      | App ID | `io.github.kccarlos.forumind` |
      | Share extension App ID | `io.github.kccarlos.forumind.share` |
      | App Group (on both App IDs) | `group.io.github.kccarlos.forumind` |
      | iCloud container (app App ID, with the iCloud › CloudKit and Push Notifications capabilities) | `iCloud.io.github.kccarlos.forumind` |

      The first signed build with automatic signing registers the container
      and turns the capabilities on; check them in the portal afterwards.
- [ ] **Deploy the CloudKit schema to production** (CloudKit Console ›
      the container › Schema › Deploy Schema Changes) before the first
      TestFlight build. Development builds create the record types in the
      development environment as they sync; TestFlight and App Store builds
      use the **production** environment, which only has what was deployed.
      Without it, sync fails for every tester and user. Redeploy whenever a
      release adds a record type or field. The record types and fields are
      listed in [SYNC.md](SYNC.md#cloudkit-schema).

- [ ] Create the app record: App Store Connect › Apps › **+** › New App.
      Platform iOS, name (see [Name and trademark](#6-name-and-trademark)),
      primary language English (U.S.), bundle ID
      `io.github.kccarlos.forumind`, SKU for example
      `forumind-ios`, full access.
- [ ] Pricing and Availability: **Free**, all regions you want.
- [ ] Set up CI secrets and variables ([CI.md](CI.md#secrets-and-variables)).
      The repository variable `DEVELOPMENT_TEAM` must be set to the signing
      team ID for TestFlight builds; the team ID is never committed (the
      checked-in project has no team, and local builds read the git-ignored
      `Config/DevelopmentTeam.txt`).

## 3. App Privacy ("nutrition label")

Answer **"No, we do not collect data from this app."** The resulting label is
**Data Not Collected**.

Why this is accurate under Apple's definitions ("collect" means transmitting
data off the device in a way that the developer or its third-party partners
can access for longer than needed to service the request):

- The developer runs no servers and receives nothing: no analytics, no crash
  SDK, no accounts, no ads.
- Forum traffic goes directly between the device and the forum the user
  opens, like any web browser.
- AI requests go directly to the provider **the user chooses and configures
  with their own key** (or to Apple Intelligence). Those providers aren't the
  developer's partners, and the data is sent only to fulfill the user's
  request. Apple treats data processed on-device or on Private Cloud Compute
  to fulfill a request as not collected by the developer.
- iCloud sync stores data in the app's CloudKit **private database** in the
  user's own iCloud account. Apple's App Privacy guidance counts data as
  collected only when the developer or its partners can access it; CloudKit
  gives the developer no access to users' private databases (the CloudKit
  Console shows only the developer's own account's data), and the content
  fields are end-to-end encrypted besides. So it is not "collected", and the
  answers don't change with sync.
- No tracking: nothing is linked to the user or shared with data brokers or
  ad networks.

Re-check the answers if you ever add analytics, crash reporting, a backend,
or a hosted AI proxy.

### Privacy manifest

`Forumind/PrivacyInfo.xcprivacy` and
`ForumindShare/PrivacyInfo.xcprivacy` declare no tracking, no tracking
domains, and no collected data, plus the "required reason" APIs the code uses:

| API category | Reason | Why |
| --- | --- | --- |
| User defaults | `CA92.1` | App-only settings and state. |

When code starts using another required-reason API (for example disk space or
system boot time), add it to the manifest. Xcode's **Generate Privacy Report**
(Organizer › Archives) shows the combined report for a build.

## 4. Export compliance

`Info.plist` sets `ITSAppUsesNonExemptEncryption` to `NO`, so App Store
Connect doesn't ask about encryption on each upload.

Rationale: the app uses only encryption **provided by Apple's operating
system**, and only standard algorithms:

- HTTPS/TLS through `URLSession` and WebKit for forum and AI requests.
- **CloudKit**'s end-to-end encryption of synced fields (`encryptedValues`),
  done entirely by the OS; the app itself only hashes (SHA-256 from Apple
  CryptoKit) to name records.
- The iOS Keychain for API keys.

There is no proprietary or non-standard cryptography and no bundled
cryptographic library. Apple's guidance treats apps whose encryption is
limited to what the OS provides as exempt from uploading export documentation.

- [ ] **(owner)** Confirm this reading with Apple's
      [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
      and the export compliance questions in App Store Connect. Depending on
      how the encryption is classified, U.S. rules may also expect a yearly
      self-classification report to the Bureau of Industry and Security;
      check whether it applies. If in doubt, answer the questions in App Store
      Connect instead of relying on the plist key.

## 5. Age rating

Fill in the age rating questionnaire (App Information › Age Rating) honestly.
The deciding answer is **Unrestricted Web Access: Yes**: the built-in browser
can open any website, not only Discourse forums. Under Apple's current age
ratings (4+, 9+, 13+, 16+, 18+), unrestricted web access places the app at
**16+**. Also expect questions about user-generated content: forums are
user-generated content that the app displays but does not host or moderate;
the app itself has no posting, messaging, or social features. Answer the
remaining content questions **None**.

If a lower rating ever matters, the browser would have to be limited to
forum sites, which would break sign-in flows and links; that is not planned.

## 6. Name and trademark

App Review guideline **5.2.1** says apps may not use protected third-party
marks in the app name or metadata without permission. The app's working title
combined "Discourse" (a trademark of Civilized Discourse Construction Kit,
Inc.) with a Microsoft product name, so it was renamed to the independent
brand **Forumind**, which uses neither.

- The name (`appstore/metadata/<locale>/name.txt`), the home-screen name
  (`CFBundleDisplayName`), and the bundle ID (`io.github.kccarlos.forumind`)
  are all Forumind.
- "Discourse" appears only descriptively, to say what the app works with:
  the subtitle is `AI for Discourse forums` (Chinese: `Discourse 论坛 AI 助手`
  / `Discourse 論壇 AI 助理`), and the description says it works with any
  Discourse forum. It is not part of the name and not a keyword.
- The description, the README, and Settings › About carry the disclaimer:
  "Forumind is an independent app and is not affiliated with or endorsed by
  Civilized Discourse Construction Kit, Inc. Discourse is a trademark of its
  respective owner."
- Keywords must not include other companies' app names or trademarks (for
  example ChatGPT or Claude); provider names appear only in the
  description, where they describe compatibility.
- [ ] **(owner)** Before submitting, search the
      [USPTO trademark database](https://tmsearch.uspto.gov) and the App Store
      for "Forumind" to confirm nothing conflicting has appeared, then create
      the app record in App Store Connect (section 2) to reserve the name.

## 7. Store listing

Text lives in `appstore/metadata/` in fastlane `deliver` layout, one folder
per App Store language: `en-US` (the primary language), `zh-Hans`
(Simplified Chinese) and `zh-Hant` (Traditional Chinese).
`scripts/ci/check-appstore-metadata.sh` checks the limits for every locale
folder in CI:

| File (in each locale folder) | Limit |
| --- | --- |
| `name.txt` | 30 |
| `subtitle.txt` | 30 |
| `promotional_text.txt` | 170 |
| `keywords.txt` | 100, comma-separated |
| `description.txt` | 4000 |
| `release_notes.txt` | 4000 ("What's New"; not used for the first version) |
| `privacy_url.txt`, `support_url.txt`, `marketing_url.txt` | URLs |
| `copyright.txt`, `primary_category.txt`, `secondary_category.txt` (top level, all languages) | |

- Category: **Productivity** (primary), **Reference** (secondary).
- Privacy Policy URL:
  `https://github.com/kccarlos/forumind/blob/main/PRIVACY.md`.
  It must be reachable without logging in, so the repository must be public
  first. A GitHub Pages URL (for example
  `https://kccarlos.github.io/forumind/privacy`) looks nicer if
  you enable Pages later; update `privacy_url.txt` in every locale if you do.
- Support URL: `https://github.com/kccarlos/forumind/issues`.
- Screenshots: `appstore/screenshots/<locale>/`, five for 6.9" iPhone
  (1320 × 2868) and five for 13" iPad (2064 × 2752) in each language. App
  Store Connect scales them for smaller devices. They are generated; see
  [Screenshots](#screenshots) below.
- App icon: comes from the build (`Assets.xcassets/AppIcon`).
- Upload with `release.yml` (`submit_metadata`, `upload_screenshots`) or
  `bundle exec fastlane metadata screenshots:true`.

### Chinese listings

The Simplified and Traditional Chinese listings mirror the English one: the
same name (Forumind, never translated), a translated subtitle, description
(including the non-affiliation disclaimer and the optional, off-by-default
ad blocking), promotional text, release notes, and Chinese keywords
(no "Discourse", no other companies' names, and no words already in the
name or subtitle, which App Store search indexes anyway). The URLs are the
same GitHub pages.

- [ ] **(owner)** A language appears on the App Store only once the version
      has that localization. Either add **Chinese (Simplified)** and
      **Chinese (Traditional)** on the version page in App Store Connect
      (the language menu at the top right of the app's page), or let CI's
      fastlane `deliver` (`release.yml` with `submit_metadata` and
      `upload_screenshots`) create them from the `zh-Hans` and `zh-Hant`
      folders. Then check each listing's text and screenshots in App Store
      Connect.

### Screenshots

The uploaded screenshots are marketing images rendered by
`scripts/brand/render_store_screenshots.sh` from raw simulator captures,
for each store language:

- Raw captures: `appstore/screenshots-raw/<locale>/` with `<locale>` one of
  `en-US`, `zh-Hans`, `zh-Hant` (iPhone 17 Pro Max and iPad Pro 13-inch,
  status bar at 9:41, sample data only; the Chinese sets are taken with the
  app in that language, which switches the sample data to Chinese,
  fictional forums). They sit outside `appstore/screenshots/` because
  fastlane treats every folder there as a language and would upload them.
  How to retake them: [DEVELOPMENT.md](DEVELOPMENT.md#app-store-screenshots).
- Output: `appstore/screenshots/<locale>/`, opaque sRGB PNGs at the exact
  App Store sizes. File names are numbered in App Store order. The renderer
  removes old `iphone*`/`ipad*` files there first.
- Design: a big headline and a short subline at the top, and the capture in
  a thin dark device frame, cropped at the bottom. English captions use SF
  Pro Rounded (black weight); Chinese captions use PingFang SC / PingFang TC
  (Semibold, the heaviest PingFang face), since SF Pro has no Chinese
  glyphs. Slides 1–3 are consecutive slices of one blue-to-purple band, so
  the three screenshots in search results read as one set. Slide 4 reverses
  the gradient, and slide 5 uses the dark icon background.
- `scripts/ci/check-appstore-metadata.sh` checks the sizes, at most ten per
  device class in each locale, that every screenshot locale has a metadata
  folder, and that no PNG has an alpha channel.

Captions are defined per locale in `Captions` in
`scripts/brand/render_store_screenshots.swift`. Captures (same in every
language): iPhone 1 summary, 2 Ask the forum, 3 chat, 4 Forums home,
5 the walkthrough's privacy page; iPad 1 Forums home + summary, 2 Ask the
forum, 3 chat, 4 Manage, 5 Settings › iCloud Sync.

**English (en-US)**

| # | Headline | iPhone subline | iPad subline |
| --- | --- | --- | --- |
| 1 | Catch up in seconds | AI summaries of long forum threads | same |
| 2 | Ask the whole forum | Answers with links to the posts | same |
| 3 | Chat with any topic | Ask follow-ups about any thread | same |
| 4 | Every forum in one app | Pin favorites, share from your browser | Summaries, chats, and watched topics |
| 5 | Private by design (iPhone) / Private & in sync (iPad) | No accounts, no tracking. Optional ad blocking. | No accounts. End-to-end encrypted sync. |

**Simplified Chinese (zh-Hans)**

| # | Headline | iPhone subline | iPad subline |
| --- | --- | --- | --- |
| 1 | 长篇讨论 / 秒懂重点 | AI 总结冗长的论坛讨论 | same |
| 2 | 问遍 / 整个论坛 | 回答附带原帖链接 | same |
| 3 | 任何话题 / 随时追问 | 针对任何讨论串追问细节 | same |
| 4 | 所有论坛 / 一个 App | 置顶常用论坛，从浏览器一键分享 | 摘要、聊天、关注的话题，集中管理 |
| 5 | 隐私 / 从设计开始 (iPhone), 隐私安全 / 跨设备同步 (iPad) | 无需账户，不做跟踪，广告拦截可选 | 无需账户，端到端加密同步 |

**Traditional Chinese (zh-Hant)**

| # | Headline | iPhone subline | iPad subline |
| --- | --- | --- | --- |
| 1 | 長篇討論 / 秒懂重點 | AI 摘要冗長的論壇討論 | same |
| 2 | 問遍 / 整個論壇 | 回答附上原文連結 | same |
| 3 | 任何話題 / 隨時追問 | 針對任何討論串追問細節 | same |
| 4 | 所有論壇 / 一個 App | 釘選常用論壇，從瀏覽器一鍵分享 | 摘要、聊天、追蹤的話題，集中管理 |
| 5 | 隱私 / 從設計開始 (iPhone), 隱私安全 / 跨裝置同步 (iPad) | 無需帳號，不做追蹤，廣告阻擋可選 | 無需帳號，端對端加密同步 |

Keep the headlines to two short lines (they must read at about 300 px wide
in search results; in Chinese, at most five characters per line on iPhone),
make every claim true of the screen shown, and don't put trademarks in the
headlines. Ad and tracker blocking is optional and off by default, so no
caption may promise an ad-free browser.

## 8. App Review information

Fill in App Store Connect › App Review Information **(owner)**: contact
name, phone, and email (these are private, only for App Review; they are not
kept in the repository). No demo account is needed.

App Review asks new apps for this information (Guideline 2.1), so put it in
the Notes up front (the field holds at most 4,000 characters, plain text) and
attach a **screen recording** from a physical device that starts at app
launch and shows the main flow (walkthrough, connecting an AI provider,
opening a forum, a summary, a follow-up question). The Notes should cover:

1. **Screen recording:** what it shows; that the app has no accounts of its
   own (no registration, login or account deletion), no user-generated
   content of its own, and no paid content or in-app purchases.
2. **Purpose and audience:** a reading companion for Discourse forums that
   summarizes long topics, answers follow-up questions, and answers
   questions from a forum search with numbered links to the posts used.
3. **How to use the main features**, step by step: choose Apple
   Intelligence in the walkthrough (no key needed); pin Discourse Meta
   (meta.discourse.org); open a topic › Assistant › Summary › Create summary;
   Chat; Ask the forum; the share extension from Safari; Settings (AI
   models, iCloud Sync, ad blocker off by default, reading pace). Forum
   sign-in is optional and uses the forum's own web login.
4. **External services:** the user's chosen Discourse forums (public pages
   and JSON endpoints, loaded directly); Apple Intelligence by default, or an
   AI service the user connects with their own key, or a local model (Ollama,
   LM Studio); iCloud (CloudKit private database, iCloud Keychain). No
   servers of our own, no analytics, advertising, authentication or payment
   services. Filter lists are bundled.
5. **Regional differences:** none, except that the app isn't offered in
   China mainland and Apple Intelligence availability is set by Apple.
   Interface languages: English, Simplified and Traditional Chinese.
6. **Regulated industries / third-party material:** not applicable; the app
   displays forum pages like a browser and doesn't host content; reporting
   and blocking stay with each forum; not affiliated with Civilized Discourse
   Construction Kit, Inc.; EasyList/EasyPrivacy under CC BY-SA 3.0; link to
   the source code.

If the review device doesn't support Apple Intelligence, reviewers see why in
Settings › AI provider. Don't put a personal API key in the notes: it would
let anyone with the notes spend on your account, and reviewers can evaluate
the app without it.

## 9. Apple Intelligence on Private Cloud Compute

On-device Apple Intelligence needs no special setup. Private Cloud Compute
(PCC) needs a **managed entitlement** that Apple assigns per app (iOS 27 and
later):

- [ ] **(owner)** After the Developer Program and Small Business Program
      enrollments are active and the App ID exists, request the Private Cloud
      Compute capability for `io.github.kccarlos.forumind` from
      [Private Cloud Compute for developers](https://developer.apple.com/private-cloud-compute/)
      (managed capabilities are requested in Certificates, Identifiers &
      Profiles › Identifiers › the App ID › Capability Requests).
- [ ] When Apple approves it, the capability appears on the App ID. Then set
      the repo variable `DC_ENABLE_PCC=YES` so release builds include the
      entitlement and the PCC code path. Leave it unset until then: a build
      that claims an entitlement the App ID doesn't have fails to sign.
- [ ] Mention PCC in the review notes of that version.

Details of how the app chooses between on-device and PCC:
[APPLE_INTELLIGENCE.md](APPLE_INTELLIGENCE.md).

## 10. Submitting

1. Push a tag (`git tag v1.0.0 && git push origin v1.0.0`). CI uploads the
   build to TestFlight.
2. Test the TestFlight build on an iPhone and an iPad (internal testers need
   no review).
3. Upload metadata and screenshots (`release.yml` with `submit_metadata` and
   `upload_screenshots`), then check the listing in App Store Connect.
4. In App Store Connect, pick the build for the version, check App Privacy,
   Age Rating, and review information, and press **Add for Review** (or run
   `release.yml` with `submit_for_review`).
5. Choose manual release, so you decide when it goes live after approval.
   Check the setting again before each submission or resubmission.

After release: bump the version with the next tag; the build number always
increases (it's the workflow run number). Keep `release_notes.txt` updated for
"What's New".
