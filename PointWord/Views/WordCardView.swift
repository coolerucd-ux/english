import SwiftUI
import SwiftData

enum WordCardState: Equatable {
    case loading(String)
    case loaded(WordExplanation)
    case failed(String)

    var word: String {
        switch self {
        case .loading(let w): return w
        case .loaded(let e): return e.word
        case .failed(let w): return w
        }
    }

    static func == (lhs: WordCardState, rhs: WordCardState) -> Bool {
        switch (lhs, rhs) {
        case (.loading(let a), .loading(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        case (.loaded(let a), .loaded(let b)): return a.word == b.word
        default: return false
        }
    }
}

struct WordCardView: View {
    let state: WordCardState
    var language: AppLanguage = .zhHans
    var compact: Bool = false                 // secondary results render compact
    var snapshot: Data? = nil                 // camera frame frozen at recognition, saved with the word
    var isStreaming: Bool = false             // answer still typing in — shows a blinking cursor
    var onClose: (() -> Void)? = nil
    var onSaved: (() -> Void)? = nil           // fired when a word is newly saved (drives top flash)
    var onRemoved: (() -> Void)? = nil         // fired when a saved word is un-saved (detail view pops back)
    var onRetry: (() -> Void)? = nil           // fired when tapping a failed card to look up again

    @Environment(\.modelContext) private var context
    @Query private var saved: [SavedWord]

    private var isSaved: Bool {
        saved.contains { $0.word.lowercased() == state.word.lowercased() }
    }

    // OCR sometimes swallows a logo glyph / bullet into the word (e.g. the cup's
    // "▢ Grid Coffee") or glues on sentence punctuation ("domain,"). Show the
    // cleaned form so the title reads clean; the same normalization is applied at
    // extraction and save time, so this only ever re-cleans legacy dirty rows.
    private var displayTitle: String {
        state.word.cleanedWord
    }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkPanel(cornerRadius: compact ? 18 : 24)
        .shadow(color: .black.opacity(0.25), radius: compact ? 8 : 18, y: 6)
    }

    // MARK: - Full card (primary result)

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayTitle)
                    .font(.title2.bold())
                    .foregroundColor(.white)

                // Tag a no-network fallback result so the user knows this is a
                // basic offline meaning, not the usual contextual AI explanation.
                if case .loaded(let exp) = state, exp.isOffline {
                    Text(language.offlineBadge)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
            }

            content

