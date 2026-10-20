import Foundation
import Testing
@testable import Avatar

// The face and speech engine's own tests.

struct VisemeTests {
    @Test(arguments: [
        ("friend", [Viseme.fv, .r, .ee, .consonant]),
        ("mom", [.mbp, .o, .mbp]),
        ("shoe", [.chjsh, .o]),
        ("thought", [.th, .u, .consonant]),
        ("happy", [.ai, .mbp, .ee]),
        ("quick", [.qw, .ai, .consonant]),
        ("pie", [.mbp, .ee]),
    ])
    func sequence(word: String, expected: [Viseme]) {
        #expect(Viseme.sequence(for: word) == expected)
    }

    @Test func punctuationIsIgnored() {
        #expect(Viseme.sequence(for: "pie.") == Viseme.sequence(for: "pie"))
    }

    @Test func wordsWithoutLettersStillMoveTheMouth() {
        #expect(Viseme.sequence(for: "42") == [.ai])
    }

    @Test func repeatedShapesAreMerged() {
        // "t" and "n" are both consonants.
        #expect(Viseme.sequence(for: "tn") == [.consonant])
    }
}

struct MouthShapeTests {
    @Test func interpolationEndpoints() {
        let a = Viseme.rest.shape, b = Viseme.ai.shape
        #expect(a.interpolated(to: b, amount: 0) == a)
        #expect(a.interpolated(to: b, amount: 1) == b)
    }

    @Test func restIsClosedAndVowelsAreOpen() {
        #expect(Viseme.rest.shape.isClosed)
        #expect(Viseme.mbp.shape.isClosed)
        #expect(!Viseme.ai.shape.isClosed)
        #expect(!Viseme.o.shape.opened(by: 0.5).isClosed)
    }
}

struct EmphasisTests {
    private func raises(_ word: String, in text: String) -> Bool {
        Emphasis.raisesBrows((text as NSString).range(of: word, options: .backwards), in: text)
    }

    @Test func firstWordIsStressed() {
        #expect(raises("Hello", in: "Hello there, friend."))
        #expect(raises("Hello", in: "\"Hello there.\""))
    }

    @Test func ordinaryWordsAreNot() {
        #expect(!raises("there", in: "Hello there, friend."))
        #expect(!raises("left", in: "Then I left."))
    }

    @Test func sentencesAndClausesStartStressed() {
        #expect(raises("friend", in: "Hello there, friend."))
        #expect(raises("Then", in: "It rained. Then I left."))
        #expect(raises("Then", in: "It rained. \"Then I left.\""))
    }

    @Test func questionsExclamationsCapitalsAndLongWords() {
        #expect(raises("ready", in: "Are you ready?"))
        #expect(raises("wow", in: "That was, wow!"))
        #expect(raises("NOW", in: "Do it NOW."))
        #expect(raises("amazing", in: "It is amazing here."))
    }

    @Test func singleCapitalLetterIsNotShouting() {
        #expect(!raises("I", in: "Then I left."))
    }

    private func brows(_ word: String, in text: String) -> Double? {
        Emphasis.brows(for: (text as NSString).range(of: word, options: .backwards), in: text)
    }

    @Test func negativeWordsLowerTheBrows() {
        #expect(brows("not", in: "That is not right.")! < 0)
        #expect(brows("don't", in: "I don't know.")! < 0)
        #expect(brows("can’t", in: "We can’t.")! < 0)
        // Lowering wins over the raise a sentence start or capitals would give.
        #expect(brows("But", in: "It works. But slowly.")! < 0)
        #expect(brows("NOT", in: "Do NOT touch.")! < 0)
    }

    @Test func questionsAndExclamationsRaiseHigher() {
        #expect(brows("ready", in: "Are you ready?") == Emphasis.exclaimedLift)
        #expect(brows("wow", in: "That was, wow!") == Emphasis.exclaimedLift)
        #expect(brows("not", in: "Why not?") == Emphasis.exclaimedLift)
        #expect(brows("Hello", in: "Hello there.") == 1)
    }

    @Test func browsRiseOrStayPut() {
        #expect(brows("Hello", in: "Hello there.") == 1)
        #expect(brows("there", in: "Hello there.") == nil)
    }
}

