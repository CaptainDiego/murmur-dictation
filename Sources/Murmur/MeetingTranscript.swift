import Foundation

/// A recognized token placed on the meeting clock.
struct TimedToken: Equatable, Sendable {
    /// SentencePiece text: a leading space marks the start of a new word.
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

enum Speaker: Equatable, Sendable {
    /// Whoever is at this Mac (the microphone).
    case me
    /// Everyone else on the call (what the browser plays).
    case others
}

struct Utterance: Equatable, Sendable {
    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Turns two token streams into a readable, timestamped Markdown transcript.
enum MeetingTranscript {
    /// Splits a token stream into utterances at pauses, and also at the end
    /// of a sentence once an utterance has run long, so paragraphs stay
    /// readable when someone talks for minutes without a break.
    static func utterances(
        from tokens: [TimedToken], speaker: Speaker,
        pause: TimeInterval = 1.0, softLimit: TimeInterval = 30
    ) -> [Utterance] {
        var result: [Utterance] = []
        var text = ""
        var start: TimeInterval = 0
        var lastEnd: TimeInterval = 0

        func flush() {
            let cleaned = normalizeSpaces(text)
            if !cleaned.isEmpty {
                result.append(Utterance(speaker: speaker, start: start, end: lastEnd, text: cleaned))
            }
            text = ""
        }

        for token in tokens {
            let startsWord = token.text.hasPrefix(" ")
            if !text.isEmpty, startsWord {
                let gap = token.start - lastEnd
                let longAndSentenceDone = lastEnd - start > softLimit && endsSentence(text)
                if gap > pause || longAndSentenceDone { flush() }
            }
            if text.isEmpty { start = token.start }
            text += token.text
            lastEnd = token.end
        }
        flush()
        return result
    }

    /// Without headphones the microphone also hears the other side through
    /// the speakers, which would show up twice. Drops "me" utterances whose
    /// words mostly match what the others said at the same moment.
    static func removeEcho(
        from mine: [Utterance], heardFrom others: [Utterance],
        window: TimeInterval = 2.0, threshold: Double = 0.6
    ) -> [Utterance] {
        mine.filter { utterance in
            let words = wordList(utterance.text)
            guard words.count >= 3 else {
                // Too short to judge by overlap; drop it only if the others
                // said the exact same thing right then.
                return !others.contains {
                    overlaps($0, utterance, window: window) && wordList($0.text) == words && !words.isEmpty
                }
            }
            // Compare word pairs, not single words: a real echo repeats
            // phrases in order, while two people talking over each other
            // share plenty of single words ("yeah", "the", "so") and that
            // used to throw away the user's own lines.
            var heard = Set<String>()
            for other in others where overlaps(other, utterance, window: window) {
                heard.formUnion(pairs(wordList(other.text)))
            }
            let mine = pairs(words)
            let matched = mine.filter(heard.contains).count
            return Double(matched) / Double(mine.count) < threshold
        }
    }

    /// Interleaves both sides by start time, joining back-to-back pieces from
    /// the same speaker.
    static func merge(_ streams: [Utterance]..., joinGap: TimeInterval = 2.0, maxLength: TimeInterval = 60)
        -> [Utterance]
    {
        let sorted = streams.flatMap { $0 }.sorted { $0.start < $1.start }
        var merged: [Utterance] = []
        for utterance in sorted {
            if let last = merged.last, last.speaker == utterance.speaker,
                utterance.start - last.end < joinGap, utterance.end - last.start < maxLength
            {
                merged[merged.count - 1] = Utterance(
                    speaker: last.speaker, start: last.start, end: max(last.end, utterance.end),
                    text: last.text + " " + utterance.text)
            } else {
                merged.append(utterance)
            }
        }
        return merged
    }

    /// `HH:MM:SS`, always with hours so the column lines up in long calls.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    struct Header {
        var title: String
        var meetingCode: String?
        var startedAt: Date
        var endedAt: Date
        /// e.g. "automatically when you left the call".
        var stoppedHow: String? = nil
        var myName: String
        var model: String
        /// Things the reader should know, e.g. that the other side was silent.
        var notes: [String] = []
    }

