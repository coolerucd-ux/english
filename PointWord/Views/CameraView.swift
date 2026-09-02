import SwiftUI
import AVFoundation
import UIKit
import SwiftData

struct CameraView: View {
    // camera is @Observable, so it's owned with @State (the WWDC23 pattern), NOT
    // @StateObject. This is HALF the freeze fix: @Observable tracks reads per
    // property, so this view re-evaluates only for the camera properties it actually
    // reads — not on every one of the ~10 frame-pipeline mutations per second like
    // the old @Published/ObservableObject did. aiService has no observed state the
    // view reads, so it stays a plain StateObject.
    @State private var camera = CameraManager()
    @StateObject private var aiService = AIService()
    @Environment(\.scenePhase) private var scenePhase
    // Used at trigger time to look up whether the pointed word was saved on an
    // earlier day (the reunion check). This is a ONE-OFF fetch inside recompute(),
    // NOT a @Query — a live @Query on this high-refresh view is what got coalesced
    // away for the badge count, so we deliberately fetch on demand instead.
    @Environment(\.modelContext) private var modelContext

    // NOTE — the saved-word count is NOT queried here anymore. It lives in the
    // dedicated SavedBadgeLabel leaf view (bottom of this file). A @Query on THIS
    // big view — next to the @Observable camera driving ~10 frame updates/sec —
    // had its SwiftData store-change invalidation coalesced away, so the count
    // only refreshed on relaunch. A tiny leaf whose body is purely the query
    // refreshes on every save/remove. (This was the "数字不实时" bug.)

    // Learner's native language — drives AI explanation language and UI strings.
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.deviceDefault.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    // The single word currently shown as a card. nil = no card up. Recognition is
    // one-word-at-a-time: point, hold, get exactly one card. The old multi-word /
    // folded-list design was removed with underline/circle detection — there is no
    // longer any path that yields more than one target at once.
    @State private var displayWord: String? = nil
    @State private var cardStates: [String: WordCardState] = [:]

    // Word reunion. When the locked word was saved on an EARLIER day, we still
    // show the normal explanation card, capped with a small banner (reunionBanner)
    // summarizing count / last-seen time / scene. Tapping it opens that word in the
    // collection pager (recallItem). reunionWord = the matched save; nil = normal.
    @State private var reunionWord: SavedWord? = nil
    @State private var reunionBanner: ReunionBanner? = nil
    @State private var recallItem: SavedWord? = nil
    // Words whose answer is still streaming in — drives the typing cursor.
    @State private var streamingWords: Set<String> = []
    // Last query issued per display key — lets a failed card retry with the same params.
    @State private var queryUnits: [String: QueryUnit] = [:]

    // Once a card is shown it locks — recognition changes are ignored until
    // the user closes it. This keeps the word on screen so they can read /
    // save it without the card jumping around.
    @State private var isLocked: Bool = false

    // Top heart-flash animation shown when a word is newly saved.
    @State private var heartFlash: Bool = false

    // Frozen camera frame captured when the current card locked — saved with the word.
    @State private var lockedSnapshot: Data? = nil

    // Library sheet, opened from the top-right badge.
    @State private var showLibrary = false

    // Location permission is primed the FIRST time a word locks (not at launch and
    // not deferred to save). CoreLocation's when-in-use prompt is async, so priming
    // it during recognition means the fix is cached and ready by the time the user
    // taps 收藏 — the first save then actually gets a city instead of "未知地点".
    // Once per launch.
    @State private var didPrimeLocation = false

    // Onboarding-hint lifecycle. Shown once on the first cold launch, capped at
    // hintVisibleDuration, and hidden the instant a card appears. Not re-shown on
    // resume, library return, or card close. hintSession guards the fade timer so
    // a late/superseded timer no-ops itself.
    @State private var hintVisible = false
    @State private var hintSession = UUID()
    // Set when the hint was requested before the preview had pixels (cold launch).
    // Once the first frame arrives we start it for real.
    @State private var hintPendingPreview = false

