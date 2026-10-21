# Privacy Policy

**Forumind for iPhone and iPad**
Effective date: October 6, 2026

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
  Google Vertex AI, OpenRouter, Groq, xAI, DeepSeek, or NVIDIA NIM): requests go straight from
  your device to that provider using your own API key, and that provider's
  privacy policy applies to what you send it.
- **A model on your own computer** (Ollama or LM Studio): requests go to that
  computer over your local network and nowhere else.

Nothing is sent to an AI service until you start a summary, chat, search, or
voice session, make a daily digest or its podcast (or turn on the daily
digest or podcast, which are made when you open the app), use read aloud
with Google's voices, or turn on automatic summary refresh for a watched
topic.

### Live voice (optional)

Voice lets you talk to the app about the forum page you're reading. It is off
until you turn it on or tap the microphone in the browser bar, and the app
asks for your consent, naming Google, before the first session with each
provider.

- While a session runs, your voice (the microphone audio) and the page
  content you ask about (post text, titles, and search results) go straight
  from your device to **Google** (Gemini Live, through Google AI Studio or
  Google Vertex AI) with your own API key. There is no Forumind server in
  between.
- On the **free tier of Google AI Studio**, Google's terms allow it to use
  what you send to improve its products, and people may review it. Don't
  say or open anything you want to keep private. Paid AI Studio use and
  Vertex AI follow Google's paid-service terms. See the
  [Gemini API Additional Terms of Service](https://ai.google.dev/gemini-api/terms)
  and the
  [Google Cloud Service Specific Terms](https://cloud.google.com/terms/service-terms).
- The app doesn't record or keep the audio. It keeps only the minutes you
  were connected, on this device, for the time limits in
  **Settings › Voice**. You can withdraw consent there.
- The microphone is used only during a session (and, as before, when a forum
  page asks to record a video). iOS shows the microphone indicator while it
  is on, including when the screen is locked during a session.

### Podcast and read aloud (optional)

The Today page can turn your digest into a short spoken podcast, and
summaries and digest cards can be read aloud.

- The podcast's script is written by your AI provider, like the digest
  itself, from the digest's cards and the topics they're about.
- Reading it out uses either **this device's voices**, which are free, work
  offline and send nothing, or **Google's voices** (Gemini text-to-speech,
  through Google AI Studio or Google Vertex AI) when you have a Google key.
  With Google's voices, the text to be spoken (the script, a summary or a
  card) goes straight from your device to Google with your own API key. No
  audio is recorded. The app asks for your consent, naming Google, before it
  first sends text this way. You can withdraw that consent in **Settings ›
  Daily digest**, separately from the voice consent.
- The same free-tier terms apply as for voice: on the free tier of Google AI
  Studio, Google may use what you send to improve its products, and people
  may review it.
- The podcast is made only while the app is open. Making it every day is off
  until you turn it on.
- The audio is kept in the app's cache on your device, with its digest, for
  at most 7 days. It is deleted with its digest. iOS may also clear it.

### What's stored on your device

- Your summaries, chats, Ask the forum runs, watched topics, forums, and
  settings are stored in the app's private storage on your device.
- **Daily digests** (the last 7), the forum data fetched for them, and their
  podcast audio stay on your device; they aren't synced. Delete them in
  **Settings › Daily digest**.
- Chats and activity you haven't marked **Keep** are cleared after a day;
  summaries are kept up to a limit. You can delete data per forum, or
  everything, in **Settings › Data & privacy**.
- **API keys** are stored in the iOS Keychain, not in the app's data file.
  If **Sync API keys** is on (the default), they are stored in **iCloud
  Keychain** so your other devices can use them. Apple end-to-end encrypts
  iCloud Keychain. Keys never go into the CloudKit database.

### iCloud sync

When your device is signed in to iCloud, the app syncs your forums,
summaries, chats, Ask the forum runs, watched topics, and settings between
your devices through **Apple CloudKit**, in the app's **private database in
your own iCloud account**. The content (forum names and addresses, topic
titles, summaries, chats, answers, and settings) is stored in CloudKit's
end-to-end encrypted fields, with keys held by your devices; Apple and the
developer can't read it. Like any CloudKit data, each record also has
unencrypted metadata that CloudKit needs to work, such as its type, an
identifier, and when it changed.

The developer has no access to your iCloud account or to your private
database: CloudKit gives the developer no way to read a user's private data.
The data counts toward your iCloud storage. Turn sync off in **Settings ›
iCloud Sync**, and use **Delete iCloud data** there to remove the app's data
from iCloud on all your devices (data on each device is kept).

CloudKit tells the app about changes from your other devices with silent
push notifications from Apple, which carry no content and show nothing on
screen.

### Notifications

If you watch a topic and allow notifications, the app checks that topic on
the forum (including in the background, when iOS allows) and shows a local
notification about new replies. If you turn on the daily digest, the app
reads your pinned forums' topic lists and your watched topics on the forums
in the background while the device is charging and online, without any AI
request, and can show a local notification that the digest is ready to
make. These notifications are created on your device; they don't go through
a push notification service.

### Ad and tracker blocking

The browser can block ads and trackers using filter lists that are **bundled
with the app** (EasyList and EasyPrivacy). Blocking is **off by default**, out
of respect for forum owners who rely on ads; turn it on, or allow a site, in
**Settings › Browser** (or from the shield in the address bar). Blocking
happens on your device; the app doesn't send your browsing to any list
provider.

### Moderation

You can block forum users and filter words (**Settings › Data & privacy**);
these choices are stored with your settings (and synced with them). Once a
day the app downloads the developer's public list of removed content
(<https://github.com/kccarlos/forumind/tree/main/moderation>) from GitHub;
this is a plain request for a public file and sends nothing about you.

If you report content (**⋯ › Report or block**), your email app opens with a
report to the developer that includes the forum, topic or post link, the
reason, and any details you add. It's sent only if you send it, from your
own email account, and is used only to review the report.

### Sharing to the app

When you share a page from Safari, Chrome, or another app to
Forumind, the share extension passes the page's address and title to the app
on your device. Nothing else is read from the sharing app.

## What the developer collects

Nothing, apart from reports you choose to email (see Moderation). The app has no analytics, crash-reporting SDK, advertising, or
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
