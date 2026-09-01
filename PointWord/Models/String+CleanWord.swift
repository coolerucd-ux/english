import Foundation

extension String {
    // The clean, display-ready form of an OCR'd word. OCR routinely grabs the
    // sentence punctuation glued to a word ("domain,", "back -") or swallows a
    // leading logo glyph ("▢ Grid"); those symbols are meaningless to the word
    // itself. We strip leading & trailing non-alphanumerics while KEEPING the
    // hyphen/apostrophe that belong inside real words (e-mail, don't, O'Neil).
    //
    // This is the SINGLE source of truth for the word: it's applied where the
    // pointed word is extracted (so the card title, the AI term, the reunion
    // match, the stored SavedWord, and the pronounced text are all the same
    // clean string), and again at display time as a safety net for rows saved
    // before this normalization existed. Detail, photo, and list thumbnail
    // therefore always read identically — no stray "," ever leaks through.
    var cleanedWord: String {
        let junk = CharacterSet.alphanumerics.inverted
        return trimmingCharacters(in: junk.subtracting(CharacterSet(charactersIn: "-'’")))
    }
}
