import Foundation

/// Discourse JSON for the post-level tests, trimmed from public
/// meta.discourse.org responses (October 2026) to the fields Forumind reads.
/// Usernames are replaced with placeholders; post 3 of the topic is removed
/// to stand in for a deleted post, so post numbers have a gap.
enum DiscourseFixtures {
    /// `/search.json?q=…`: three hits in one topic, one in another, and a
    /// hit whose topic is missing from `topics`.
    static let search = #"""
    {"posts":[
      {"id":1172032,"username":"alice","blurb":"I imagine that sidebar customisation will be added in due course, but for now I'...","post_number":1,"topic_id":240488},
      {"id":1172723,"username":"bob","blurb":"Hello, You can hide it with this. :slightly_smiling_face: .sidebar-section-link-...","post_number":5,"topic_id":240488},
      {"id":2053909,"username":"carol","blurb":"That's cool! How did you build it, just have an agent have a go at it? I used th...","post_number":13,"topic_id":415035},
      {"id":1198342,"username":"bob","blurb":"https://meta.discourse.org/t/how-can-i-hide-the-badges-link-in-the-sidebar/24048...","post_number":10,"topic_id":240488},
      {"id":1,"username":"zed","blurb":"orphan","post_number":2,"topic_id":999}
    ],"topics":[
      {"id":240488,"title":"How can I hide the Badges link in the sidebar?","fancy_title":"How can I hide the Badges link in the sidebar?","slug":"how-can-i-hide-the-badges-link-in-the-sidebar","posts_count":11,"last_posted_at":"2022-11-21T09:57:55.135Z"},
      {"id":415035,"title":"A sense of place: Meta's new sidebar","fancy_title":"A sense of place: Meta&rsquo;s new sidebar","slug":"a-sense-of-place-metas-new-sidebar","posts_count":9,"last_posted_at":"2026-10-20T21:00:50.293Z"}
    ]}
    """#

    /// `/t/240488.json`: solved (current Solved plugin, `accepted_answers`),
    /// anonymous (`like_count` is null), with a gap after post 2.
    static let topic = #"""
    {"id":240488,"title":"How can I hide the Badges link in the sidebar?","slug":"how-can-i-hide-the-badges-link-in-the-sidebar","posts_count":10,"highest_post_number":14,"details":{"created_by":{"username":"alice"}},"accepted_answers":[{"post_number":5,"username":"bob"}],
    "post_stream":{"stream":[1172032,1172635,1172700,1172723,1172726,1187644,1198319,1198340,1198342,1198348,1198558,1198580,1534270],"posts":[
      {"id":1172032,"post_number":1,"username":"alice","like_count":null,"accepted_answer":false,"topic_accepted_answer":true,"actions_summary":[{"id":2,"count":2}]},
      {"id":1172635,"post_number":2,"username":"dave","like_count":null,"accepted_answer":false,"topic_accepted_answer":true,"actions_summary":[{"id":2,"count":1}]},
      {"id":1172700,"post_number":4,"username":"alice","like_count":null,"accepted_answer":false,"topic_accepted_answer":true,"actions_summary":[{"id":2,"count":1}]},
      {"id":1172723,"post_number":5,"username":"bob","like_count":null,"accepted_answer":true,"topic_accepted_answer":true,"actions_summary":[{"id":2,"count":6}]},
      {"id":1172726,"post_number":6,"username":"alice","like_count":null,"accepted_answer":false,"topic_accepted_answer":true,"actions_summary":[{"id":2,"count":3}]},
      {"id":1187644,"post_number":7,"username":"system","like_count":null,"accepted_answer":false,"topic_accepted_answer":true,"actions_summary":[]}
    ]}}
    """#

    /// `/t/240488/posts.json?post_ids[]=1198342&post_ids[]=1172723`, in the
    /// order the forum returned them.
    static let posts = #"""
    {"post_stream":{"posts":[
      {"id":1198342,"post_number":10,"username":"bob","like_count":null,"actions_summary":[{"id":2,"count":1}],"cooked":"<p><a href=\"https://meta.discourse.org/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488/5\">This</a> still works for me on the latest version.</p>\n<p><div class=\"lightbox-wrapper\"><a class=\"lightbox\" href=\"https://example.com/x.png\" title=\"Screenshot\"><img src=\"https://example.com/x.png\" alt=\"Screenshot\" width=\"690\" height=\"200\"><div class=\"meta\"><span class=\"filename\">Screenshot</span><span class=\"informations\">834×242 28.2 KB</span></div></a></div></p>\n<hr>\n<p>Can you share your code? Q&amp;A &#8212; thanks&hellip;</p>"},
      {"id":1172723,"post_number":5,"username":"bob","like_count":null,"actions_summary":[{"id":2,"count":6}],"cooked":"<p>Hello,</p>\n<p>You can hide it with this. <img src=\"https://emoji.discourse-cdn.com/twitter/slightly_smiling_face.png?v=15\" title=\":slightly_smiling_face:\" class=\"emoji\" alt=\":slightly_smiling_face:\" loading=\"lazy\" width=\"20\" height=\"20\"></p>\n<pre data-code-wrap=\"scss\"><code class=\"lang-scss\">.sidebar-section-link-wrapper {\n  .sidebar-section-link.sidebar-section-link-badges {\n    display: none;\n  }\n}\n</code></pre>"}
    ]}}
    """#
}
