import SwiftUI

/// What polishing changed, character by character: the words Whisper heard
/// that were taken out, and the ones the model put in.
enum TextDiff {
    enum Kind: Equatable {
        case same
        case removed
        case inserted
    }

    struct Segment: Equatable {
        let kind: Kind
        let text: String
    }

    /// Past this many characters a full comparison is not worth its memory;
    /// the two texts are shown whole instead.
    static let limit = 600

    static func segments(from old: String, to new: String) -> [Segment] {
        let a = Array(old), b = Array(new)
        guard a.count <= limit, b.count <= limit else {
            return [Segment(kind: .removed, text: old), Segment(kind: .inserted, text: new)]
        }
        // Longest common subsequence; table[i][j] is the LCS of a[i...] and b[j...].
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Segment] = []
        func add(_ kind: Kind, _ character: Character) {
            if let last = result.last, last.kind == kind {
                result[result.count - 1] = Segment(kind: kind, text: last.text + String(character))
            } else {
                result.append(Segment(kind: kind, text: String(character)))
            }
        }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                add(.same, a[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                add(.removed, a[i]); i += 1
            } else {
                add(.inserted, b[j]); j += 1
            }
        }
        while i < a.count { add(.removed, a[i]); i += 1 }
        while j < b.count { add(.inserted, b[j]); j += 1 }
        return result
    }

    /// How many places were touched, counting a removal next to an insertion as one.
    static func changeCount(_ segments: [Segment]) -> Int {
        var count = 0
        var previous: Kind = .same
        for segment in segments where segment.kind != .same {
            if previous == .same || previous == segment.kind { count += 1 }
            previous = segment.kind
        }
        return count
    }

    /// Removed text struck through in grey, inserted text in `mark`.
    static func attributed(_ segments: [Segment], mark: Color) -> AttributedString {
        var text = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same: break
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = .secondary
            case .inserted:
                piece.foregroundColor = mark
            }
            text.append(piece)
        }
        return text
    }
}
