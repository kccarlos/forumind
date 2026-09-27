# Security Policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them
privately through GitHub:

1. Go to <https://github.com/kccarlos/forumind/security/advisories/new>
   (the repository's **Security** tab › **Report a vulnerability**).
2. Describe the issue, how to reproduce it, and what an attacker could do.

Only the maintainers can see the report. You'll get a reply as soon as
possible, usually within a week, and we'll keep you updated until it's fixed.
If you'd like, you'll be credited in the advisory.

## Scope

In scope: the iOS app, its share extension, and the build and release
tooling in this repository. Examples of what we care about:

- API keys, forum cookies, or synced data leaking to anyone other than the
  forum or AI provider the user chose
- Deep links (`forumind://`) or shared content that start actions the
  user didn't ask for
- Weaknesses in the encryption of iCloud sync files
- Ways for a web page in the built-in browser to reach the app's data

Out of scope: vulnerabilities in Discourse itself (report those to
the Discourse team, see [meta.discourse.org](https://meta.discourse.org)), in
AI providers' services,
or in iOS.

## Supported versions

Security fixes go into the latest App Store release and the `main` branch.
