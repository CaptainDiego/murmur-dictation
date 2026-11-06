import Testing
@testable import Murmur
import AVFoundation

private func tokens(_ words: [(String, Double)], length: Double = 0.3) -> [TimedToken] {
    words.map { TimedToken(text: " " + $0.0, start: $0.1, end: $0.1 + length) }
}

@Suite("Meeting transcript")
struct MeetingTranscriptTests {
    @Test("A pause starts a new utterance; sub-word tokens stay joined")
    func splitsOnPauses() {
        var stream = tokens([("Hello", 0), ("every", 0.4)])
        stream.append(TimedToken(text: "one.", start: 0.7, end: 0.9))
        stream += tokens([("Next", 3.0), ("topic", 3.4)])

        let result = MeetingTranscript.utterances(from: stream, speaker: .me)
        #expect(result.map(\.text) == ["Hello everyone.", "Next topic"])
        #expect(result[1].start == 3.0)
    }

    @Test("A long monologue breaks at a sentence end")
    func splitsLongRuns() {
        var stream: [TimedToken] = []
        for second in 0..<40 {
            let text = second == 34 ? "end." : "word"
            stream += tokens([(text, Double(second) * 0.9)])
        }
        let result = MeetingTranscript.utterances(from: stream, speaker: .others)
        #expect(result.count == 2)
        #expect(result[0].text.hasSuffix("end."))
    }

    @Test("Speaker echo picked up by the mic is dropped, real replies are kept")
    func removesEcho() {
        let theirs = [Utterance(speaker: .others, start: 10, end: 14, text: "Can you send the deck by Friday?")]
        let mine = [
            Utterance(speaker: .me, start: 10.3, end: 14.2, text: "can you send the deck by friday"),
            Utterance(speaker: .me, start: 15, end: 17, text: "Sure, I will send it tomorrow."),
        ]
        let kept = MeetingTranscript.removeEcho(from: mine, heardFrom: theirs)
        #expect(kept.map(\.text) == ["Sure, I will send it tomorrow."])
    }

    @Test("Both sides interleave by time and same-speaker pieces join")
    func mergesStreams() {
        let mine = [
            Utterance(speaker: .me, start: 0, end: 2, text: "Hi."),
            Utterance(speaker: .me, start: 2.5, end: 4, text: "Can you hear me?"),
        ]
        let theirs = [Utterance(speaker: .others, start: 5, end: 6, text: "Yes.")]
        let merged = MeetingTranscript.merge(mine, theirs)
        #expect(merged.map(\.text) == ["Hi. Can you hear me?", "Yes."])
        #expect(merged.map(\.speaker) == [.me, .others])
    }

    @Test("Markdown has a timestamp and speaker on every line")
    func rendersMarkdown() {
        let header = MeetingTranscript.Header(
            title: "Weekly sync",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 1800),
            myName: "Diego", model: "Parakeet")
        let markdown = MeetingTranscript.markdown(
            header: header,
            utterances: [
                Utterance(speaker: .me, start: 5, end: 6, text: "Hi."),
                Utterance(speaker: .others, start: 3725, end: 3730, text: "Bye."),
            ])
        #expect(markdown.hasPrefix("# Weekly sync\n"))
        #expect(markdown.contains("(30 min)"))
        #expect(markdown.contains("**[00:00:05] Diego:** Hi."))
        #expect(markdown.contains("**[01:02:05] Others:** Bye."))
    }
}

@Suite("Meet window detection")
struct MeetWindowTests {
    @Test("Meet call titles are recognized, other tabs are not")
    func recognizesMeet() {
        #expect(MeetWindow.isMeet("Meet - abc-defg-hij - Google Chrome - Diego"))
        #expect(MeetWindow.isMeet("Meet – Weekly sync"))
        #expect(MeetWindow.isMeet("Weekly sync - Google Meet"))
        #expect(!MeetWindow.isMeet("Google Meet"))  // the landing page
        #expect(!MeetWindow.isMeet("YouTube - Google Chrome"))
        #expect(!MeetWindow.isMeet("Meeting notes - Google Docs"))
    }

    @Test("Name and code come out of the title")
    func extractsNameAndCode() {
        #expect(MeetWindow.meetingName("Meet - Weekly sync - Google Chrome") == "Weekly sync")
        #expect(MeetWindow.meetingName("Meet - abc-defg-hij - Google Chrome") == nil)
        #expect(MeetWindow.code(in: "Meet - abc-defg-hij") == "abc-defg-hij")
    }
}
