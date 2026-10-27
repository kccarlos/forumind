import XCTest
@testable import Forumind

final class HTMLTextTests: XCTestCase {
    func testEntitiesDecodeOnceNamedDecimalAndHexUnknownOnesStay() {
        XCTAssertEqual(HTMLText.decodeEntities("Chase Sapphire &#038; Freedom"), "Chase Sapphire & Freedom")
        XCTAssertEqual(
            HTMLText.decodeEntities("Let the games&#8230; begin &rsquo; &#x2019; &amp;#038;"),
            "Let the games… begin ’ ’ &#038;")
        XCTAssertEqual(
            HTMLText.decodeEntities("&bogus; &#0; &#xD800; &#99999999;"),
            "&bogus; &#0; &#xD800; &#99999999;")
        XCTAssertEqual(HTMLText.decodeEntities("&AMP; &Copy; &hellip;"), "& © …")
        XCTAssertEqual(HTMLText.decodeEntities("no entities"), "no entities")
    }

    func testParagraphsBreaksAndListsKeepTheirLineStructure() {
        XCTAssertEqual(
            HTMLText.plainText("<p>One</p><p>Two<br/>three</p><ul><li>a</li><li>b</li></ul>"),
            "One\n\nTwo\nthree\n\n- a\n- b")
    }

    func testBlankLineRunsNeverReachThreeNewlines() {
        let text = HTMLText.plainText("<p>one</p>\n\n\n\n<p></p><p></p><p>two</p><div><div><p>three</p></div></div>")
        XCTAssertFalse(text.contains("\n\n\n"))
        XCTAssertEqual(text, "one\n\ntwo\n\nthree")
    }

    func testLinksKeepTheirAddressUnlessTheTextAlreadyIsTheAddress() {
        XCTAssertEqual(
            HTMLText.plainText(#"<a href="https://x.example/a?b=1&amp;c=2">this deal</a>"#),
            "this deal (https://x.example/a?b=1&c=2)")
        XCTAssertEqual(HTMLText.plainText(#"<a href="https://x.example/">https://x.example/</a>"#), "https://x.example/")
        XCTAssertEqual(HTMLText.plainText(#"<a href="javascript:alert(1)">click</a>"#), "click")
        XCTAssertEqual(HTMLText.plainText(##"<a href="#comment-5">earlier</a>"##), "earlier")
        XCTAssertEqual(HTMLText.plainText("<a href='http://x.example/p'><b>bold</b> label</a>"), "bold label (http://x.example/p)")
    }

    func testQuotesArePrefixedImagesNamedScriptsAndCommentsDropped() {
        XCTAssertEqual(
            HTMLText.plainText("<blockquote><p>quoted</p><p>more</p></blockquote><p>reply</p>"),
            "> quoted\n>\n> more\n\nreply")
        XCTAssertEqual(HTMLText.plainText("<blockquote><p>I &lt;3 this -&gt; that</p></blockquote>"), "> I <3 this -> that")
        XCTAssertEqual(HTMLText.plainText(#"<img src="a.png" alt="the card"><img src="b.png">"#), "[image: the card][image]")
        XCTAssertEqual(HTMLText.plainText("a<script>evil()</script><style>p{}</style><!-- hidden -->b"), "ab")
        XCTAssertEqual(HTMLText.plainText("a<noscript>x</noscript><template><p>t</p></template>b"), "ab")
    }

    func testTextThatIsNotMarkupPassesThroughAndEmptyInputIsEmpty() {
        XCTAssertEqual(HTMLText.plainText("plain 1 < 2 text"), "plain 1 < 2 text")
        XCTAssertEqual(HTMLText.plainText(""), "")
    }

    func testTableCellsAreSeparatedAndTheArticleFixtureEntitiesDecode() {
        XCTAssertEqual(HTMLText.plainText("<table><tr><td>a</td><td>b</td></tr></table>"), "a | b |")
        XCTAssertEqual(
            HTMLText.plainText("<p>Rewards &#038; fees&#8230; it&#8217;s &amp;lt; fine</p>"),
            "Rewards & fees… it’s &lt; fine")
    }

    func testEntityDecodedAngleBracketsAreNotReparsedAsTags() {
        XCTAssertEqual(HTMLText.plainText("<p>use &lt;b&gt;bold&lt;/b&gt;</p>"), "use <b>bold</b>")
    }
}
