import SwiftUI
import AVFoundation
import UIKit
import SwiftData

struct CameraView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var aiService = AIService()
    @Environment(\.scenePhase) private var scenePhase

    // Saved-word count for the top-right badge.
    @Query private var saved: [SavedWord]

    // Learner's native language — drives AI explanation language and UI strings.
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.deviceDefault.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    // Words currently presented as cards (order = display order).
    @State private var displayWords: [String] = []
    // Which word is expanded as the big card. nil = all shown compact.
    // Default after a multi-word hit is the first word (big), rest folded.
    @State private var focusedWord: String? = nil
    @State private var cardStates: [String: WordCardState] = [:]
    // Words whose answer is still streaming in — drives the typing cursor.
    @State private var streamingWords: Set<String> = []
    // Last query issued per display key — lets a failed card retry with the same params.
    @State private var queryUnits: [String: QueryUnit] = [:]

    // Once a card is shown it locks — recognition changes are ignored until
    // the user closes it. This keeps the word on screen so they can read /
    // save it without the card jumping around.
    @State private var isLocked: Bool = false

    // Boxes to outline green, frozen at lock time (vision space, bottom-left).
    // Drawn over the frozen still so they never drift. Only the words that
    // actually produced a card are included.
    @State private var hitBoxes: [CGRect] = []

    // Top heart-flash animation shown when a word is newly saved.
    @State private var heartFlash: Bool = false

    // Frozen camera frame captured when the current card locked — saved with the word.
    @State private var lockedSnapshot: Data? = nil

    // Library sheet, opened from the top-right badge.
    @State private var showLibrary = false

    // At most 5 cards on screen (1 primary + 4 secondary).
    private let maxCards = 5

    var body: some View {
        ZStack {
            cameraLayer
            annotationLayer

            // Card overlay
            if showOverlay {
                overlay
            }

            heartFlashView
            scanningHintView
            idlePointHintView

            // Camera permission denied — full-screen fallback with a route to Settings.
            if camera.permissionDenied {
                CameraDeniedView(language: language)
            }
        }
        // Badge floats as an overlay — NOT a ZStack sibling — so toggling the
        // result card inside the ZStack can never shift its position. The badge
        // pins itself to the physical screen top and offsets by the real notch
        // inset, so its vertical position is deterministic (no reliance on how
        // SwiftUI resolves safe area under the full-screen camera layer).
        .overlay { badge }
        .animation(.easeInOut(duration: 0.2), value: camera.isScanning)
        .animation(.easeInOut(duration: 0.2), value: showOverlay)
        .fullScreenCover(isPresented: $showLibrary) {
            LibraryView()
        }
        .onAppear {
            camera.requestPermissionAndStart()
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { phase in
            // Re-check when coming back from Settings — they may have granted access.
            if phase == .active {
                camera.requestPermissionAndStart()
                // The live session restarts on resume, but a stale freeze would
                // keep an old still pinned over it (frozen photo + dead card).
                // Drop back to live scanning if we were locked.
                if isLocked { dismiss() }
            }
        }
        .onChange(of: camera.pointedWord?.text) { _ in recompute() }
        .onChange(of: camera.colorMarks) { _ in recompute() }
        .onChange(of: camera.hoveringWord?.text) { _ in prefetchHovered() }
    }

    // MARK: - Body layers
    // Each layer is split out with an explicit `some View` type so the compiler
    // type-checks small pieces instead of one giant ZStack expression (which
    // times out in Xcode's incremental build and silently blocks new builds).

    // Live preview + the frozen still shown after a result locks.
    @ViewBuilder
    private var cameraLayer: some View {
        CameraPreviewView(session: camera.session)
            .ignoresSafeArea()

        // Frozen still — shown once a result locks. Covers the live preview at
        // the exact aspect-fill geometry the boxes use, so the page and the
        // green boxes stay pixel-locked until the user rescans.
        if let frozen = camera.frozenImage {
            Image(uiImage: frozen)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .transition(.opacity)
        }
    }

    // Green result boxes (post-lock) + the live finger dot.
    private var annotationLayer: some View {
        GeometryReader { geo in
            let size = geo.size

            // Green boxes. Mid-scan the view stays clean — none at all. After a
            // lock we outline only the words that produced a card, drawn from
            // coordinates frozen at lock time (over the frozen still), so they
            // never drift with later OCR/hand movement.
            if isLocked {
                ForEach(Array(hitBoxes.enumerated()), id: \.offset) { _, box in
                    let rect = visionRectToView(box, viewSize: size)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.green, lineWidth: 2.5)
                        .frame(width: max(rect.width, 20), height: max(rect.height, 14))
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                }
            }

            // Finger indicator dot — only while live (hidden once frozen).
            if !isLocked, let fp = camera.fingerVisionPoint {
                let pt = visionPointToView(fp, viewSize: size)
                Circle()
                    .fill(Color.blue.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(pt)
            }
        }
    }

    // Top-right saved-word count badge. Pinned to the PHYSICAL screen rect and
    // offset by the real safe-area insets read from the window — the same
    // absolute approach the bottom card uses. Vertical/horizontal position is
    // therefore deterministic and unaffected by the full-screen camera layer or
    // by the result card appearing/disappearing.
    private var badge: some View {
        Button {
            showLibrary = true
        } label: {
            HStack(spacing: 8) {
                Image("IconBook")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                Text("\(saved.count)")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCapsule(interactive: true)
            .environment(\.colorScheme, .dark)
        }
        .padding(.top, screenInsets.top + 8)   // just below the notch / status bar
        .padding(.trailing, 20)                // 20pt gutter from the right edge
        .frame(
            width: UIScreen.main.bounds.width,
            height: UIScreen.main.bounds.height,
            alignment: .topTrailing
        )
        .ignoresSafeArea()
    }

    // Top heart-flash — appears briefly when a word is saved.
    @ViewBuilder
    private var heartFlashView: some View {
        if heartFlash {
            Image(systemName: "heart.fill")
                .font(.system(size: 60))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.25), radius: 8)
                .transition(.scale.combined(with: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
                .allowsHitTesting(false)
        }
    }

    // Bottom scanning hint with shimmer — while a target is being confirmed.
    @ViewBuilder
    private var scanningHintView: some View {
        if camera.isScanning && !showOverlay {
            ScanningHint(text: language.scanning)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 44)
                .transition(.opacity)
        }
    }

    // Idle guidance — the camera is live but nothing is pointed at / recognizing
    // and no card is up. Without this the screen reads as "dead" over a page it
    // deliberately won't auto-translate. A calm static pill teaches the core
    // gesture. Suppressed the moment scanning or a result takes over.
    @ViewBuilder
    private var idlePointHintView: some View {
        if !showOverlay && !camera.isScanning && !camera.permissionDenied {
            Text(language.pointHint)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white.opacity(0.95))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                // Dark underlay UNDER the glass so the pill stays legibly dark over
                // bright scenes. .ultraThinMaterial alone is adaptive and washes out
                // to near-white over light backgrounds (paper / desk), hiding the
                // light text. Mirrors glassPill's black-0.45 underlay.
                .background(Color.black.opacity(0.45), in: Capsule())
                .glassCapsule()
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 44)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var showOverlay: Bool {
        !displayWords.isEmpty
    }

    // MARK: - Result overlay
    //
    // The card block floats at the bottom, inset from all edges.
    //
    // IMPORTANT: the full-screen camera preview (ignoresSafeArea) inflates the
    // layout reference used by relative modifiers, so `.padding`/GeometryReader
    // gave NO real gutters on device (they worked only in the sim, which has no
    // camera). We therefore pin the width to an ABSOLUTE pixel value derived from
    // the physical screen — immune to the camera layer, safe area, and parents.
    private var cardBlockWidth: CGFloat {
        UIScreen.main.bounds.width - 40   // 20pt gutter each side
    }

    // Real safe-area insets read straight from the key window. The full-screen
    // camera preview (ignoresSafeArea) makes SwiftUI's own safe-area math
    // unreliable in this ZStack — same reason cardBlockWidth is pinned to
    // UIScreen — so overlays that must clear the notch / home indicator read
    // the physical insets and lay out against them.
    private var screenInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets ?? .zero
    }

    private var overlay: some View {
        ZStack(alignment: .bottom) {
            // Tap outside to rescan.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 12) {
                cardBlock
                rescanButton
            }
            .frame(width: cardBlockWidth)      // absolute width → guaranteed gutters
            .padding(.bottom, 20)              // match the 20pt left/right gutters
            .ignoresSafeArea(edges: .bottom)
        }
        .transition(.opacity)
        .animation(.spring(response: 0.35), value: displayWords)
    }

    // Card presentation has three shapes for a multi-word hit:
    //   • one word            → just the big card.
    //   • focusedWord set      → that word big, the rest folded away. Tapping the
    //                            big card expands everyone into the compact list.
    //   • focusedWord nil      → every word as a compact card. Tapping one focuses
    //                            it (big) and folds the others.
    @ViewBuilder
    private var cardBlock: some View {
        let words = Array(displayWords.prefix(maxCards))
        if words.count == 1 {
            card(for: words[0])
        } else if let focus = focusedWord, words.contains(focus) {
            // Focused: big card on top; tap it to expand all into compact cards.
            card(for: focus)
                .onTapGesture {
                    withAnimation(.spring(response: 0.35)) { focusedWord = nil }
                }
        } else {
            // Expanded: all compact; tap one to focus it as the big card.
            VStack(spacing: 10) {
                ForEach(words, id: \.self) { word in
                    card(for: word, compact: true)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35)) { focusedWord = word }
                        }
                }
            }
        }
    }

    // Return to live scanning.
    private var rescanButton: some View {
        Button(action: dismiss) {
            Text(language.rescan)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .darkPanel(cornerRadius: 20)
        }
    }

    private func card(for word: String, compact: Bool = false) -> some View {
        WordCardView(
            state: cardStates[word] ?? .loading(word),
            language: language,
            compact: compact,
            snapshot: lockedSnapshot,
            isStreaming: streamingWords.contains(word),
            onClose: compact ? nil : { dismiss() },
            onSaved: { triggerHeartFlash() },
            onRetry: { retry(word) }
        )
    }

    // Re-issue a lookup for a card that failed. Uses the remembered query params.
    private func retry(_ key: String) {
        guard let unit = queryUnits[key] else { return }
        cardStates[key] = .loading(key)
        lookup(unit)
    }

    // Close the current card and resume recognition.
    private func dismiss() {
        displayWords = []
        focusedWord = nil
        isLocked = false
        hitBoxes = []
        camera.unfreeze()   // drop the still, resume live preview
    }

    // Brief white heart burst at the top when a word is saved.
    private func triggerHeartFlash() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
            heartFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.3)) {
                heartFlash = false
            }
        }
    }

    // MARK: - Trigger logic (finger priority > marks)

    private func recompute() {
        // A card is on screen and locked — keep it until the user closes it.
        guard !isLocked else { return }

        let targets = Array(targetWords().prefix(maxCards))
        guard !targets.isEmpty else { return }

        // Lock onto this result and show it.
        isLocked = true
        camera.freeze()                             // freeze the live preview into a still
        lockedSnapshot = camera.currentSnapshot()   // freeze the page for the library card
        displayWords = targets.map { $0.displayKey }
        // Default: first word big, the rest folded (only matters for multi-word).
        focusedWord = displayWords.first

        // Green outline: exactly the words that produced a card (P1), from boxes
        // frozen here at lock time so they sit on the still and never drift.
        let boxes = targets.flatMap { $0.boxes }
        withAnimation(.easeInOut(duration: 0.2)) { hitBoxes = boxes }

        for t in targets where cardStates[t.displayKey] == nil {
            lookup(t)
        }
    }

    // One thing to look up: a single word, or a marked phrase treated as a unit.
    private struct QueryUnit {
        let displayKey: String   // card title + state key (the phrase, or the word)
        let term: String         // what we send to AI
        let longestWord: String  // phrase's phonetic anchor
        let isPhrase: Bool
        let context: String
        let boxes: [CGRect]      // vision-space boxes of the covered word(s), for the green outline
    }

    // Priority: finger-pointed word first; otherwise all marked words/phrases.
    // A mark spanning >1 word is looked up as a whole phrase.
    private func targetWords() -> [QueryUnit] {
        if let w = camera.pointedWord, !w.text.isEmpty {
            return [QueryUnit(displayKey: w.text, term: w.text,
                              longestWord: w.text, isPhrase: false, context: w.context,
                              boxes: [w.boundingBox])]
        }
        var seen = Set<String>()
        var result: [QueryUnit] = []
        for mark in camera.colorMarks {
            guard let d = mark.primaryDetected else { continue }
            if mark.isPhrase {
                // Whole underlined/circled phrase → one query for its overall meaning.
                let phrase = mark.phraseText
                let dedupe = phrase.lowercased()
                guard !phrase.isEmpty, !seen.contains(dedupe) else { continue }
                seen.insert(dedupe)
                result.append(QueryUnit(displayKey: phrase, term: phrase,
                                        longestWord: d.text, isPhrase: true, context: phrase,
                                        boxes: mark.words.map { $0.boundingBox }))
            } else {
                let w = d.text
                guard !w.isEmpty, !seen.contains(w.lowercased()) else { continue }
                seen.insert(w.lowercased())
                result.append(QueryUnit(displayKey: w, term: w,
                                        longestWord: w, isPhrase: false, context: d.context,
                                        boxes: [d.boundingBox]))
            }
        }
        return result
    }

    // MARK: - AI Lookup

    // Fire the lookup while the finger is still hovering (before the 0.4s
    // confirm). By the time the card opens the result is usually already cached,
    // so it appears instantly instead of after a spinner.
    private func prefetchHovered() {
        guard !isLocked, let w = camera.hoveringWord, !w.text.isEmpty else { return }
        lookup(QueryUnit(displayKey: w.text, term: w.text,
                         longestWord: w.text, isPhrase: false, context: w.context,
                         boxes: [w.boundingBox]))
    }

    private func lookup(_ unit: QueryUnit) {
        let lang = language
        let key = unit.displayKey
        queryUnits[key] = unit   // remember for retry
        if let cached = aiService.cachedResult(for: unit.term, context: unit.context, language: lang) {
            cardStates[key] = .loaded(cached)
            return
        }
        // Only show the spinner if nothing is on screen for this word yet.
        if cardStates[key] == nil { cardStates[key] = .loading(key) }

        Task {
            await MainActor.run { streamingWords.insert(key) }
            do {
                // Consume partial results as they stream in — the card types them out.
                for try await partial in aiService.streamLookup(
                    unit.term, context: unit.context, language: lang,
                    isPhrase: unit.isPhrase, phoneticWord: unit.longestWord
                ) {
                    await MainActor.run { cardStates[key] = .loaded(partial) }
                }
            } catch {
                await MainActor.run {
                    // Keep any partial we already showed; only fail if we have nothing.
                    if case .loading = cardStates[key] ?? .loading(key) {
                        cardStates[key] = .failed(key)
                    }
                }
            }
            await MainActor.run { streamingWords.remove(key) }
        }
    }

    // MARK: - Coordinate Conversion
    //
    // Camera preset hd1280x720 captures landscape 1280×720.
    // VNImageRequestHandler(orientation: .right) treats it as portrait → effective 720×1280.
    // Vision bounding boxes: normalized [0,1], origin bottom-left.
    // Preview layer gravity: resizeAspectFill (scale to fill, centered, crops edges).

    private let imageSize = CGSize(width: 720, height: 1280)

    private func visionRectToView(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let cropX = (imageSize.width * scale - viewSize.width) / 2
        let cropY = (imageSize.height * scale - viewSize.height) / 2

        let x = rect.minX * imageSize.width * scale - cropX
        let y = (1 - rect.maxY) * imageSize.height * scale - cropY
        let w = rect.width * imageSize.width * scale
        let h = rect.height * imageSize.height * scale
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func visionPointToView(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let cropX = (imageSize.width * scale - viewSize.width) / 2
        let cropY = (imageSize.height * scale - viewSize.height) / 2

        let x = point.x * imageSize.width * scale - cropX
        let y = (1 - point.y) * imageSize.height * scale - cropY
        return CGPoint(x: x, y: y)
    }
}