    private let hintVisibleDuration: TimeInterval = 5.0   // max time the onboarding hint stays up

    // On-screen diagnostic HUD (fps / word-count / finger / running). The freeze
    // is fixed, so it's OFF — the top-left line no longer shows. Kept as a flag
    // (not deleted) so it can be re-armed in one edit if a capture stall ever
    // needs a self-diagnosing screenshot again.
    private let showDiagnostics = false

    // NOTE — the OTHER half of the freeze fix: this view holds NO cached screen
    // geometry and reads NO global mutable state (UIScreen.main / UIApplication.shared)
    // anywhere in its body. Those reads-during-body were the AttributeGraph cycle
    // source on iOS 26; a previous attempt cached them via a hidden GeometryReader
    // that WROTE @State the body then READ BACK — which is itself a layout feedback
    // loop and did NOT clear the cycle. All chrome now positions with SwiftUI-native
    // safe area + relative padding, so there is nothing for a cycle to form around.

    var body: some View {
        // FULL-BLEED camera stack lives in .background so it does NOT inflate the
        // layout the chrome measures against. THIS is what lets the badge and card
        // use native safe-area + relative padding and STILL get real 20pt gutters
        // on device — with NO UIScreen.main / UIApplication.shared reads anywhere in
        // this body. Those global-state reads-during-layout were the AttributeGraph
        // cycle source (attributes 9272 / 18784 in the logs; 9296 earlier). A
        // .background full-bleed layer + native safe-area chrome removes them
        // entirely, without the card going 靠边.
        ZStack {
            // Card overlay
            if showOverlay {
                overlay
            }

            heartFlashView
            idlePointHintView

            // Camera permission denied — full-screen fallback with a route to Settings.
            if camera.permissionDenied {
                CameraDeniedView(language: language)
            }

            // Live diagnostic HUD — tiny, top-left, under the notch. Lets a single
            // screenshot of a frozen state be self-diagnosing: fps>0 w>0 = camera &
            // detection alive (UI-delivery bug); fps>0 w=0 = alive but not
            // recognizing; fps=0 / frozen text = capture source truly dead. Toggle
            // off by flipping showDiagnostics once the freeze is nailed.
            if showDiagnostics && !camera.diagLine.isEmpty {
                VStack {
                    HStack {
                        Text(camera.diagLine)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 60)
                .padding(.leading, 14)
                .allowsHitTesting(false)
            }
        }
        // Fill the safe area so .background (full bleed) and .overlay (safe-area
        // corner) always have a frame to anchor to, even when no card/hint is up.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Live preview + finger/annotation dots + green sweep — all full-bleed.
        // As a .background they fill the screen (each ignoresSafeArea) WITHOUT
        // enlarging the foreground's layout, so the chrome above stays in the safe
        // area natively. The annotation GeometryReader still measures the full
        // screen here (ignoresSafeArea on this ZStack), so finger-dot coordinate
        // mapping is unchanged.
        .background {
            ZStack {
                cameraLayer
                annotationLayer
                scanLineView
            }
            .ignoresSafeArea()
        }
        // Badge pinned to the top-trailing SAFE-AREA corner natively — clears the
        // notch/status bar with no manual inset math and no global reads, so its
        // position is deterministic and unaffected by the card appearing.
        .overlay(alignment: .topTrailing) { badge }
        .animation(.easeInOut(duration: 0.2), value: showOverlay)
        .animation(.easeInOut(duration: 0.35), value: hintVisible)
        .fullScreenCover(isPresented: $showLibrary) {
            LibraryView()
        }
        // "去回忆" from the reunion banner — open THIS word's photo group: a
        // 3-per-row album of every time it was met (where/when), tappable into a
        // swipeable full-screen viewer. Presented as a bottom sheet so it feels
        // like the rest of the collection.
        .sheet(item: $recallItem) { item in
            WordPhotoGroupView(word: item, language: language) {
                // The word was un-saved from INSIDE the viewer. Tear the whole
                // reunion stack down from the top in one go — dismissing only the
                // inner pager would leave this group sheet holding a now-deleted
                // SavedWord and it would trap on the next read. Also drop the stale
                // reunion banner so tapping "去回忆" again can't reopen the deleted
                // word (that read would crash too).
                recallItem = nil
                reunionWord = nil
                reunionBanner = nil
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .onAppear {
            camera.requestPermissionAndStart()
            startHintSession()
            OfflineDictionary.shared.preload()   // warm the no-network fallback off the main thread
            // Keep the screen awake while the recognition page is up. The single
            // biggest cause of "left it on the desk, came back, camera is dead" was
            // the display auto-dimming / the system throttling the app after minutes
            // of no touches — which stalls the capture pipeline. A word scanner is
            // used hands-off (finger on paper, not on glass), so the normal idle
            // timer fights the core use case; disable it here and restore it on exit.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false   // stop holding the screen awake
        }
        .onChange(of: showLibrary) { open in
            if open {
                // Library covers us full-screen → SwiftUI fires onDisappear and we
                // stop the session to free the camera. Nothing else runs while the
                // library is up.
            } else {
                // Returned from the library. onAppear does NOT re-fire for a view
                // revealed from under a fullScreenCover, so the session we stopped
                // on cover-present would stay dead (preview frozen, no detection).
                // Restart it explicitly. The onboarding hint is intentionally NOT
                // shown here — it's a first-launch primer only.
                camera.requestPermissionAndStart()
            }
        }
        .onChange(of: scenePhase) { phase in
            // Tell the manager whether we're the foreground app FIRST — its watchdog
            // and restart paths use this to refuse startRunning() while backgrounded
            // (iOS reports that as interruption reason=1,
            // videoDeviceNotAvailableInBackground, and a restart there just re-hammers
            // the shared camera server → the -17281 spam and permanent freeze).
            camera.setForeground(phase == .active)

            switch phase {
            case .background:
                // REAL background / swipe-kill → release the camera cleanly NOW,
                // while we still get CPU. onDisappear does NOT reliably fire before
                // iOS suspends a swipe-killed process, so the session would otherwise
                // die WITH the process still holding the camera; mediaserverd then
                // keeps a dead client connection and the NEXT launch collides with it
                // (-17281 at startup → frozen). Stopping here guarantees clean
                // release. Idempotent, so a later onDisappear stop() is harmless.
                camera.stop()

            case .active:
                // WARM RESUME (app was alive in the background) or the foreground
                // half of launch. @State survives in-process, so restore the user
                // where they left off:
                //   1. A card is up (isLocked) → keep it; the frozen still covers the
                //      stopped session. (We must NOT dismiss — that destroys the state
                //      the user wants back.)
                //   2. Library open (showLibrary) → do nothing; the cover owns the
                //      screen and the session stays stopped.
                //   3. Live recognition → re-arm the session so scanning resumes.
                if isLocked || showLibrary { return }
                camera.requestPermissionAndStart()

            default:
                // .inactive is TRANSIENT — Control Center, app-switcher peek, a
                // notification banner, the launch hand-off. iOS interrupts the
                // capture session itself and resumes it on its own; tearing it down
                // and restarting here only churns start/stop and hammers the camera
                // server. Do nothing and let the system own it. A real background
                // trip always continues on to .background, which is handled above.
                break
            }
        }
        .onChange(of: camera.pointedWord?.text) { _ in recompute() }
        .onChange(of: camera.hoveringWord?.text) { _ in prefetchHovered() }
        .onChange(of: camera.isPreviewLive) { live in if live { onPreviewLive() } }
    }

    // MARK: - Body layers
    // Each layer is split out with an explicit `some View` type so the compiler
    // type-checks small pieces instead of one giant ZStack expression (which
    // times out in Xcode's incremental build and silently blocks new builds).

    // Live preview + the frozen still shown after a result locks.
    @ViewBuilder
    private var cameraLayer: some View {
        CameraPreviewView(session: camera.session, focusTarget: camera)
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

            // No result outline. During scanning only the blue dot shows; on a
            // successful lock only the word card appears. The old green box was
            // removed at the user's request — on the frozen still it lagged a few
            // handheld-jitter frames behind the OCR box and drifted off the word.

            // Finger indicator — only while live (hidden once frozen). This is the
            // SINGLE pointing indicator: just the blue dot, no ring, no green box,
            // no glow (they read as competing markers). It is drawn at the PROBE
            // point — the spot just above the nail that recognition actually reads
            // — NOT the raw fingertip, so the dot the user sees sits on the exact
            // word being recognized. That alignment is the fix for "I point here
            // but it reads the word above". Falls back to the fingertip only if no
            // probe has been computed yet (the very first frame a hand appears).
            // The dot itself carries the lock feedback — it grows and brightens as
            // the dwell fills, so one calm element shows both "here's the fingertip"
            // and "locking in".
            if !isLocked, let anchor = camera.fingerProbePoint ?? camera.fingerVisionPoint {
                let pt = visionPointToView(anchor, viewSize: size)
                let p = camera.pointingProgress
                // The dot IS the lock feedback: it starts small and dim while the
                // finger is only hovering, and grows + brightens as the dwell
                // fills, so at full lock it's a clearly larger, solid dot — the
                // "this word is locked" signal, no separate ring needed. Growth is
                // pronounced (22→42pt, opacity 0.40→0.90) so the lock reads at a
                // glance instead of the old subtle 12pt creep. Green #32f08c —
                // same hue as the scan sweep, so the whole recognition UI is one color.
                Circle()
                    .fill(Color(red: 0.196, green: 0.941, blue: 0.549).opacity(0.40 + 0.50 * p))
                    .frame(width: 22 + 20 * p, height: 22 + 20 * p)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(pt)
                    .animation(.easeOut(duration: 0.12), value: p)
            }
        }
    }

    // Top-right saved-word count badge. Positioned by the parent
    // `.overlay(alignment: .topTrailing)`, which keeps it inside the safe area
    // natively — so it clears the notch/status bar with NO UIScreen/UIApplication
    // reads and NO manual inset math. The camera is a .background layer now, so it
    // no longer inflates this chrome's layout; relative padding gives real gutters.
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
                // Leaf view — see SavedBadgeLabel. Owning the @Query here (on the
                // big camera view) made the count refresh only on relaunch.
                SavedBadgeLabel()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCapsule(interactive: true)
            .environment(\.colorScheme, .dark)
        }
        .padding(.top, 8)             // just below the safe-area top (notch/status bar)
        .padding(.trailing, 20)       // 20pt gutter from the right edge
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

    // The bottom "正在识别" text pill was removed: it overlapped the scan light
    // (both signaled "I'm recognizing") and sat exactly where the result card
    // pops up, so it read as clutter. The blue scan sweep now carries that meaning
    // on its own, and the finger dot carries the precise per-word feedback.

    // Full-screen top→bottom GREEN sweep — the ambient "recognition mode is live"
    // signal. It runs while the camera is actively looking (idle or scanning) but
    // HIDES once a result card is up (showOverlay): recognition already succeeded,
    // so a "still searching" animation behind the card is misleading clutter. Also
    // hidden by the permission-denied fallback (no camera to scan). It sits below
    // the result card in the ZStack.
    @ViewBuilder
    private var scanLineView: some View {
        // Gated on isPreviewLive so the sweep only animates over ACTUAL camera
        // pixels. Before the first frame the screen is black — during the
        // first-launch camera/network permission prompts there are no pixels yet,
        // so a scanning animation behind the system dialog reads as a bogus
        // "loading". No preview → no sweep. (Also kills the cold-start black-gap
        // flicker.)
        if camera.isPreviewLive && !camera.permissionDenied && !showOverlay {
            ScanLineView()
        }
    }

    // Idle guidance — the camera is live but nothing is pointed at / recognizing
    // and no card is up. Without this the screen reads as "dead" over a page it
    // deliberately won't auto-translate. Clean shadowed text teaches the core
    // gestures. Suppressed the moment scanning or a result takes over.
    @ViewBuilder
    private var idlePointHintView: some View {
        if hintVisible && !showOverlay && !camera.permissionDenied {
            Text(language.pointHint)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                // No pill — clean floating text per the 留白 look. White text
                // washes out on bright paper, so two stacked shadows carry the
                // contrast: a tight dark one draws a crisp edge right around the
                // glyphs, a softer wider one lifts them off any background. Works
                // over both the dark desk (top) and the white page (bottom).
                .shadow(color: .black.opacity(0.55), radius: 1.5, x: 0, y: 0.5)
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 1)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 44)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var showOverlay: Bool {
        displayWord != nil
    }

    // MARK: - Result overlay
    //
    // The card block floats at the bottom, inset 20pt from each side. Now that the
    // camera is a .background layer (it no longer inflates this overlay's layout),
    // native relative padding produces real gutters on device — no UIScreen read.
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
            .padding(.horizontal, 20)          // 20pt gutter each side
            .padding(.bottom, 20)              // match the 20pt left/right gutters
        }
        .transition(.opacity)
        .animation(.spring(response: 0.35), value: displayWord)
    }

    // Exactly one word → exactly one card. When the word is a reunion (saved on an
    // earlier day), a tappable banner caps the card with the "又见面了" summary;
    // the card itself is the SAME explanation card as any other result.
    @ViewBuilder
    private var cardBlock: some View {
        VStack(spacing: 10) {
            if let banner = reunionBanner {
                ReunionBannerView(banner: banner, language: language) {
                    recallItem = reunionWord      // "去回忆" → open the collection pager
                }
            }
            if let word = displayWord {
                card(for: word)
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

    private func card(for word: String) -> some View {
        WordCardView(
            state: cardStates[word] ?? .loading(word),
            language: language,
            compact: false,
            snapshot: lockedSnapshot,
            isStreaming: streamingWords.contains(word),
            onClose: { dismiss() },
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
        displayWord = nil
        isLocked = false
        reunionWord = nil       // clear any reunion so the next hold starts clean
        reunionBanner = nil
        recallItem = nil
        camera.unfreeze()       // drop the still, resume live preview
        camera.resetDetection() // clear stale pointed word so the next card comes
                                // from a FRESH finger hold, not the leftover result
                                // that just closed
        // No hint here — the onboarding primer is shown only on first cold launch,
        // not every time a card closes.
    }

    // MARK: - Onboarding hint scheduling
    //
    // A first-launch primer only: it appears once when the app cold-launches
    // (onAppear), stays at most hintVisibleDuration seconds, and disappears the
    // instant a scan result (card) shows. It is NOT re-shown on background resume,
    // on returning from the library, or after a card closes. hintSession is bumped
    // on the (single) start so a superseded/late timer no-ops itself.
    private func startHintSession() {
        // If the preview has no pixels yet (cold launch — the camera takes a beat
        // to deliver its first frame), defer: showing the hint over the black
        // startup gap wastes its whole window, which is exactly why it "didn't
        // appear" after launch. onPreviewLive picks it up.
        guard camera.isPreviewLive else {
            hintPendingPreview = true
            return
        }
        hintPendingPreview = false
        let session = UUID()
        hintSession = session
        showHint(session)
    }

    // The first camera frame arrived. If a hint session was waiting on it, run it now.
    private func onPreviewLive() {
        guard hintPendingPreview else { return }
        hintPendingPreview = false
        startHintSession()
    }

    private func showHint(_ session: UUID) {
        // A newer session superseded us, or a card is already up — do nothing.
        guard session == hintSession, !showOverlay else { return }
        hintVisible = true

        // Hard cap: fade out after the max window even if the user never scans.
        DispatchQueue.main.asyncAfter(deadline: .now() + hintVisibleDuration) {
            guard session == hintSession else { return }
            hintVisible = false
        }
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

    // MARK: - Trigger logic (finger pointing only)

    private func recompute() {
        // A card is on screen and locked — keep it until the user closes it.
        guard !isLocked else { return }

        // Exactly one target: the finger-pointed word (or nothing).
        guard let target = targetWord() else { return }

        // Lock onto this result and show it.
        isLocked = true
        hintVisible = false                         // a result is up → drop the onboarding hint
        camera.freeze()                             // freeze the live preview into a still
        lockedSnapshot = camera.currentSnapshot()   // freeze the page for the library card

        // Prime location permission during the FIRST recognition. This is where the
        // when-in-use prompt appears — while the user is looking up their first word,
        // not at launch. Fire-and-forget: the async prompt returns immediately, the
        // resolved fix is cached for the save that follows. We don't use the result.
        if !didPrimeLocation {
            didPrimeLocation = true
            Task { _ = await LocationService.shared.currentPlace(language: language) }
        }

        // Reunion check: was this exact word saved on an EARLIER day? If so, cap the
        // card with the "又见面了" banner and show the SAVED explanation (word /
        // phonetic / meaning) straight away — no network needed, it's all on record.
        if let past = reunionCandidate(for: target.term) {
            // Snapshot the banner BEFORE bumping counters, so "上次见到" reads as the
            // previous encounter and the count shows THIS visit's ordinal.
            reunionBanner = ReunionBanner(
                count: past.seenCount + 1,
                lastSeen: past.effectiveLastSeen,
                scene: past.scene
            )
            reunionWord = past
            past.markSeenAgain()                    // record this encounter (count +1, time = now)

            // Grow the word's photo group: this reunion is a fresh sighting, so
            // append the frame we just froze as another WordPhoto (the "每次重逢
            // 自动收一张" behaviour). Enrich its place/scene in the background — a
            // slow/failed vision or GPS lookup never blocks the card.
            if let shot = lockedSnapshot {
                let photo = WordPhoto(image: shot)
                photo.word = past
                modelContext.insert(photo)
                let lang = language
                Task { @MainActor in
                    async let visionTask = AIService.describeSnapshot(imageData: shot, language: lang)
                    async let placeTask = LocationService.shared.currentPlace(language: lang)
                    let (vision, place) = await (visionTask, placeTask)
                    photo.scene = vision.scene
                    photo.venue = vision.venue
                    photo.venueEmoji = vision.emoji
                    photo.placeCity = place.city
                    photo.placeCountry = place.country
                    try? modelContext.save()
                }
            }
            try? modelContext.save()

            let key = target.displayKey
            displayWord = key                        // drives showOverlay / the bottom card slot
            // Reuse the saved fields as a loaded card — instant, offline, identical
            // to what they saw when they saved it.
            cardStates[key] = .loaded(explanation(from: past))
            return
        }

        displayWord = target.displayKey

        if cardStates[target.displayKey] == nil {
            lookup(target)
        }
    }

    // Rebuild a WordExplanation from a saved word — used to render the reunion card
    // from stored data (same rebuild the library detail view does).
    private func explanation(from saved: SavedWord) -> WordExplanation {
        WordExplanation(
            word: saved.word,
            phonetic: saved.phonetic,
            partOfSpeech: saved.partOfSpeech,
            meanings: saved.meanings,
            contextPhrase: saved.contextPhrase,
            contextMeaning: saved.contextMeaning
        )
    }

    // The saved record for `term` IF pointing at it should trigger a reunion:
    // saved before today, and not a high-frequency function word. One-off fetch at
    // lock time (not per frame) — see the modelContext note at the top of this view.
    // Matched case-insensitively because OCR casing ("Submitted") can differ from the
    // canonical saved form ("submitted"), the same way WordCardView.isSaved matches.
    private func reunionCandidate(for term: String) -> SavedWord? {
        let key = term.lowercased()
        guard let saved = try? modelContext.fetch(FetchDescriptor<SavedWord>()),
              let match = saved.first(where: { $0.word.lowercased() == key }),
              Reunion.shouldTrigger(word: match) else { return nil }
        return match
    }

    // One thing to look up: the finger-pointed word.
    private struct QueryUnit {
        let displayKey: String   // card title + state key
        let term: String         // what we send to AI
        let context: String
    }

    // The finger-pointed word, if any. Underline / circle detection was removed,
    // so pointing is the only path to a result — always at most one word.
    //
    // OCR often glues the sentence's punctuation onto the word ("domain,"). We
    // clean it HERE, once, so the same string is the card title, the AI term, the
    // reunion-match key, the stored SavedWord, and the pronounced text — detail,
    // photo, and list thumbnail then all read identically. Guard against a token
    // that was ALL punctuation (cleaning to empty) by falling back to the raw text.
    private func targetWord() -> QueryUnit? {
        guard let w = camera.pointedWord, !w.text.isEmpty else { return nil }
        let clean = w.text.cleanedWord.isEmpty ? w.text : w.text.cleanedWord
        return QueryUnit(displayKey: clean, term: clean, context: w.context)
    }

    // MARK: - AI Lookup

    // Fire the lookup while the finger is still hovering (before the 0.4s
    // confirm). By the time the card opens the result is usually already cached,
    // so it appears instantly instead of after a spinner.
    private func prefetchHovered() {
        guard !isLocked, let w = camera.hoveringWord, !w.text.isEmpty else { return }
        // Clean identically to targetWord() so the prefetch caches under the SAME
        // key the locked card will read — otherwise "domain," and "domain" would
        // miss each other's cache and refetch.
        let clean = w.text.cleanedWord.isEmpty ? w.text : w.text.cleanedWord
        lookup(QueryUnit(displayKey: clean, term: clean, context: w.context))
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
                // Always a single pointed word now (marks removed), so isPhrase=false
                // and the phonetic anchor is the word itself.
                for try await partial in aiService.streamLookup(
                    unit.term, context: unit.context, language: lang,
                    isPhrase: false, phoneticWord: unit.term
                ) {
                    await MainActor.run { cardStates[key] = .loaded(partial) }
                }
            } catch {
                await MainActor.run {
                    // Network/AI failed. Before showing a dead "retry" card, try the
                    // bundled offline dictionary — the subway safety net. Only if we
                    // haven't already streamed a partial answer in.
                    if case .loading = cardStates[key] ?? .loading(key) {
                        if let offline = OfflineDictionary.shared.lookup(unit.term, language: lang) {
                            cardStates[key] = .loaded(offline)
                        } else {
                            cardStates[key] = .failed(key)
                        }
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
    // The manager borrows this layer to convert a Vision point → device focus point
    // (captureDevicePointConverted). weak on its side; we just hand it the reference.
    weak var focusTarget: CameraManager?

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
        focusTarget?.previewLayer = layer
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

// The saved-word count for the top-right badge, isolated in its own leaf view.
//
// WHY A SEPARATE VIEW: when this @Query lived on CameraView, the count only
// refreshed when the app relaunched — tapping ♥ to save/unsave did nothing to it
// live. CameraView is a very large view whose body also depends on the
// @Observable CameraManager, which mutates ~10×/sec from the frame pipeline.
// SwiftData delivers its store-change invalidation to @Query, but on a host view
// that heavy, SwiftUI coalesced the count's update away between the constant
// camera-driven re-evaluations, so the displayed number went stale until the
// view tree was rebuilt (relaunch). A leaf whose ENTIRE body is just this query
// has nothing to coalesce against, so every insert/delete redraws it at once.
private struct SavedBadgeLabel: View {
    @Query private var saved: [SavedWord]
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.deviceDefault.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    var body: some View {
        // Localized, width-stable count (Plan A): grouped below 10k ("52,089"),
        // compact above ("5.2万" / "52K"). Never truncates, never jitters the pill.
        Text(language.badgeCount(saved.count))
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

// A horizontal glow band that sweeps top→bottom on repeat while the recognition
// screen is up. Purely decorative feedback ("recognition mode is live"); it
// carries no layout and ignores touches. Design notes:
//   • GREEN (#32f08c), the brand recognition accent.
//   • The LEADING (bottom) edge is a crisp green line — kept sharp, no blur, no
//     drop shadow — with a soft glow TRAILING upward behind it. So it reads as a
//     clean light front gliding down the page, not a fuzzy blob with halos.
//   • Spans the full screen width, feathered at the left/right ends.
//   • Travels from 30% to 85% down the screen (over the reading area).
//   • Fades IN at the top and OUT near the bottom so each pass ends softly
//     instead of decelerating and hard-snapping back to the top.
//
// The sweep is driven by TimelineView(.animation), NOT a withAnimation state
// tween. Reason: the fade in/out is a piecewise (non-monotonic) function of the
// pass progress, so a single 0→1 state interpolation can't reproduce it — the
// body only re-evaluates at the animation's END. TimelineView re-evaluates every
// frame, so BOTH the position and the fade track the same time-derived phase.
struct ScanLineView: View {
    // One full pass, in seconds. The fade windows below are fractions of this.
    private let period: Double = 2.5

    // #32f08c — the green recognition accent.
    private let glow = Color(red: 0.196, green: 0.941, blue: 0.549)

    // Trailing glow height above the crisp leading edge. Kept shorter so the
    // upward glow is a light, quick falloff — not a heavy column of green.
    private let bandHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            TimelineView(.animation) { timeline in
                // phase 0→1 over `period`, looping. Derived from wall-clock time so
                // the motion is steady (linear) and the fade can be a free function
                // of it rather than a state tween.
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t.truncatingRemainder(dividingBy: period)) / period)

                // Leading (bright, sharp) edge travels from 30% top → 85% (15% from
                // the bottom).
                let leadingY = h * 0.30 + phase * (h * 0.55)

                // Fade IN over the first 12% of the pass, OUT over the last 18%, so
                // each loop appears at the top and vanishes before it snaps back —
                // no lingering, no hard reset ("最后消失有点慢/生硬").
                let sweepOpacity = min(phase / 0.12, (1 - phase) / 0.18, 1)

                ZStack {
                    // A very light focus vignette: darkens the far edges a touch so
                    // attention settles toward the center of the page. Kept
                    // restrained (edges only to ~0.13) to preserve the 留白 calm — a
                    // focus cue, never a heavy frame. It rides the parent's opacity
                    // transition in/out with the sweep.
                    RadialGradient(
                        colors: [.clear, .clear, Color.black.opacity(0.13)],
                        center: .center,
                        startRadius: h * 0.18,
                        endRadius: h * 0.72
                    )

                    // The green sweep: a soft glow trailing UPWARD, capped by a
                    // crisp green leading line at the bottom. No blur / no shadow,
                    // so the bottom edge stays sharp and nothing bleeds above/below.
                    ZStack(alignment: .bottom) {
                        // Soft trailing glow — transparent at the top, building to
                        // the leading edge. Lighter ramp so the upper half of the
                        // sweep isn't a heavy green block; the light lives mostly
                        // near the crisp line. All stops here are 30% lighter than
                        // before (×0.7) so the sweep recedes and the finger's green
                        // dot reads as the brightest thing on screen.
                        LinearGradient(
                            colors: [
                                .clear,
                                glow.opacity(0.042),
                                glow.opacity(0.154),
                                glow.opacity(0.35)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: bandHeight)

                        // Crisp leading edge — a clean 1px green line, full width,
                        // no shadow. This is the "下边缘保持清晰" front of the sweep.
                        // Opacity also dropped 30% (0.95→0.665) to sit behind the dot.
                        Rectangle()
                            .fill(glow.opacity(0.665))
                            .frame(height: 1)
                    }
                    .frame(width: w, height: bandHeight)
                    // Soft horizontal fade so the band doesn't end in hard vertical
                    // edges — full-strength across the middle 70%, feathering in the
                    // outer ~15% each side, so it still reaches the screen edges but
                    // the ends read soft, not cut.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white, location: 0.15),
                                .init(color: .white, location: 0.85),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    // Anchor the band's BOTTOM (the crisp line) at leadingY.
                    .position(x: w / 2, y: leadingY - bandHeight / 2)
                    .opacity(sweepOpacity)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .transition(.opacity)
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
