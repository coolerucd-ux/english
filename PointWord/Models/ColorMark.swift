import Foundation
import CoreGraphics

struct ColorMark: Equatable, Identifiable {
    enum MarkType { case underline, circle }

    let markType: MarkType
    let boundingBox: CGRect    // Vision normalized, bottom-left origin
    let words: [DetectedWord]

    // Stable id derived from the words it covers (so paging/animation stays consistent).
    var id: String { words.map { $0.text }.joined(separator: "|") }

    var combinedText: String {
        words.map { $0.text }.joined(separator: " ")
    }

    // Words joined left-to-right (reading order) — used to look a marked phrase
    // up as one unit. Detection order isn't reliably left-to-right, so sort by minX.
    var phraseText: String {
        words
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            .map { $0.text }
            .joined(separator: " ")
    }

    // True when the mark spans more than one word — treat it as a phrase.
    var isPhrase: Bool { words.count > 1 }

    var primaryWord: String {
        primaryDetected?.text ?? words.first?.text ?? ""
    }

    // The most meaningful word under the mark, with its OCR line as context.
    var primaryDetected: DetectedWord? {
        let trivial: Set<String> = ["the", "a", "an", "of", "in", "on", "at", "to", "for",
                                    "is", "are", "was", "and", "or", "but"]
        return words
            .filter { !trivial.contains($0.text.lowercased()) }
            .max(by: { $0.text.count < $1.text.count })
            ?? words.first
    }

    static func == (lhs: ColorMark, rhs: ColorMark) -> Bool {
        lhs.words.map { $0.text } == rhs.words.map { $0.text }
    }
}
