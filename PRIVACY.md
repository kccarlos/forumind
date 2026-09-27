# Privacy Policy

**Forumind for iPhone and iPad**
Effective date: September 26, 2026

Forumind is a free, open-source app that helps you read Discourse
forums with an AI assistant. This policy explains, in plain words, what the
app does with your information. The short version: **the developer collects
nothing.** There are no Forumind servers, accounts, analytics,
advertising, or tracking.

## What the app handles, and where it goes

### Forum pages and your forum login

The app has a built-in web browser. When you open a forum, the page loads
directly from that forum, as it would in Safari. If you log in to a forum, the
forum's login cookies are stored on your device by iOS's web view and are sent
**only to that forum**, never to another site.

When you ask for a summary, a chat answer, or an Ask the forum search, the app
reads the forum's posts directly from the forum, using your login if you're
logged in, so it can read what you can read.

### Your AI provider

To summarize or answer, the app sends the relevant forum posts and your
question to the AI service **you** choose:

- **Apple Intelligence** (where available): requests are processed by Apple's
  on-device model, or by Apple's **Private Cloud Compute**, which Apple
  designed so that your data is used only to fulfill your request and isn't
  stored or made accessible to Apple. See Apple's privacy information on
  Apple Intelligence.
- **A provider you connect** (for example OpenAI, Anthropic, Google Gemini,
  OpenRouter, Groq, xAI, DeepSeek, or NVIDIA NIM): requests go straight from
  your device to that provider using your own API key, and that provider's
  privacy policy applies to what you send it.
- **A model on your own computer** (Ollama or LM Studio): requests go to that
  computer over your local network and nowhere else.

Nothing is sent to an AI service until you start a summary, chat, or search,
or turn on automatic summary refresh for a watched topic.

### What's stored on your device

- Your summaries, chats, Ask the forum runs, watched topics, forums, and
  settings are stored in the app's private storage on your device.
- Chats and activity you haven't marked **Keep** are cleared after a day;
  summaries are kept up to a limit. You can delete data per forum, or
  everything, in **Settings › Data & privacy**.
- **API keys** are stored in the iOS Keychain, not in the app's data file.
  If **Sync API keys** is on (the default), they are stored in **iCloud
  Keychain** so your other devices can use them. Apple end-to-end encrypts
  iCloud Keychain.

### iCloud sync (optional)

If you choose a folder in **Settings › iCloud Sync**, the app writes your
forums, summaries, chats, Ask the forum runs, watched topics, and settings to
that folder in **your own iCloud Drive**. Every file is encrypted on your
device (AES-GCM) with a key kept in your iCloud Keychain, so iCloud Drive
stores only encrypted files. The developer has no access to your iCloud
account, the folder, or the key. Stop syncing at any time in Settings, and
delete the folder in the Files app to remove the synced copies.

### Notifications

If you watch a topic and allow notifications, the app checks that topic on
the forum (including in the background, when iOS allows) and shows a local
notification about new replies. Notifications are created on your device; no
push notification service is used.

### Ad and tracker blocking

The browser blocks ads and trackers using filter lists that are **bundled
with the app** (EasyList and EasyPrivacy). Blocking happens on your device;
the app doesn't send your browsing to any list provider. You can turn blocking
off, or allow a site, in **Settings › Browser**.

### Sharing to the app

When you share a page from Safari, Chrome, or another app to
Forumind, the share extension passes the page's address and title to the app
on your device. Nothing else is read from the sharing app.

## What the developer collects

Nothing. The app has no analytics, crash-reporting SDK, advertising, or
tracking, and no third-party code. The developer does not operate servers
that receive your data. The app does not track you across apps or websites.

If you choose to share crash reports and usage data with app developers in
iOS Settings, Apple may provide the developer with anonymous crash reports
through App Store Connect; that is controlled by you in iOS and by Apple's
privacy policy.

## Children

The app is not directed at children. It includes a web browser that can open
any website.

## Open source

The app's complete source code is public at
<https://github.com/kccarlos/forumind>, so anyone can check what it
does.

## Changes

If this policy changes, the new version will be posted at this address with a
new effective date. The history of changes is visible in the repository.

## Contact

Questions or concerns: open an issue at
<https://github.com/kccarlos/forumind/issues>. To report something
privately, use
<https://github.com/kccarlos/forumind/security/advisories/new>.
