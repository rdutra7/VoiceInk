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
}