// UIViewRepresentable wrapper for AVCaptureVideoPreviewLayer.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let conn = layer.connection {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
        view.layer.addSublayer(layer)
        view.previewLayer = layer
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

// Full-screen fallback shown when camera access is denied/restricted, with a
// button that deep-links to the app's Settings page.
struct CameraDeniedView: View {
    let language: AppLanguage

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "camera.metering.none")
                    .font(.system(size: 52))
                    .foregroundColor(.secondary)

                Text(language.cameraDeniedTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(language.cameraDeniedBody)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text(language.openSettings)
                        .font(.headline)
                        .foregroundColor(.black)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 14)
                        .glassProminentCapsule(tint: .white)
                }
                .padding(.top, 8)
            }
        }
    }
}

// Bottom "recognizing…" pill. The text sits dim, and a bright highlight sweeps
// left→right through the letters themselves — the common AI-loading shimmer.
// The base text is hidden (reserves layout only); the ONLY visible glyphs are
// the single masked layer in the overlay, so nothing can overlap / ghost.
struct ScanningHint: View {
    let text: String
    @State private var phase: CGFloat = -1

    private let font: Font = .subheadline.weight(.medium)

    var body: some View {
        Text(text)
            .font(font)
            .hidden()                 // reserves size; draws nothing
            .overlay { shimmer }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassCapsule()
            .environment(\.colorScheme, .dark)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }

