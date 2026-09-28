# Ad and tracker blocking

The in-app browser can block ads and trackers with WebKit **content rule lists**
(`WKContentRuleList`, Safari content-blocker JSON). The rules come from
**EasyList** (ads) and **EasyPrivacy** (trackers). They are converted at
**build time**, and the output is committed to the repo and bundled with the
app. The app contains no filter engine and no Brave code: WebKit does all the
matching from the compiled JSON.

```
easylist.txt ─┐                    adblock-rust (build time)       build_rules.py
easyprivacy ──┴─ update_rules.sh ─► dc-adblock-converter ─► JSON ─► sanitize → validate → dedupe
                                                                   → chunk → manifest + ATTRIBUTION
                                                                   ↓
                                   Forumind/ContentBlocking/ (committed, bundled as a folder)
```

## Output contract

The files live in `Forumind/ContentBlocking/`. The project includes this
directory as a **folder reference**, so it is copied into the bundle as-is and
found like this:

```swift
Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "ContentBlocking")
```

Because it is a folder reference, adding or removing a chunk later does not
require regenerating the Xcode project.

`manifest.json`:

```json
{
  "version": "2026-09-26-67decfe12418",
  "generatedAt": "2026-09-26T05:17:26Z",
  "sources": [
    {"name": "EasyList", "url": "https://easylist.to/easylist/easylist.txt",
     "listVersion": "202609260507", "license": "CC BY-SA 3.0",
     "lastModified": "26 Sep 2026 05:07 UTC", "commit": "…"},
    {"name": "EasyPrivacy", "url": "https://easylist.to/easylist/easyprivacy.txt", …}
  ],
  "lists": [
    {"identifier": "ads-1", "category": "ads", "file": "ads-1.json", "ruleCount": 28602, "sha256": "…"},
    …
  ]
}
```

- `version` is `<UTC date of generation>-<first 12 hex chars of the SHA-256 of all chunk files concatenated in manifest order>`.
  Treat it as an opaque string. It changes only when a chunk's bytes change, so
  it works as the cache key for compiled lists (for example, recompile when the
  stored version differs).
- `category` is `ads` (from EasyList) or `privacy` (from EasyPrivacy), and the
  identifiers are `ads-1…N` and `privacy-1…N`. Each chunk is a standalone,
  valid content-rule-list JSON array with at most 50,000 rules.
- `sha256` and `ruleCount` describe each file exactly. `ContentBlockingRulesTests`
  checks both.
- `lastModified` and `commit` are extra fields copied from the list headers.
- `ATTRIBUTION.md` holds the CC BY-SA attribution. It is regenerated together
  with the chunks.

### Chunk layout (why there are "N+1" files per category)

WebKit compiles and evaluates each rule list **independently**. An
`ignore-previous-rules` exception only cancels earlier rules *in the same
list*. So:

- **Network chunks** (`ads-1`, `ads-2`, `privacy-1`, `privacy-2`): the blocking
  rules are split evenly across these chunks. Each chunk then ends with the
  category's **complete** exception set (`@@…` rules, in source order), plus
  adblock-rust's catch-all "first-party document" exception. That catch-all
  keeps ABP's rule that a page you navigate to is never itself blocked. The
  exceptions are about 0.5–0.9k rules and are repeated in every network chunk.
- **Cosmetic chunk** (last chunk of each category, for example `ads-3`): only
  `css-display-none` rules, with no `ignore-previous-rules`. The catch-all
  document exception matches every top-level page load, so keeping the two
  apart means it can never cancel element hiding.

Enabling a category means adding **all** of its chunks to the
`WKUserContentController`.

## Converter: Brave's adblock-rust (build time only)

The conversion uses **`adblock-rust`** (Brave, MPL-2.0) with its
`content-blocking` feature. A small wrapper
(`scripts/adblock/converter/src/main.rs`, about 40 lines) calls
`FilterSet::into_content_blocking()`. It builds in about 10 s, converts both
lists in under 1 s, and its output compiles in WebKit.

