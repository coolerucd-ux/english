import Foundation

struct WordExplanation {
    let word: String
    let phonetic: String            // /ˌiːvəˈluːʃən/
    let partOfSpeech: String        // 名词
    let meanings: [String]          // ["进化", "演变", "发展"]

    // 语境理解 — 结合指向单词所在的句子给出的解释。
    // 若查词时没有上下文（比如从词库点开），这些字段为空，卡片自动隐藏。
    let contextPhrase: String       // 单词所在的短语/句子，如 "delicate aroma"
    let contextMeaning: String      // 在这句话里的具体含义

    init(
        word: String,
        phonetic: String,
        partOfSpeech: String,
        meanings: [String],
        contextPhrase: String = "",
        contextMeaning: String = ""
    ) {
        self.word = word
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.meanings = meanings
        self.contextPhrase = contextPhrase
        self.contextMeaning = contextMeaning
    }
}
