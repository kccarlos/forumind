# Moderation list

`blocklist.json` is the developer's list of content removed from Forumind for
every user. The app downloads it at most once a day (a plain request for this
public file; nothing about the user is sent) and hides what it lists, in the
built-in browser and in everything sent to an AI provider.

Reports sent from the app (⋯ › Report or block) are reviewed within 24 hours.
Content found to break the [Terms of Use](../TERMS.md) is added here, and the
report is passed on to the forum's own moderators when appropriate.

```json
{
  "version": 1,
  "users": [{ "site": "https://forum.example.com", "username": "someone" }],
  "posts": [{ "site": "https://forum.example.com", "topic": 123, "post": 4 }],
  "words": ["a phrase"]
}
```

- `users`: hides everything the user posts on that forum; leave out `site` to
  hide the username on every forum.
- `posts`: hides one post (topic ID and post number).
- `words`: hides posts containing the word or phrase, on every forum.