    static func markdown(header: Header, utterances: [Utterance]) -> String {
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateFormat = "HH:mm"

        let minutes = max(1, Int((header.endedAt.timeIntervalSince(header.startedAt) / 60).rounded()))
        var out = "# \(header.title)\n\n"
        out += "- **Date:** \(day.string(from: header.startedAt)), "
        out += "\(time.string(from: header.startedAt))–\(time.string(from: header.endedAt)) (\(minutes) min)\n"
        if let stoppedHow = header.stoppedHow {
            out += "- **Stopped:** \(stoppedHow)\n"
        }
        if let code = header.meetingCode {
            out += "- **Meeting:** [\(code)](https://meet.google.com/\(code))\n"
        }
        out += "- **Speakers:** \(header.myName) (this Mac's microphone), Others (audio playing on this Mac)\n"
        out += "- **Transcribed on device by Murmur** · \(header.model)\n"
        for note in header.notes {
            out += "\n> **Note:** \(note)\n"
        }
        out += "\n## Transcript\n\n"
        if utterances.isEmpty {
            out += "_Nothing was heard._\n"
        }
        for utterance in utterances {
            let name = utterance.speaker == .me ? header.myName : "Others"
            out += "**[\(timestamp(utterance.start))] \(name):** \(utterance.text)\n\n"
        }
        return out
    }

    // MARK: - Filler words

    /// Hesitations that carry no meaning anywhere ("uh", "um", French
    /// "euh"). Words like "like" or "you know" often do, so they stay.
    static let fillers: Set<String> = [
        "uh", "uhh", "uhm", "um", "umm", "erm", "er", "ah", "ahh", "hmm", "hm", "mm", "mmm", "euh", "heu",
    ]
    /// Agreement noises: dropped only when they are the whole utterance,
    /// since inside a sentence "mm-hmm" can mean "yes".
    static let backchannels: Set<String> = ["mm-hmm", "mhm", "uh-huh", "mm-mm", "uh-uh"]

    /// Removes filler words, then drops utterances left with nothing to say.
    static func removingFillers(from utterances: [Utterance]) -> [Utterance] {
        utterances.compactMap { utterance in
            let text = removeFillers(utterance.text)
            return text.isEmpty
                ? nil : Utterance(speaker: utterance.speaker, start: utterance.start, end: utterance.end, text: text)
        }
    }

    /// "So, uh, we shipped it. Um, next week." → "So, we shipped it. Next week."
    /// Returns "" when only fillers (or a lone "Mm-hmm.") were said.
    static func removeFillers(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        func core(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(["-"]))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        if words.allSatisfy({ fillers.contains(core($0)) || backchannels.contains(core($0)) }) { return "" }

        // "ERM" or "AH" in capitals is an acronym, not a hesitation.
        func isFiller(_ word: String) -> Bool {
            let letters = word.filter(\.isLetter)
            return fillers.contains(core(word)) && !(letters.count > 1 && letters.allSatisfy(\.isUppercase))
        }

        var kept: [String] = []
        var capitalizeNext = false
        for word in words {
            if isFiller(word) {
                // "So, uh, we" → "So we": the commas only framed the filler.
                if word.hasSuffix(","), let last = kept.last, last.hasSuffix(",") {
                    kept[kept.count - 1] = String(last.dropLast())
                }
                // "it, um." → "it." : the filler's sentence end moves back.
                if let end = word.last, ".?!".contains(end), let last = kept.popLast() {
                    let trimmed = last.hasSuffix(",") ? String(last.dropLast()) : last
                    kept.append(endsSentence(trimmed) ? trimmed : trimmed + String(end))
                }
                // A sentence that began with "Uh, so…" should still start
                // with a capital once the "Uh" is gone.
                if kept.isEmpty || kept.last.map(endsSentence) == true || word.first?.isUppercase == true {
                    capitalizeNext = true
                }
                continue
            }
            var word = word
            if capitalizeNext, kept.isEmpty || kept.last.map(endsSentence) == true {
                word = word.prefix(1).uppercased() + word.dropFirst()
            }
            capitalizeNext = false
            kept.append(word)
        }
        // A filler at the very end can leave a dangling comma.
        if let last = kept.last, last.hasSuffix(",") {
            kept[kept.count - 1] = String(last.dropLast()) + "."
        }
        return kept.joined(separator: " ")
    }

    // MARK: - Helpers

    private static func overlaps(_ a: Utterance, _ b: Utterance, window: TimeInterval) -> Bool {
        a.start - window <= b.end && b.start - window <= a.end
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!".contains(last)
    }

    private static func pairs(_ words: [String]) -> [String] {
        zip(words, words.dropFirst()).map { "\($0) \($1)" }
    }

    static func wordList(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalizeSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
