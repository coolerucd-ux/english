import Foundation
import SwiftData

// A word the user chose to save. Persisted with SwiftData.
@Model
final class SavedWord {
    @Attribute(.unique) var word: String
    var phonetic: String
    var partOfSpeech: String
    var meanings: [String]
    // 语境理解 — 保存时随单词一起存下，详情页复原识别时的上下文解释。
    // 默认空串，让 SwiftData 对旧数据做轻量迁移，老记录这两个字段为空。
    var contextPhrase: String = ""
    var contextMeaning: String = ""
    var createdAt: Date
    // JPEG of the camera frame at save time — used as the library card background.
    @Attribute(.externalStorage) var snapshot: Data?

    init(word: String, phonetic: String, partOfSpeech: String, meanings: [String], contextPhrase: String = "", contextMeaning: String = "", snapshot: Data? = nil, createdAt: Date = .now) {
        self.word = word
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.meanings = meanings
        self.contextPhrase = contextPhrase
        self.contextMeaning = contextMeaning
        self.snapshot = snapshot
        self.createdAt = createdAt
    }

    convenience init(from exp: WordExplanation, snapshot: Data? = nil) {
        self.init(
            word: exp.word,
            phonetic: exp.phonetic,
            partOfSpeech: exp.partOfSpeech,
            meanings: exp.meanings,
            contextPhrase: exp.contextPhrase,
            contextMeaning: exp.contextMeaning,
            snapshot: snapshot
        )
    }
}