Why not a home-grown converter:

- adblock-rust is the converter Brave uses for its iOS content-blocking lists,
  so it is battle-tested on exactly these lists. That includes the fiddly parts a
  home-grown converter would have to get right: `||`/`|`/`^`/`*` to regex,
  `$third-party`, `$domain=` / `~domain` (it drops rules that mix the two, which
  WebKit can't express), resource types, `@@` ordering, `$subdocument`
  splitting, `#@#` folded into `unless-domain`, punycoding, and rejecting
  `$redirect`, `$csp`, `$removeparam`, `$generichide`, scriptlets and
  procedural cosmetics.
- With the `css-validation` feature, it drops selectors that fail a real CSS
  parser (about 200 in EasyList) before they reach WebKit.
- A custom converter would mean maintaining that same logic, with a long tail
  of edge cases.

How we use it, and what that means for licensing:

- The crate is **not vendored**. `converter/Cargo.toml` pins `adblock = "=0.13.3"`,
  and the committed `Cargo.lock` pins every transitive dependency, so
  `cargo build --locked` reproduces the same converter. To upgrade, bump the
  version, run `cargo update -p adblock`, run `scripts/adblock/run_tests.sh`,
  and run the update script.
- adblock-rust runs **only at build time**. Its MPL-2.0 obligations cover its
  source files, and we neither ship nor modify them. They do not extend to the
  JSON it produces, and nothing from the crate ends up in the app binary.

### Our post-processing (`scripts/adblock/build_rules.py`, stdlib Python)

adblock-rust's output is not trusted blindly. For every rule, the post-processor:

1. **Sanitizes.**
   - Adds `*` to every `if-domain`/`unless-domain` entry, and lowercases and
     punycodes it. ABP `example.com##…` covers subdomains, but WebKit's bare
     `example.com` does not.
   - Rewrites a mid-pattern `\^` to the separator class `[^a-zA-Z0-9_.%-]`.
     adblock-rust 0.13 escapes the ABP separator `^` as a literal caret, which
     never matches a URL; about 380 rules were dead because of this.
   - Rewrites `"resource-type": []` to `["document"]`. adblock-rust 0.13 emits
     `[]` for `$document` filters, and WebKit would read `[]` as "all types";
     this affects about 590 EasyList rules.
   - Sorts arrays so the output is deterministic.
2. **Validates** against WebKit's schema:
   - Action types, trigger keys, and `resource-type`/`load-type` values limited
     to the set iOS 17 accepts.
   - No empty `url-filter`, no empty arrays, and never `if-domain` and
     `unless-domain` together.
   - Domains are lowercase ASCII.
   - `url-filter` stays inside WebKit's regex subset: literals, `.`, `*`, `+`,
     `?`, `[...]`, groups without `|`, `^` only at the start and `$` only at the
     end, and no `{n}`, `\d`, `\b`, back-references or `(?…)`.

   Any rule that fails is dropped and counted. In a normal run this drops a
   handful, for example `wayfair.*` entity domains and `[::1]` IP domains.
3. **De-duplicates** within each category.
4. **Chunks** the rules as described above.
5. **Writes** the chunks as one rule per line, which keeps PR diffs readable. If
   the chunk bytes are identical to what is already committed, it writes
   **nothing**: `generatedAt` and `version` stay the same, so the weekly job
   opens no PR.

## What's shipped (2026-09-26)

| file | rules | size |
|---|---:|---:|
| ads-1.json | 28,602 | 2.92 MB |
| ads-2.json | 28,602 | 3.02 MB |
| ads-3.json (cosmetic) | 13,970 | 1.39 MB |
| privacy-1.json | 28,471 | 3.08 MB |
| privacy-2.json | 28,470 | 3.10 MB |
| privacy-3.json (cosmetic) | 2 | <0.01 MB |
| **total** | **128,117** | **13.5 MB raw, 1.15 MB gzip** |

- **Inputs:** EasyList has 84.3k filters, of which 80.6k converted into 80.7k
  rules. EasyPrivacy has 56.2k filters, of which 56.1k converted.
- **Size:** an IPA is zip-compressed, so the download cost is roughly the gzip
  figure.
- **Compile time:** on the iPhone 17 Pro simulator (M-series Mac), compiling each
  chunk with `WKContentRuleListStore` took 0.05–1.0 s, and all six took about
  3 s. A real device will be several times slower, so compile off the critical
  path and cache by `version`; `lookUpContentRuleList` is near-instant.

### Dropped by design: site-specific element hiding

EasyList has about 10.1k domain-specific hiding rules (`example.com##.sidebar-ad`,
roughly 1.5 MB). We **don't ship** them:

- The in-app browser is built for forum pages. These rules are overwhelmingly
  for news, video, streaming and shopping sites, and each one adds a per-page
  domain check.
- Generic hiding rules (`##.ad`) and all network blocking (which removes the ad
  requests themselves) are kept.
- To include the site-specific rules anyway, run
  `scripts/adblock/update_rules.sh --include-site-cosmetics`.

## In the app

`ContentBlocker.swift` and `AppModel+ContentBlocking.swift` load the bundled
chunks into the browser's `WKUserContentController`:

- **Off by default.** Ads and trackers are both off for new installs and for
  saved settings without the keys, out of respect for forum owners who rely
  on ads. While both are off, the app doesn't look up, compile or attach any
  list, and page loads never wait for them (`ContentRuleLibrary` stays
  `idle`). Turning either on (Settings › Browser, or **Turn on ad blocking**
  in the address-bar shield, which turns on both) starts the lookups or the
  first compile in the background; lists attach as they're ready and the
  page reloads once they are. Settings reads only the manifest, to show the
  lists' date.
- **Caching.** Each chunk is stored in `WKContentRuleListStore` as
  `dc-<list>-<manifest version>-x<exceptions hash>`. A relaunch only looks the
  lists up (near-instant). The first launch, or a new list version, compiles
  them one at a time in the background (about 3 s in total on a simulator) and
  attaches each to the web view as soon as it's ready, so no page load waits
  for compiling; a load waits at most 300 ms for the lookups. Old
  versions are removed from the store afterwards. A chunk that fails to
  compile is logged and skipped.
- **Always allowed.** Because `ignore-previous-rules` only works within one
  list (verified in `ContentBlockerTests`), the app appends an exceptions tail
  to every chunk: first-party `.json`, `/raw/`, `/session`, `/auth/`,
  `/login`, `/u/`, `/message-bus/` and Cloudflare challenge requests (so the
  app's in-page `fetch()` and forum sign-in never break), plus sign-in and
  captcha providers (Google, Apple, GitHub, Discord, Facebook, Microsoft, X,
  reCAPTCHA, hCaptcha, Turnstile).
- **Per-site allow.** While blocking is on, sites the user allows (from the
  shield in the address bar), and sign-in pages such as `accounts.google.com`,
  get no lists while they are the main frame; the switch happens in
  `decidePolicyFor` before each main-frame navigation.
- **Address-bar shield.** Green while blocking on the page, a plain shield
  while blocking is off (its menu offers **Turn on ad blocking**), and a
  slashed shield on an allowed site or a sign-in page.
- **Settings.** Settings › Browser turns ads and trackers on or off
  separately (both off by default). Changes apply at once and reload the
  current page only when they change what is blocked on it.
- WebKit reports no per-page block count, so the app shows none.

## Updating

**Automatically:** `.github/workflows/update-filter-lists.yml` runs every
Monday at 06:17 UTC, and can also be started manually with `workflow_dispatch`.
It:

1. Runs the converter tests.
2. Runs the update script.
3. If `Forumind/ContentBlocking/` changed, opens or updates a PR from
   `bot/update-filter-lists`, committed as `github-actions[bot]`.

**One-time repo setup:** enable Settings → Actions → General → "Allow GitHub
Actions to create and approve pull requests". Without it, the PR step fails.

PRs created with `GITHUB_TOKEN` don't trigger `pull_request` CI. Close and
reopen the PR (or push to it) so that `ContentBlockingRulesTests` compiles the
new chunks before you merge.

**Locally:** you need `curl`, `python3` and a Rust toolchain
(`brew install rust`, or rustup).

```sh
scripts/adblock/update_rules.sh          # download → convert → validate → write (no-op if unchanged)
scripts/adblock/update_rules.sh --force  # rewrite even if unchanged
scripts/adblock/run_tests.sh             # converter tests (cargo test + python unittest)
```

Then run the unit tests (`ContentBlockingRulesTests` compiles every chunk in the
simulator's WebKit) and commit `Forumind/ContentBlocking/`.

**Tests:**

- `scripts/adblock/converter/src/tests.rs` pins adblock-rust's behavior for each
  ABP syntax case we rely on. A crate bump that changes that behavior fails CI.
- `scripts/adblock/tests/test_build_rules.py` covers the regex-subset validator,
  schema checks, sanitizing, chunk/exception layout, determinism, the manifest
  and attribution.
- Both run in the CI `lint` job.

## Licenses

- **EasyList / EasyPrivacy:** The EasyList authors, dual-licensed GPLv3 / **CC
  BY-SA 3.0**; we use the CC BY-SA 3.0 option
  (<https://easylist.to/pages/licence.html>). The bundled JSON is a converted
  derivative. It is distributed under CC BY-SA 3.0 with attribution in
  `Forumind/ContentBlocking/ATTRIBUTION.md`, which the app shows in
  Settings › About › Acknowledgements. See also the repository's `NOTICE`.
- **adblock-rust:** MPL-2.0, used as a build-time tool only (see above).
- **Sources we avoid:** no GPL-only material (uBlock Origin lists, AdGuard
  SafariConverterLib) is used, vendored or shipped.

## Known limitations

- **No scriptlets, `$redirect`, `$csp`, `$removeparam` or procedural cosmetics**
  (`#?#`, `#$#`, `##+js`). Content rule lists can't express them, so ads that
  need script injection to defeat (anti-adblock walls, YouTube-style ads) are
  not handled.
- **Cosmetic filtering is CSS `display: none` only.**
  - Generic hiding rules apply everywhere except where `#@#` exceptions exist.
  - `$generichide` and `$elemhide` exceptions are not supported, and
    site-specific hiding isn't shipped (see above).
  - Hidden elements still take their DOM and network cost unless a network rule
    also blocks them.
- **`$popup` filters aren't converted.**
- **`$document` is approximate.**
  - `||x^$document` blocks document loads, and in practice only third-party
    frames, because of the first-party document exception.
  - `@@…$document` only un-blocks the document request itself, not everything on
    that page.
- **`$important` has no priority** in WebKit. Our exceptions still override
  "important" blocks.
- **`$match-case` filters are skipped** by adblock-rust 0.13 (none in the
  current lists).
- **`^` separators:**
  - A trailing `^` after a hostname is dropped, because WebKit has no
    alternation to express "end or separator". For example, `||ad.com^` also
    matches `ad.company.com`.
  - A `^` in the middle of a pattern becomes a character class (see
    post-processing), which cannot match "end of URL".
- **Rule caps:** WebKit rejects a list with more than 150,000 rules. We cap
  chunks at 50,000, so a failing chunk only loses its own slice and compiles
  stay fast. Enabling both categories puts about 128k rules into the page's
  content-rule-list machinery. WebKit documents no aggregate cap across lists,
  but memory cost scales with the total number of rules.
- **Update cadence:** rules only change when a new build ships (weekly PR,
  then an app release). There is no over-the-air list update.
