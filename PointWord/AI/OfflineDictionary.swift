import Foundation

// Offline fallback dictionary — the safety net for no-network moments (the
// subway being the canonical case: the camera survives interruptions now, but
// the AI lookup still needs the internet). When the streaming AI call fails
// with nothing to show, we fall back to a bundled, compact English→Chinese
// dictionary so the user still gets a basic meaning instead of a dead "retry"
// card.
//
// Data: ~27k common words (exam syllabi + Oxford/Collins high-frequency + top
// frequency ranks) distilled from ECDICT (MIT). Shipped as a compact JSON
// (~2MB) so it packs into the app with zero third-party runtime dependency —
// pure Foundation parsing, which the file-system-synchronized target bundles
// automatically (see the build-membership note in CameraView).
final class OfflineDictionary {
    static let shared = OfflineDictionary()

    // word(lowercased) → (translation, optional phonetic). Nil until loaded.
    private var entries: [String: Entry]?
    private let loadLock = NSLock()

    private struct Entry: Decodable {
        let t: String            // Chinese translation (POS-prefixed, cleaned)
        let p: String?           // IPA phonetic, optional
    }

    private init() {}

    // Kick off a background load so the first offline lookup isn't blocked on a
    // 2MB JSON parse. Safe to call more than once — subsequent calls no-op.
    func preload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.loaded()
        }
    }

    // Look a word up. Returns nil when the dictionary has no entry (or isn't
    // loadable). Tries the word as-is, then a few cheap morphological fallbacks
    // (plural / past / -ing / comparative) so "studies" or "running" still
    // resolve to the base form the dictionary actually stores.
    func lookup(_ raw: String, language: AppLanguage) -> WordExplanation? {
        guard let dict = loaded() else { return nil }

        // Strip surrounding non-letters (OCR sometimes glues a bullet/quote on).
        let word = raw
            .trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "-'")))
            .lowercased()
        guard !word.isEmpty else { return nil }

        for candidate in [word] + morphologicalBases(of: word) {
            if let e = dict[candidate] {
                return explanation(for: raw, entry: e)
            }
        }
        return nil
    }

    // MARK: - Loading

    private func loaded() -> [String: Entry]? {
        loadLock.lock(); defer { loadLock.unlock() }
        if let entries { return entries }
        guard let url = Bundle.main.url(forResource: "offline_dict", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            print("🔴 离线词典加载失败：offline_dict.json 未找到或解析失败")
            entries = [:]                  // cache the empty result so we don't retry every miss
            return entries
        }
        entries = parsed
        print("🟢 离线词典就绪：\(parsed.count) 词")
        return entries
    }

    // MARK: - Morphology
    //
    // Deliberately small and rule-based — enough to catch the common inflections
    // a reader points at, without a stemmer dependency. Order matters: longer,
    // more specific strips first.
    private func morphologicalBases(of w: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if s.count >= 2 { out.append(s) } }

        if w.hasSuffix("ies") { add(String(w.dropLast(3)) + "y") }        // studies → study
        if w.hasSuffix("es")  { add(String(w.dropLast(2))) }              // boxes → box
        if w.hasSuffix("s")   { add(String(w.dropLast(1))) }              // cats → cat
        if w.hasSuffix("ied") { add(String(w.dropLast(3)) + "y") }        // tried → try
        if w.hasSuffix("ed")  {
            add(String(w.dropLast(2)))                                    // walked → walk
            add(String(w.dropLast(1)))                                    // liked → like
        }
        if w.hasSuffix("ing") {
            add(String(w.dropLast(3)))                                    // reading → read
            add(String(w.dropLast(3)) + "e")                             // making → make
        }
        if w.hasSuffix("er")  { add(String(w.dropLast(2))) }              // faster → fast
        if w.hasSuffix("est") { add(String(w.dropLast(3))) }             // fastest → fast

        // Doubled final consonant: running → run, bigger → big, stopped → stop.
        // Strip the inflection, then if the stem ends in a repeated consonant
        // drop one copy.
        let stem: String?
        if w.hasSuffix("ing")      { stem = String(w.dropLast(3)) }
        else if w.hasSuffix("ed")  { stem = String(w.dropLast(2)) }
        else if w.hasSuffix("er")  { stem = String(w.dropLast(2)) }
        else if w.hasSuffix("est") { stem = String(w.dropLast(3)) }
        else                       { stem = nil }
        if let base = stem, base.count >= 3,
           let last = base.last, base.dropLast().last == last {
            add(String(base.dropLast()))
        }
        return out
    }

    // MARK: - Mapping

    private func explanation(for displayWord: String, entry: Entry) -> WordExplanation {
        // The stored translation is one cleaned string like "n. 进化, 发展, 进展".
        // Peel an optional leading POS token off the front so the card can render
        // (pos) meaning the same way the AI result does; split the rest into
        // meanings on common separators.
        let (pos, body) = splitPOS(entry.t)
        let meanings = body
            .split(whereSeparator: { "；;，,、".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return WordExplanation(
            word: displayWord,
            phonetic: entry.p.map { $0.hasPrefix("/") ? $0 : "/\($0)/" } ?? "",
            partOfSpeech: pos,
            meanings: Array(meanings.prefix(3)),
            isOffline: true
        )
    }

    // Peel a leading part-of-speech token ("n.", "adv.", "vt.", "prep.") off the
    // translation so it renders in the (pos) slot instead of inside the meaning.
    private func splitPOS(_ s: String) -> (pos: String, body: String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // Match a short leading alpha token ending in a dot: n. / adj. / vt. / prep.
        if let range = trimmed.range(of: #"^[a-zA-Z]{1,5}\."#, options: .regularExpression) {
            let pos = String(trimmed[range]).replacingOccurrences(of: ".", with: "")
            let body = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (posLabel(pos), body)
        }
        return ("", trimmed)
    }

    // Map the abbreviated English POS to a compact label. Keep it terse — the
    // card shows it in parentheses.
    private func posLabel(_ abbr: String) -> String {
        switch abbr.lowercased() {
        case "n":                 return "n."
        case "v", "vi", "vt":     return "v."
        case "adj", "a":          return "adj."
        case "adv":               return "adv."
        case "prep":              return "prep."
        case "conj":              return "conj."
        case "pron":              return "pron."
        case "art":               return "art."
        case "num":               return "num."
        case "int":               return "int."
        default:                  return abbr + "."
        }
    }
}
