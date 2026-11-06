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
            var heard = Set<String>()
            for other in others where overlaps(other, utterance, window: window) {
                heard.formUnion(wordList(other.text))
            }
            let matched = words.filter(heard.contains).count
            return Double(matched) / Double(words.count) < threshold
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

    // MARK: - Helpers

    private static func overlaps(_ a: Utterance, _ b: Utterance, window: TimeInterval) -> Bool {
        a.start - window <= b.end && b.start - window <= a.end
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!".contains(last)
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
