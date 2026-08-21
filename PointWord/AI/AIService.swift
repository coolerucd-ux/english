import Foundation

class AIService: ObservableObject {
    private var cache: [String: WordExplanation] = [:]

    // Dedicated session that WAITS for connectivity instead of failing instantly.
    // This matters most on China-region iOS: the very first outbound request pops
    // the system "wireless data" permission dialog, during which the network path
    // is momentarily unusable. URLSession.shared would fail that first request
    // outright; with waitsForConnectivity the request holds until the user grants
    // access, so the first lookup succeeds instead of showing a retry card.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true          // ride through the permission prompt
        config.timeoutIntervalForRequest = 20        // per-request inactivity ceiling
        config.timeoutIntervalForResource = 45       // whole-transfer ceiling
        return URLSession(configuration: config)
    }()

    // Cache key combines word + context + language so the same word in a
    // different sentence or a different native language gets looked up fresh.
    private func key(word: String, context: String, language: AppLanguage) -> String {
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(language.rawValue)::\(word.lowercased())::\(ctx)"
    }

    func cachedResult(for word: String, context: String = "", language: AppLanguage) -> WordExplanation? {
        cache[key(word: word, context: context, language: language)]
    }

    // MARK: - Streaming lookup
    //
    // Emits progressively-more-complete explanations as tokens arrive from the
    // model, so the card can type the answer out (phonetic → meanings → context)
    // instead of waiting for the whole response. The final emission is cached.
    //
    // For a marked phrase (isPhrase), we translate the phrase as a whole and show
    // its overall meaning; phoneticWord anchors the IPA (the longest word).
    func streamLookup(
        _ word: String,
        context: String = "",
        language: AppLanguage,
        isPhrase: Bool = false,
        phoneticWord: String = ""
    ) -> AsyncThrowingStream<WordExplanation, Error> {
        AsyncThrowingStream { continuation in
            let k = self.key(word: word, context: context, language: language)

            // Cache hit — emit once, done. Feels instant.
            if let cached = self.cache[k] {
                continuation.yield(cached)
                continuation.finish()
                return
            }

            let task = Task {
                do {
                    let final = try await self.streamTongyi(
                        word: word, context: context, language: language,
                        isPhrase: isPhrase, phoneticWord: phoneticWord
                    ) { partial in
                        continuation.yield(partial)
                    }
                    self.cache[k] = final
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamTongyi(
        word: String,
        context: String,
        language: AppLanguage,
        isPhrase: Bool,
        phoneticWord: String,
        onPartial: @escaping (WordExplanation) -> Void
    ) async throws -> WordExplanation {
        // One automatic retry: the first attempt can be sacrificed to the iOS
        // network-permission prompt (or a cold Function Compute start). If it
        // fails BEFORE any content streamed, we quietly try once more instead of
        // dropping straight to a "tap to retry" card. Once bytes have arrived we
        // never silently retry — a mid-stream failure keeps the partial result.
        do {
            return try await streamOnce(word: word, context: context, language: language,
                                        isPhrase: isPhrase, phoneticWord: phoneticWord,
                                        onPartial: onPartial)
        } catch {
            if Task.isCancelled { throw error }
            return try await streamOnce(word: word, context: context, language: language,
                                        isPhrase: isPhrase, phoneticWord: phoneticWord,
                                        onPartial: onPartial)
        }
    }

    private func streamOnce(
        word: String,
        context: String,
        language: AppLanguage,
        isPhrase: Bool,
        phoneticWord: String,
        onPartial: @escaping (WordExplanation) -> Void
    ) async throws -> WordExplanation {
        // Talk to our proxy, not DashScope directly — the API key stays
        // server-side. Model and max_tokens are locked by the proxy, so we only
        // send the messages.
        guard let url = URL(string: Config.apiProxyURL) else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Config.appSharedSecret.isEmpty {
            req.setValue(Config.appSharedSecret, forHTTPHeaderField: "x-app-key")
        }

        let prompt = buildPrompt(word: word, context: context, language: language,
                                 isPhrase: isPhrase, phoneticWord: phoneticWord)
        let body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await Self.session.bytes(for: req)
        // A non-200 yields no SSE deltas, so it would otherwise surface as an
        // empty card. Throw so the retry / failed-state path can handle it.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            print("🔴 代理流式状态码：\(http.statusCode)")
            throw URLError(.badServerResponse)
        }

        var accumulated = ""
        for try await line in bytes.lines {
            // Server-Sent Events: "data: {json}" per line, ends with "data: [DONE]".
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }

            if let delta = Self.extractDelta(data) {
                accumulated += delta
                onPartial(parseFields(accumulated, word: word))
            }
        }

        // Final parse — line format first, JSON as fallback if the model ignored it.
        let parsed = parseFields(accumulated, word: word)
        if parsed.meanings.isEmpty {
            return parseWordJSON(accumulated, word: word)
        }
        return parsed
    }

    // Pulls choices[0].delta.content out of one streaming chunk.
    private static func extractDelta(_ data: Data) -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
        return chunk.choices.first?.delta.content
    }

    // MARK: - Prompt
    //
    // Line-based format (not JSON) so partial output stays readable and can be
    // parsed field-by-field as it streams. Word is always English; explanations
    // are in the learner's language; phonetic stays IPA.
    private func buildPrompt(word: String, context: String, language: AppLanguage,
                             isPhrase: Bool, phoneticWord: String) -> String {
        let lang = language.promptName

        // Marked phrase → translate the whole thing; PHON is for the longest word.
        if isPhrase {
            let anchor = phoneticWord.isEmpty ? word : phoneticWord
            return """
            Translate the English phrase "\(word)" for a learner as a whole unit.
            Respond in EXACTLY this line format, nothing else, no extra text:
            PHON: <IPA pronunciation of the word "\(anchor)" only>
            POS: <the phrase's type in \(lang), e.g. phrase / idiom / verb phrase>
            DEF: <the overall meaning of the whole phrase in \(lang), 1-2 short senses separated by ；>
            CTX: <one short sentence in \(lang) explaining how the phrase is used>
            """
        }

        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContext = !ctx.isEmpty && ctx.lowercased() != word.lowercased()

        var lines = """
        Explain the English word "\(word)" for a learner.
        Respond in EXACTLY this line format, nothing else, no extra text:
        PHON: <IPA pronunciation>
        POS: <part of speech in \(lang)>
        DEF: <up to 3 short senses in \(lang), separated by ；>
        """

        if hasContext {
            lines += """

            PHRASE: <a 2-4 word English phrase from the sentence containing the word>
            CTX: <one short sentence in \(lang): what the word means in this sentence: "\(ctx)">
            """
        }
        return lines
    }

    // MARK: - Parsing

    // Parse the line-based format into a WordExplanation. Tolerant of partial
    // input — the last, still-streaming line is parsed as far as it goes.
    private func parseFields(_ raw: String, word: String) -> WordExplanation {
        let cleaned = raw
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var phonetic = "", pos = "", def = "", phrase = "", ctx = ""

        for rawLine in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let v = value(of: "PHON:", in: line) { phonetic = v }
            else if let v = value(of: "POS:", in: line) { pos = v }
            else if let v = value(of: "DEF:", in: line) { def = v }
            else if let v = value(of: "PHRASE:", in: line) { phrase = v }
            else if let v = value(of: "CTX:", in: line) { ctx = v }
        }

        let meanings = def
            .split(whereSeparator: { "；;，,".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return WordExplanation(
            word: word,
            phonetic: phonetic,
            partOfSpeech: pos,
            meanings: Array(meanings.prefix(3)),
            contextPhrase: phrase,
            contextMeaning: ctx
        )
    }

    private func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let body = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return Self.stripListMarkers(body)
    }

    // The model sometimes decorates values with markdown list glyphs
    // (• - * ・ ·) or leading numbering. Strip them so titles/meanings read clean.
    private static func stripListMarkers(_ s: String) -> String {
        var out = s
        let leading: Set<Character> = ["•", "-", "*", "・", "·", "‣", "◦", "–", "—"]
        while let first = out.first, first.isWhitespace || leading.contains(first) {
            out.removeFirst()
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // Fallback: some responses may still come back as JSON.
    private func parseWordJSON(_ raw: String, word: String) -> WordExplanation {
        struct WordJSON: Decodable {
            let phonetic: String
            let pos: String
            let meanings: [String]
            let contextPhrase: String?
            let contextMeaning: String?
        }

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let jsonData = cleaned.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(WordJSON.self, from: jsonData) {
            return WordExplanation(
                word: word,
                phonetic: parsed.phonetic,
                partOfSpeech: parsed.pos,
                meanings: parsed.meanings,
                contextPhrase: parsed.contextPhrase ?? "",
                contextMeaning: parsed.contextMeaning ?? ""
            )
        }
        return WordExplanation(word: word, phonetic: "", partOfSpeech: "", meanings: [cleaned])
    }
}