            // Action row — 🔊 pronounce + ♥ save, evenly spaced. Appears once streaming settles.
            // These are the card's PRIMARY, high-frequency actions, so they're
            // deliberately kept LARGE (36pt) — bigger than the 20pt chrome icons
            // (back / globe / close). Consistency there is about header chrome; here
            // the priority is an easy, obvious tap target.
            if case .loaded(let exp) = state, !isStreaming {
                HStack {
                    Spacer()
                    Button {
                        SpeechService.shared.speak(exp.word)
                    } label: {
                        SpeakingVolumeIcon(word: exp.word)
                            .frame(width: 36, height: 36)
                            .foregroundColor(.white.opacity(0.9))
                    }
                    Spacer()
                    Button {
                        toggleSave(exp)
                    } label: {
                        Image(isSaved ? "IconHeartFilled" : "IconHeart")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .foregroundColor(.white.opacity(isSaved ? 1 : 0.9))
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .animation(.easeInOut(duration: 0.2), value: isStreaming)
    }

    // MARK: - Compact card (folded secondary results)

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(.title3.bold())
                .foregroundColor(.white)
                .lineLimit(1)

            if case .loaded(let exp) = state {
                // Second line: phonetic (mono, gray) + (pos) + meanings.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !exp.phonetic.isEmpty {
                        Text(exp.phonetic)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    if !exp.meanings.isEmpty {
                        Text((exp.partOfSpeech.isEmpty ? "" : "(\(exp.partOfSpeech)) ")
                             + exp.meanings.prefix(3).joined(separator: "；"))
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            } else if case .loading = state {
                Text(language.loadingWord)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Full content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8).tint(.white)
                Text(language.loadingWord)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }

        case .loaded(let exp):
            // Phonetic on its own line, right under the word.
            if !exp.phonetic.isEmpty {
                Text(exp.phonetic)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }

            // One flowing paragraph: (POS) meaning1；meaning2；meaning3，语境解释。
            // Meanings are emphasized; the contextual explanation trails lighter.
            if !exp.meanings.isEmpty || !exp.contextMeaning.isEmpty {
                let pos = exp.partOfSpeech.isEmpty ? "" : "(\(exp.partOfSpeech)) "
                let means = exp.meanings.prefix(3).joined(separator: "；")
                let ctx = exp.contextMeaning.isEmpty ? "" : "，\(exp.contextMeaning)"

                (Text(pos).foregroundColor(.white)
                    + Text(means).fontWeight(.semibold).foregroundColor(.white)
                    + Text(ctx).foregroundColor(.white.opacity(0.82))
                    // While streaming, trail a block glyph so it reads as "typing".
                    + Text(isStreaming ? " ▌" : "").foregroundColor(.white.opacity(0.7)))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            } else if isStreaming {
                // Loaded shell but no text yet — cursor so the card feels alive.
                TypingCursor()
            }

        case .failed:
            Button {
                onRetry?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text(language.lookupFailed + " · " + language.retry)
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleSave(_ exp: WordExplanation) {
        if let existing = saved.first(where: { $0.word.lowercased() == exp.word.lowercased() }) {
            context.delete(existing)
            onRemoved?()   // let the detail view pop back to the library
        } else {
            let newWord = SavedWord(from: exp, snapshot: snapshot)
            context.insert(newWord)

            // The first encounter photo of this word's group. Every later-day
            // reunion appends another, building the "where/when I met this word"
            // set. The legacy `snapshot` above still stands in for old rows.
            let firstPhoto = WordPhoto(image: snapshot, createdAt: newWord.createdAt)
            firstPhoto.word = newWord
            context.insert(firstPhoto)

            onSaved?()   // trigger the top heart-flash

            // Enrich the fresh save for the reunion banner + footprints. The insert
            // + save below already made the word real, so this only ADDS metadata
            // later — a slow/failed vision or location lookup never blocks or delays
            // the save, and the empty defaults just mean the group falls back to a
            // venue name / "未知地点". Runs on the MAIN actor: the awaits merely
            // suspend (no UI stall) and both `context` and the model stay main-actor
            // bound, so there's no cross-actor SwiftData access.
            if let data = snapshot {
                let lang = language
                Task { @MainActor in
                    // One VL call (scene + venue + emoji) and the GPS/geocode run
                    // concurrently — independent, so we don't pay their latencies
                    // back to back.
                    async let visionTask = AIService.describeSnapshot(imageData: data, language: lang)
                    async let placeTask = LocationService.shared.currentPlace(language: lang)
                    let (vision, place) = await (visionTask, placeTask)

                    newWord.scene = vision.scene
                    newWord.venue = vision.venue
                    newWord.venueEmoji = vision.emoji
                    newWord.placeCity = place.city
                    newWord.placeCountry = place.country
                    // Same metadata onto the first photo so the group grid's caption
                    // matches the word's.
                    firstPhoto.scene = vision.scene
                    firstPhoto.venue = vision.venue
                    firstPhoto.venueEmoji = vision.emoji
                    firstPhoto.placeCity = place.city
                    firstPhoto.placeCountry = place.country
                    try? context.save()
                }
            }
        }
        // Persist immediately. Without this, autosave defers the write (often
        // until backgrounding), so OTHER views observing the same store via
        // @Query — e.g. the camera screen's top-right saved-count badge — don't
        // refresh until the app is relaunched. An explicit save fires the store
        // change notification now, so every @Query updates live.
        try? context.save()
    }
}

// A blinking block that trails streaming text — the "typing" affordance.
private struct TypingCursor: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.7))
            .frame(width: 8, height: 15)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}

// The 🔊 pronounce icon. While its word is being spoken it cycles through the
// three Lucide volume glyphs (no wave → one wave → two waves) so the icon reads
// as radiating sound; idle it rests on the full two-wave glyph.
private struct SpeakingVolumeIcon: View {
    let word: String
    @ObservedObject private var speech = SpeechService.shared
    @State private var frame = 2                     // 0 = volume, 1 = volume-1, 2 = volume-2
    @State private var timer: Timer?

    private var isSpeaking: Bool {
        speech.speakingText?.caseInsensitiveCompare(word) == .orderedSame
    }

    private let names = ["IconVolume", "IconVolume1", "IconVolume2"]

    var body: some View {
        Image(names[frame])
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .onChange(of: isSpeaking) { _, speaking in
                speaking ? startCycling() : stopCycling()
            }
            .onDisappear(perform: stopCycling)
    }

    private func startCycling() {
        frame = 0
        timer?.invalidate()
        // ~5 fps sweep: 0 → 1 → 2 → 0 … reads as pulsing sound waves.
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.12)) {
                frame = (frame + 1) % 3
            }
        }
    }

    private func stopCycling() {
        timer?.invalidate()
        timer = nil
        withAnimation(.easeInOut(duration: 0.15)) { frame = 2 }
    }
}
