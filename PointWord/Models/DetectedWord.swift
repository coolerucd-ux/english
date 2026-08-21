import Foundation
import CoreGraphics

struct DetectedWord: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let boundingBox: CGRect  // Vision normalized coords, origin bottom-left
    let confidence: Float
    let context: String      // full OCR line this word belongs to (for语境 lookup)

    init(text: String, boundingBox: CGRect, confidence: Float, context: String = "") {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.context = context
    }

    static func == (lhs: DetectedWord, rhs: DetectedWord) -> Bool {
        lhs.id == rhs.id
    }
}
