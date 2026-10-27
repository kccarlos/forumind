import Foundation

/// What a topic read says about a topic beyond its title, without another
/// request: size, the post-id stream, the opening poster, the accepted answer
/// and the posts the read included (about the first 20 on Discourse).
/// `stream` and `Post.id` are the adapter's own post ids: only the adapter's
/// `postLookup` reads them. Everything else is site-neutral.
struct TopicFacts: Equatable {
    struct Post: Equatable {
        /// Adapter post id (not the post number).
        var id: Int
        var number: Int
        var username: String
        var likeCount: Int?
    }

    struct AcceptedAnswer: Equatable {
        var postNumber: Int
        var username: String?
    }

    var postsCount: Int?
    var highestPostNumber: Int?
    /// Every adapter post id in topic order. Its positions are not post numbers:
    /// deleted posts leave gaps in the numbering.
    var stream: [Int] = []
    var openingPoster: String?
    var acceptedAnswer: AcceptedAnswer?
    var posts: [Post] = []

    /// The id of post `number`, when the JSON included that post.
    func postID(forNumber number: Int) -> Int? {
        posts.first { $0.number == number }?.id
    }

    /// The id of post `number` if known, else a guess: counted along the
    /// stream from the nearest included post before it. Deleted posts after
    /// that one make the guess land later, so callers check the number of
    /// the post that comes back.
    func likelyPostID(forNumber number: Int) -> Int? {
        if let id = postID(forNumber: number) { return id }
        guard number >= 1, !stream.isEmpty else { return nil }
        let anchor = posts
            .filter { $0.number < number }
            .max { $0.number < $1.number }
            .flatMap { post in stream.firstIndex(of: post.id).map { (index: $0, number: post.number) } }
        let index = anchor.map { $0.index + number - $0.number } ?? number - 1
        return stream[min(index, stream.count - 1)]
    }
}
