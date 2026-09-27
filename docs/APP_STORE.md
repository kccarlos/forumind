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

- The name (`appstore/metadata/en-US/name.txt`), the home-screen name
  (`CFBundleDisplayName`), and the bundle ID (`io.github.kccarlos.forumind`)
  are all Forumind.
- "Discourse" appears only descriptively, to say what the app works with:
  the subtitle is `AI for Discourse forums`, and the description says it works
  with any Discourse forum. It is not part of the name and not a keyword.
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

Text lives in `appstore/metadata/` in fastlane `deliver` layout, and
`scripts/ci/check-appstore-metadata.sh` checks the limits in CI:

| File | Limit |
| --- | --- |
| `en-US/name.txt` | 30 |
| `en-US/subtitle.txt` | 30 |
| `en-US/promotional_text.txt` | 170 |
| `en-US/keywords.txt` | 100, comma-separated |
| `en-US/description.txt` | 4000 |
| `en-US/release_notes.txt` | 4000 ("What's New"; not used for the first version) |
| `en-US/privacy_url.txt`, `support_url.txt`, `marketing_url.txt` | URLs |
| `copyright.txt`, `primary_category.txt`, `secondary_category.txt` | |

- Category: **Productivity** (primary), **Reference** (secondary).
- Privacy Policy URL:
  `https://github.com/kccarlos/forumind/blob/main/PRIVACY.md`.
  It must be reachable without logging in, so the repository must be public
  first. A GitHub Pages URL (for example
  `https://kccarlos.github.io/forumind/privacy`) looks nicer if
  you enable Pages later; update `privacy_url.txt` if you do.
- Support URL: `https://github.com/kccarlos/forumind/issues`.
- Screenshots: `appstore/screenshots/en-US/`, five for 6.9" iPhone
  (1320 × 2868) and five for 13" iPad (2064 × 2752). App Store Connect scales
  them for smaller devices.
- App icon: comes from the build (`Assets.xcassets/AppIcon`).
- Upload with `release.yml` (`submit_metadata`, `upload_screenshots`) or
  `bundle exec fastlane metadata screenshots:true`.

## 8. App Review information

Fill in App Store Connect › App Review Information **(owner)**: contact
name, phone, and email (these are private, only for App Review; they are not
kept in the repository). No demo account is needed. Suggested notes:

```text
Forumind is a free, open-source reader for Discourse forums (any
site built on the open-source Discourse forum software) with an AI assistant.
No account or sign-in is required.

How to test:
1. On first launch, the walkthrough offers AI providers. On a device with
   Apple Intelligence turned on, "Apple Intelligence" works without any key.
   (Other providers need the user's own API key; you can skip that step.)
2. Pin a suggested forum, for example meta.discourse.org (the Discourse
   project's public community), or tap Add forum and enter
   meta.discourse.org.
3. Open any topic, tap Assistant, then Summary. Try Chat, and Ask the forum
   (the assistant searches the forum and answers with numbered sources).
4. Share extension: in Safari, open a topic on meta.discourse.org, tap Share,
   choose Forumind, then Summarize.

Notes:
- The built-in browser can open any website (hence the web access age
  rating) and blocks ads/trackers with bundled EasyList/EasyPrivacy lists.
- iCloud sync is automatic when the device is signed in to iCloud: CloudKit
  private database, end-to-end encrypted fields. There is no server of ours.
  To see it, use two devices on one Apple Account; Settings › iCloud Sync
  shows the status.
- The app is not affiliated with Discourse (Civilized Discourse Construction
  Kit, Inc.); it only reads public forum pages and pages the user is logged
  in to.
- Source code: https://github.com/kccarlos/forumind
```

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

After release: bump the version with the next tag; the build number always
increases (it's the workflow run number). Keep `release_notes.txt` updated for
"What's New".
