import Testing
@testable import Avatar

struct ListeningCuesTests {
    /// Cues whose nod gaps come from `gaps`, in turn.
    private func cues(_ gaps: [Double] = [3]) -> ListeningCues {
        var next = gaps.makeIterator()
        return ListeningCues { next.next() ?? 3 }
    }

    @Test func smallNodsNeedNewWordsAndTheirGap() {
        var cues = cues([3, 2.5])
        let nod1 = cues.heard(words: 2, at: 0)
        #expect(!nod1)  // too few words
        let nod2 = cues.heard(words: 3, at: 0.5)
        #expect(nod2)  // the first nod needs only the words
        let nod3 = cues.heard(words: 7, at: 2)
        #expect(!nod3)  // words enough, but within the 2.5 s gap
        let nod4 = cues.heard(words: 8, at: 3.1)
        #expect(nod4)
        let nod5 = cues.heard(words: 9, at: 9)
        #expect(!nod5)  // the gap passed, but only one new word
    }

    @Test func aNewPhraseCountsItsWordsAfresh() {
        var cues = cues([0, 0, 0])
        let nod6 = cues.heard(words: 5, at: 0)
        #expect(nod6)
        cues.phraseEnded(at: 1)
        let nod7 = cues.heard(words: 2, at: 2)
        #expect(!nod7)
        let nod8 = cues.heard(words: 3, at: 2.2)
        #expect(nod8)
    }

    @Test func hearingLastsASecondAfterTheLastWord() {
        var cues = cues()
        #expect(!cues.isHearing(at: 0))
        _ = cues.heard(words: 1, at: 10)
        #expect(cues.isHearing(at: 10.9))
        #expect(!cues.isHearing(at: 11.1))
    }

    @Test func aPauseBringsABriefGlanceThatWordsCancel() {
        var cues = cues()
        _ = cues.heard(words: 1, at: 0)
        #expect(!cues.isGlancing(at: 0.5))
        #expect(cues.isGlancing(at: 0.8))
        #expect(!cues.isGlancing(at: 1.4))
        #expect(cues.isActive(at: 1.2))
        #expect(!cues.isActive(at: 1.4))
        _ = cues.heard(words: 2, at: 2)
        #expect(!cues.isGlancing(at: 2.1))
    }

    @Test func listeningPoseFollowsTheCues() {
        #expect(PresencePose.target(for: .listening) == .listening)
        #expect(PresencePose.target(for: .listening, hearing: true).brows > PresencePose.listening.brows)
        #expect(PresencePose.target(for: .listening, glancing: true).lids > 0)
        #expect(PresencePose.target(for: .thinking, hearing: true, glancing: true) == .thinking)
    }
}

@MainActor
struct NodTests {
    @Test func aNodMovesTheHeadNotTheShoulders() {
        for portrait in Portrait.all {
            let shift = { (y: Double) in portrait.nodShift(atY: y, nod: 4) }
            #expect(shift(0) == 0)                                  // the top of the frame stays
            #expect(shift(portrait.brows[0].line) == 4)             // the brows dip the most
            #expect(shift(portrait.chinY) < 4 && shift(portrait.chinY) > 1)
            #expect(shift(portrait.neckY) == 0)                     // the collar and shoulders stay
            #expect(shift(portrait.size.height - 1) == 0)
            #expect(portrait.nodShift(atY: portrait.chinY, nod: 0) == 0)
        }
    }
}
