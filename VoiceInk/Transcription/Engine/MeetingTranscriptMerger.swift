import Foundation

/// Merges two timestamped segment arrays (mic and system audio) into a single
/// speaker-labelled dialogue string.
///
/// Algorithm:
///   1. Trim segment text and discard blank segments.
///   2. Sort all segments by (t0ms, side) — mic (side 0) wins ties with system (side 1).
///   3. Fold consecutive segments from the same side into one turn, joining with " ".
///   4. Render each turn as "\(label): \(text)", joined by "\n\n".
enum MeetingTranscriptMerger {

    static func merge(
        mic: [TranscriptionSegment],
        system: [TranscriptionSegment],
        micLabel: String = "Eu",
        systemLabel: String = "Outro lado"
    ) -> String {
        // 1. Label and filter
        typealias Labeled = (t0ms: Int64, side: Int, label: String, text: String)
        var labeled: [Labeled] = []

        for seg in mic {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            labeled.append((seg.t0ms, 0, micLabel, t))
        }
        for seg in system {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            labeled.append((seg.t0ms, 1, systemLabel, t))
        }

        guard !labeled.isEmpty else { return "" }

        // 2. Sort by (t0ms, side) — mic=0 before system=1 on equal timestamps
        labeled.sort { a, b in
            if a.t0ms != b.t0ms { return a.t0ms < b.t0ms }
            return a.side < b.side
        }

        // 3. Fold consecutive same-side segments into turns
        struct Turn { let label: String; var text: String }
        var turns: [Turn] = []
        for seg in labeled {
            if turns.last?.label == seg.label {
                turns[turns.count - 1].text += " " + seg.text
            } else {
                turns.append(Turn(label: seg.label, text: seg.text))
            }
        }

        // 4. Render
        return turns.map { "\($0.label): \($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: - Repetition loops

    /// Whisper sometimes gets stuck repeating one sentence over silence or noise (the mic
    /// track of a 46-min meeting on 2026-10-15 came out as the same sentence dozens of
    /// times). Within one track, a run of `minRun` or more identical consecutive sentences
    /// (case and punctuation ignored) is collapsed to its first occurrence. Shorter repeats
    /// ("Tchau. Tchau.") are left alone, and segments with nothing removed keep their
    /// original text untouched. Returns how many sentences were removed.
    static func collapseRepeatedSentences(
        _ segments: [TranscriptionSegment],
        minRun: Int = 4
    ) -> (segments: [TranscriptionSegment], removedCount: Int) {
        typealias Item = (segment: Int, sentence: String, key: String)
        var items: [Item] = []
        for (index, segment) in segments.enumerated() {
            for sentence in sentences(in: segment.text) {
                items.append((index, sentence, normalized(sentence)))
            }
        }

        var dropped = Set<Int>()
        var runStart = 0
        for j in 0...items.count {
            guard j == items.count || items[j].key != items[runStart].key else { continue }
            if j - runStart >= minRun, !items[runStart].key.isEmpty {
                dropped.formUnion((runStart + 1)..<j)
            }
            runStart = j
        }
        guard !dropped.isEmpty else { return (segments, 0) }

        var kept = [[String]](repeating: [], count: segments.count)
        var touched = Set<Int>()
        for (j, item) in items.enumerated() {
            if dropped.contains(j) {
                touched.insert(item.segment)
            } else {
                kept[item.segment].append(item.sentence)
            }
        }

        let result = segments.enumerated().map { index, segment in
            guard touched.contains(index) else { return segment }
            return TranscriptionSegment(
                text: kept[index].joined(separator: " "),
                t0ms: segment.t0ms,
                t1ms: segment.t1ms
            )
        }
        return (result, dropped.count)
    }

    /// Splits on `.`, `!`, `?` or `…` (runs of them) followed by whitespace or the end,
    /// so "1.500" stays whole.
    private static func sentences(in text: String) -> [String] {
        let chars = Array(text)
        let terminators: Set<Character> = [".", "!", "?", "…"]
        var result: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if terminators.contains(ch), next == nil || next!.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    private static func normalized(_ sentence: String) -> String {
        sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
