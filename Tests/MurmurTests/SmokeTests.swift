import Testing
@testable import Murmur

@Suite("Key name formatting")
struct KeyNamesTests {
    @Test("Known special keys get their glyph")
    func specialKeys() {
        #expect(KeyNames.name(for: UInt16(36)) == "↩")  // Return
        #expect(KeyNames.name(for: UInt16(49)) == "Space")
    }

    @Test("Function keys are recognized")
    func functionKeyDetection() {
        #expect(KeyNames.isFunctionKey(UInt16(122)))  // F1
        #expect(!KeyNames.isFunctionKey(UInt16(0)))  // 'A'
    }

    @Test("Modifier key codes are recognized")
    func modifierKeyDetection() {
        #expect(KeyNames.isModifierKeyCode(UInt16(55)))  // Command
        #expect(!KeyNames.isModifierKeyCode(UInt16(0)))  // 'A'
    }
}

@Suite("Transcript history")
struct TranscriptHistoryTests {
    @Test("Keeps only the newest five, newest first")
    func capacity() {
        var history = TranscriptHistory(capacity: 5)
        for n in 1...7 { history.add("t\(n)") }
        #expect(history.items == ["t7", "t6", "t5", "t4", "t3"])
    }

    @Test("Shrinking the capacity drops the oldest straight away")
    func shrink() {
        var history = TranscriptHistory(capacity: 25)
        for n in 1...12 { history.add("t\(n)") }
        history.capacity = 10
        #expect(history.items.count == 10)
        history.capacity = 5
        #expect(history.items == ["t12", "t11", "t10", "t9", "t8"])
    }

    @Test("Repeating a transcript moves it to the top instead of duplicating")
    func dedupe() {
        var history = TranscriptHistory()
        history.add("a"); history.add("b"); history.add("a")
        #expect(history.items == ["a", "b"])
    }

    @Test("Blank transcripts are ignored and clear empties it")
    func blankAndClear() {
        var history = TranscriptHistory()
        history.add("  \n")
        #expect(history.isEmpty)
        history.add("hello")
        history.clear()
        #expect(history.isEmpty)
    }

    @Test("Menu preview is one line and truncated")
    func preview() {
        #expect(TranscriptHistory.preview("one\ntwo") == "one two")
        #expect(TranscriptHistory.preview(String(repeating: "x", count: 60), limit: 10) == "xxxxxxxxxx…")
    }
}