struct BrowRegionTests {
    @Test func browWeightFadesAtTheEnds() {
        let brow = BrowRegion(minX: 100, maxX: 200, top: 0, line: 10, bottom: 20)
        #expect(brow.weight(atX: 100) == 0)
        #expect(brow.weight(atX: 200) == 0)
        #expect(brow.weight(atX: 150) == 1)
        #expect(brow.weight(atX: 110) > 0 && brow.weight(atX: 110) < 1)
    }
}

struct ScriptTests {
    private func moodOf(_ word: String, in script: Script) -> Mood {
        script.mood(at: (script.text as NSString).range(of: word).location)
    }

    @Test func cuesAreRemovedAndApplyUntilTheNext() {
        let script = Script.parse("[happy] Hello there. [sad] I have to go. [neutral] Bye.")
        #expect(script.text == "Hello there. I have to go. Bye.")
        #expect(moodOf("Hello", in: script) == .happy)
        #expect(moodOf("go", in: script) == .sad)
        #expect(moodOf("Bye", in: script) == .neutral)
    }

    @Test func unknownBracketsAreLeftAlone() {
        #expect(Script.parse("See note [1] and [HAPPY] too").text == "See note [1] and too")
    }

    @Test func emojiSetTheirSentencesMood() {
        let script = Script.parse("Well done! 😊 The build broke 😟 again.")
        #expect(script.text == "Well done! The build broke again.")
        #expect(moodOf("done", in: script) == .happy)
        #expect(moodOf("broke", in: script) == .concerned)
    }

    @Test func emoticonsCountButNotInsideWords() {
        let script = Script.parse("That is sad :( really.")
        #expect(script.text == "That is sad really.")
        #expect(moodOf("sad", in: script) == .sad)
        #expect(Script.parse("See https://example.com today").text == "See https://example.com today")
    }

    @Test func feelingWordsSuggestAMood() {
        let script = Script.parse("Congratulations on the release. The tests ran. Unfortunately, the deploy failed.")
        #expect(moodOf("release", in: script) == .happy)
        #expect(moodOf("ran", in: script) == .neutral)
        // "unfortunately" (sad) and "failed" (concerned) tie; the first wins.
        #expect(moodOf("deploy", in: script) == .sad)
    }

    @Test func aGivenMoodOverridesGuessesButNotCues() {
        let script = Script.parse("Great news. [surprised] Really?", mood: .concerned)
        #expect(moodOf("Great", in: script) == .concerned)
        #expect(moodOf("Really", in: script) == .surprised)
    }

    @Test func offsetsAreUTF16() {
        // "é" is one UTF-16 unit, "🚀" (not a mood emoji, so kept) is two.
        let script = Script.parse("Café 🚀 [angry] Stop.")
        #expect(moodOf("Stop", in: script) == .angry)
        #expect(moodOf("Café", in: script) == .neutral)
    }
}

struct SpeakableTextTests {
    @Test func formattingIsNotRead() {
        #expect(SpeakableText.from(markdown: "This is **bold**, *italic*, `code` and ~~gone~~ text.")
                == "This is bold, italic, code and gone text.")
        #expect(SpeakableText.from(markdown: "snake_case_name and 2 * 3 * 4 stay.") == "snake_case_name and 2 * 3 * 4 stay.")
    }

    @Test func structureIsSpokenAsWords() {
        #expect(SpeakableText.from(markdown: "## The plan\n- First step\n- [x] Done step\n1. One\n> Wise words")
                == "The plan First step Done step 1. One Quote: Wise words")
        #expect(SpeakableText.from(markdown: "See [the docs](https://example.com) or https://x.dev/a.") == "See the docs or a link")
        #expect(SpeakableText.from(markdown: "| Name | Age |\n|---|---|\n| Ann | 3 |") == "Name, Age Ann, 3")
        #expect(SpeakableText.from(markdown: "---") == "")
    }

    @Test func codeBlocksAreAnnouncedNotRead() {
        #expect(SpeakableText.from(markdown: "Here:\n```swift\nlet a = 1\nlet b = 2\n```\nDone.")
                == "Here: Code block, 2 lines. Done.")
        // A segment that ends inside a fence.
        #expect(SpeakableText.from(markdown: "```\none line") == "Code block, 1 line.")
        // Mood cues are left for Script.
        #expect(SpeakableText.from(markdown: "[happy] **Great** news!") == "[happy] Great news!")
    }
}