    // Dim base + a bright band sweeping across, the whole thing clipped to the
    // glyph shapes so the light travels through the letters. One layer only.
    private var shimmer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Color.white.opacity(0.35)          // dim base tone
                LinearGradient(
                    colors: [.clear, .white, .white, .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: w * 0.55)
                .offset(x: phase * w * 1.4)         // slides off-screen at both ends
            }
            .mask(
                Text(text)
                    .font(font)
                    .frame(width: w, height: geo.size.height)
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Surfaces
//
// These live here (not in a separate file) on purpose: kept as a standalone
// file, Xcode's file-system-synchronized group failed to fold them into the
// build, so every call site errored and the whole target silently kept running
// the previous build. Inlining into a file that is already compiled removes any
// chance of that recurring.
//
// The app is dark chrome over a live camera feed. Two kinds of surface:
//  • darkPanel  — CONTENT (word cards, rescan bar). A solid DARK frosted panel
//    like the mockup: floats over the page, rounded corners, readable white
//    text on any background. Same on every iOS version for consistency.
//  • glassCapsule — small CHROME controls (badge, hint). Liquid Glass on iOS 26,
//    Material below.
extension View {

    /// Dark frosted content panel — word cards & the rescan bar. A charcoal
    /// scrim over material keeps white text legible over a bright page, and the
    /// hairline border lifts it off the scrim. This is the ONLY card surface.
    func darkPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .background(Color.black.opacity(0.45), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
            .environment(\.colorScheme, .dark)
    }

    /// Small floating control — top-right badge, scanning hint.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Tinted, prominent capsule — primary CTAs (onboarding, denied view).
    @ViewBuilder
    func glassProminentCapsule(tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            background(tint, in: Capsule())
        }
    }
}
