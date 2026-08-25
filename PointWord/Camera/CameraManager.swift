import AVFoundation
import Vision
import Combine
import CoreGraphics
import UIKit

// Manages camera session and all Vision processing (OCR + hand pose + color marks).
class CameraManager: NSObject, ObservableObject {
    @Published var detectedWords: [DetectedWord] = []
    @Published var fingerVisionPoint: CGPoint? = nil  // Vision space, bottom-left origin
    @Published var pointedWord: DetectedWord? = nil
    @Published var hoveringText: String? = nil        // word under finger before confirmed
    @Published var hoveringWord: DetectedWord? = nil  // same, with context — used for AI prefetch
    @Published var colorMarks: [ColorMark] = []       // stable detected marks on paper
    @Published var isScanning: Bool = false           // a target is being confirmed → show bottom hint
    @Published var permissionDenied: Bool = false     // camera access denied/restricted → show settings fallback
    @Published var isPreviewLive: Bool = false        // first frame has arrived → the preview is actually showing pixels
    @Published var isStalled: Bool = false            // frames stalled while we intend to run → surface a recover affordance

    // A crisp still of the frame at lock time. Displayed over the live preview so
    // the result "freezes" — green boxes then sit on fixed pixels and never drift
    // with subsequent OCR/hand movement. Cleared on rescan.
    @Published var frozenImage: UIImage? = nil
    private var freezeRequested = false               // processing-queue only

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "pw.vision", qos: .userInitiated)
    private let colorMarkService = ColorMarkService()

    private lazy var ocrRequest: VNRecognizeTextRequest = {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate          // 精确模式，读印刷体更准
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["en-US"]      // 只识别英文
        req.minimumTextHeight = 0.01              // 允许更小的字
        return req
    }()

    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 1
        return req
    }()

    // Finger tracking — spatial + temporal, NOT text-anchored.
    //
    // OCR text flickers frame-to-frame ("Origin"→"Orgin", word split in two),
    // so anchoring confirmation on the recognized *string* never settles. We
    // instead anchor on the fingertip's *position*: hold roughly the same spot
    // for hoverDuration and we confirm, reading whatever the freshest OCR word
    // at that spot happens to be. Only touched on the main thread.
    private var anchorPoint: CGPoint? = nil        // vision-space point being held
    private var anchorStart: Date? = nil
    private let hoverDuration: TimeInterval = 0.3   // dwell before confirming the pointed word
    private let anchorTolerance: CGFloat = 0.07    // stay within this to keep the anchor
    // We sample the word the NAIL points at: project a point just past the
    // fingertip along the finger's own pointing direction (knuckle → tip), then
    // prefer the word whose box contains it. This replaces the old fixed
    // "hand enters from below" +y guess, which grabbed whichever word sat around
    // the hand rather than the one being pointed at.
    private let fingerProjection: CGFloat = 0.03   // how far past the nail to sample
    private let fingerReach: CGFloat = 0.09        // fallback: max nail→word-edge gap to count

    // Color mark stabilization — keyed on POSITION, not text (same reason as above).
    // Only touched on main thread.
    //
    // PER-MARK tracking with HAND-SHAKE TOLERANCE. Phones are held by hand and
    // always drift a little; the mark's box wanders a few % every frame. Two
    // things must survive that:
    //   1. Identity — a frame's mark is matched to last frame's track by PROXIMITY
    //      (nearest same-type mark within markMatchDistance), NOT by an exact grid
    //      key. So a mark sliding across a grid boundary is still "the same mark"
    //      and its dwell timer keeps accumulating instead of resetting.
    //   2. Presence — a track survives brief dropouts (markGracePeriod). Detection
    //      naturally blinks out for a frame or two under shake / motion blur; we
    //      don't drop the track (or the published card) for that.
    // Result: normal handheld jitter never stalls recognition or flickers a card.
    private struct TrackedMark {
        var mark: ColorMark
        let firstSeen: Date
        var lastSeen: Date
    }
    private var trackedMarks: [TrackedMark] = []
    private let markStableDuration: TimeInterval = 0.4    // dwell before a mark publishes
    private let markMatchDistance: CGFloat = 0.07         // normalized center distance = "same mark"
    private let markGracePeriod: TimeInterval = 0.4       // keep a track through brief dropouts
    private var anyMarkConfirming = false                 // a mark is seen but not yet stable → drives scanning pill

    // isScanning debounce (main-thread only). The confirming signals below
    // (hovering word, stabilizing mark) blink nil↔value between frames because
    // OCR / mark detection is noisy. The "recognizing…" pill and the idle hint
    // share the bottom slot and are mutually exclusive on isScanning, so a raw
    // per-frame toggle made the two pills swap back and forth — the flicker. We
    // turn the pill ON immediately, but only turn it OFF after the confirming
    // signal has stayed gone for scanningOffGrace, so a momentary gap can't drop it.
    private var scanningOffSince: Date? = nil
    private let scanningOffGrace: TimeInterval = 0.45

    // OCR / color scan are heavy — run them every N frames and reuse the last
    // result in between. Hand pose stays every-frame so the finger dot is smooth.
    private var frameCounter = 0
    private let heavyWorkInterval = 2
    private var lastWords: [DetectedWord] = []
    private var lastMarks: [ColorMark] = []

    // Finger stillness (processing-queue only) — tells a POINTING hand (held
    // still over a word) apart from a DRAWING hand (moving a pen along a line).
    // A still finger suppresses mark detection so pointing stays authoritative;
    // a moving hand lets underline/circle detection run so drawing is still read.
    private var lastFingerPoint: CGPoint? = nil
    private var fingerStillSince: Date? = nil
    private let fingerStillTolerance: CGFloat = 0.03   // vision-space wobble allowed
    private let fingerStillDelay: TimeInterval = 0.25  // held this long → "pointing"

    // Most recent frame as a small JPEG — captured when a word is saved so the
    // library card can show the page the user was reading. Updated on heavy frames.
    private let snapshotLock = NSLock()
    private var lastSnapshot: Data? = nil
    private var lastSnapshotTime: Date = .distantPast
    private let snapshotInterval: TimeInterval = 0.6   // throttle heavy JPEG encoding

    // Returns a downscaled JPEG of the current camera frame (for library thumbnails).
    func currentSnapshot() -> Data? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return lastSnapshot
    }

    // Freeze the preview: render the next frame full-screen as a still and publish
    // it. The live session keeps running underneath (cheaper than stop/restart and
    // avoids a black flash on resume) — the still just covers it.
    func freeze() {
        processingQueue.async { [weak self] in self?.freezeRequested = true }
    }

    // Resume live preview.
    func unfreeze() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.frozenImage != nil else { return }
            self.frozenImage = nil
        }
    }

    private let ciContext = CIContext()

    // Frame watchdog — a session can report isRunning while silently delivering
    // no frames (some capture errors post no notification). If frames stall past
    // frameStallTimeout, force a full restart. Cooldown avoids thrashing.
    private let frameLock = NSLock()
    private var lastFrameTime: Date = .distantPast
    private var watchdog: Timer?
    private let frameStallTimeout: TimeInterval = 2.0
    private var lastRestartTime: Date = .distantPast   // main-thread only
    private let restartCooldown: TimeInterval = 3.0
    // Our INTENT: true between start() and stop(). The watchdog recovers on this,
    // not on session.isRunning — a system interruption (call, Control Center,
    // another camera client, thermal) forces isRunning false, and iOS often never
    // delivers interruptionEnded, so gating recovery on isRunning would leave us
    // permanently frozen (the "stuck on a dead camera frame" bug). We know we
    // should be live, so we retry regardless of the session's current flag.
    private var shouldBeRunning = false                // main-thread only

    override init() {
        super.init()
        setupCamera()
    }

    // Force the scanning latch back to idle. Called when the view (re)enters the
    // live screen: on resume the capture session restarts and no frame has yet
    // arrived to recompute isScanning, so a value left true from before
    // backgrounding would linger and suppress the idle hint for its whole window.
    // At an entry point we are idle by definition, so clearing it is safe.
    func resetScanningState() {
        scanningOffSince = nil
        if isScanning { isScanning = false }
    }

    // Wipe ALL detection outputs. Called when a result card is dismissed / the
    // user taps 重新识别. Without this, pointedWord / colorMarks / the hover
    // anchor keep their values from the LAST recognition, so the very next frame
    // re-fires recompute() with stale data — a card pops up instantly (before the
    // finger even settles) showing the PREVIOUS word, not what's under the finger
    // now. Clearing everything forces a fresh confirmation from a clean slate.
    func resetDetection() {
        pointedWord = nil
        hoveringWord = nil
        hoveringText = nil
        anchorPoint = nil
        anchorStart = nil
        colorMarks = []
        trackedMarks.removeAll()
        resetScanningState()
    }

    // MARK: - Setup

    private func setupCamera() {
        session.sessionPreset = .hd1280x720

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        observeSessionHealth()
    }

    // The capture source can hit a runtime error (err=-17281) or get interrupted
    // by the system; AVFoundation does NOT auto-recover. Without this the preview
    // keeps showing but frames stop flowing — recognition silently dies after a
    // few seconds. Restart the session whenever that happens.
    private func observeSessionHealth() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: AVCaptureSession.runtimeErrorNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: AVCaptureSession.interruptionEndedNotification, object: session)
        // Also observe the START of an interruption. iOS does NOT reliably deliver
        // interruptionEnded (especially after the interruptor — a call, Control
        // Center, another camera client — goes away), so we can't rely on it to
        // restart. We record that we were interrupted; the watchdog then recovers
        // us on its own, gated on INTENT (shouldBeRunning) rather than on the
        // session's current isRunning, which an interruption forces false.
        nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                       name: AVCaptureSession.wasInterruptedNotification, object: session)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        print("🔴 相机会话运行时错误：\(err?.code ?? 0) — 尝试重启")
        restartSession()
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        print("🟡 相机会话被系统中断：reason=\(reason) — 依赖看门狗自愈")
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        restartSession()
    }

    // Recovery escalates. A plain stop/start (level 0) fixes most stalls cheaply.
    // But when the system reclaims the camera (another client, thermal, resource
    // pressure) a bare restart of the SAME session often can't get it back — the
    // input is dead. On the next attempt we escalate to a FULL rebuild: rip the
    // input/output out and reconfigure from scratch, which reacquires the device.
    private var restartLevel = 0                       // processing-queue only

    private func restartSession() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        markFrameSeen()   // give the restart a fresh grace window before the watchdog fires again
        processingQueue.async { [weak self] in
            guard let self else { return }
            if self.restartLevel == 0 {
                // Cheap path: just bounce the running session.
                if self.session.isRunning { self.session.stopRunning() }
                self.session.startRunning()
                self.restartLevel = 1
            } else {
                // Escalated path: fully rebuild the capture graph to reacquire the
                // device the system took away.
                self.rebuildSession()
            }
        }
    }

    // Tear the capture graph down and build it back up. Reacquires the camera
    // device from scratch — the only reliable way back after the system hands the
    // camera to another client and never returns it via interruptionEnded.
    private func rebuildSession() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()

        session.sessionPreset = .hd1280x720
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.isRunning { session.stopRunning() }
        session.startRunning()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        watchdog?.invalidate()
    }

    // MARK: - Lifecycle

    func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setDenied(false)
            startSession()
            probeNetworkPermission()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.setDenied(false)
                    self?.startSession()
                    // Fire the network probe right after camera is granted, so the
                    // iOS "wireless data" prompt appears now instead of waiting for
                    // the first word lookup.
                    self?.probeNetworkPermission()
                } else {
                    self?.setDenied(true)
                }
            }
        default:
            // Denied or restricted — surface the settings fallback.
            setDenied(true)
        }
    }

    // Trigger the iOS network-permission prompt eagerly, right after camera
    // access is granted, rather than lazily on the first word lookup. On
    // China-region iOS the "wireless data" dialog only appears on the app's first
    // outbound connection; making that connection now means the user answers it
    // up front and the first real lookup isn't spent on the prompt. Fire-and-
    // forget: we hit the same proxy host (so it's the same permission scope),
    // ignore the response, and run at most once per launch.
    private var didProbeNetwork = false
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private func probeNetworkPermission() {
        guard !didProbeNetwork else { return }
        didProbeNetwork = true
        guard let url = URL(string: Config.apiProxyURL) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"          // no body needed — we only want the connection to open
        let task = Self.probeSession.dataTask(with: req) { _, _, _ in
            // Result is irrelevant. The point was to open a connection so iOS
            // shows its network dialog now; success/failure both satisfy that.
        }
        task.resume()
    }

    private func setDenied(_ denied: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.permissionDenied != denied else { return }
            self.permissionDenied = denied
        }
    }

    private func startSession() {
        shouldBeRunning = true            // record intent so the watchdog can recover us
        guard !session.isRunning else { return }
        markFrameSeen()   // start the grace window now, before frames arrive
        processingQueue.async { self.session.startRunning() }
        startWatchdog()
    }

    func stop() {
        shouldBeRunning = false           // deliberate stop — watchdog must NOT fight it
        stopWatchdog()
        processingQueue.async { self.session.stopRunning() }
        // The next start must wait for a fresh first frame before the preview is
        // considered live again. Without this reset, isPreviewLive stays true
        // across a stop/start, so the hint-and-detection resume logic that gates
        // on "first frame arrived" thinks pixels are already flowing and never
        // re-arms — a big reason the app "went dead" on the second entry.
        DispatchQueue.main.async { [weak self] in
            self?.isPreviewLive = false
            self?.isStalled = false
        }
    }

    // MARK: - Frame watchdog

    private func markFrameSeen() {
        frameLock.lock()
        lastFrameTime = Date()
        frameLock.unlock()
    }

    // A word is usable for MARK detection unless its box is clipped by the frame
    // edge. A cropped fragment ("developers"→"lopers") has a box that runs right
    // up to a border, and the strip just outside it collides with the frame edge /
    // neighbouring line and false-fires as an underline. We reject ONLY words that
    // actually touch an edge (within a small epsilon) — not a wide inset, which
    // previously (margin 0.12) also threw away perfectly framed words near the
    // sides, so their underline/circle "couldn't be detected". Finger pointing
    // uses the full word list, so pointing at an edge word is unaffected.
    private func isCentered(_ box: CGRect) -> Bool {
        let edge: CGFloat = 0.02
        return box.minX > edge && box.maxX < 1 - edge
            && box.minY > edge && box.maxY < 1 - edge
    }

    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.watchdog == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkFrameFlow()
            }
            // .common so it keeps firing during scroll / interaction.
            RunLoop.main.add(timer, forMode: .common)
            self.watchdog = timer
        }
    }

    private func stopWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdog?.invalidate()
            self?.watchdog = nil
        }
    }

    // Runs on the main thread once a second. Recovers whenever frames have stalled
    // while we intend to be live — gated on shouldBeRunning, NOT session.isRunning.
    // A system interruption forces isRunning false and iOS may never send
    // interruptionEnded, so an isRunning gate would freeze us forever. As long as
    // WE meant to be running and frames dried up, restart (subject to cooldown).
    private func checkFrameFlow() {
        guard shouldBeRunning else { return }

        frameLock.lock()
        let since = Date().timeIntervalSince(lastFrameTime)
        frameLock.unlock()

        guard since >= frameStallTimeout else { return }

        // Frames have dried up while we mean to be live → tell the UI so it can
        // stop looking dead and offer a manual recover tap. Cleared the instant a
        // real frame arrives again (see captureOutput).
        if !isStalled { isStalled = true }

        guard Date().timeIntervalSince(lastRestartTime) >= restartCooldown else { return }

        lastRestartTime = Date()
        print("🔴 看门狗：\(String(format: "%.1f", since))s 无新帧 (isRunning=\(session.isRunning)) — 强制重启会话")
        restartSession()
    }

    // Manual recovery — the on-screen "tap to recover" affordance calls this.
    // Escalates straight to a full rebuild (skip the cheap bounce that the
    // watchdog already tried) and re-arms our run intent.
    func forceRecover() {
        shouldBeRunning = true
        startWatchdog()
        markFrameSeen()
        processingQueue.async { [weak self] in
            self?.restartLevel = 1
            self?.rebuildSession()
        }
    }
}

// MARK: - Frame Processing

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        markFrameSeen()   // heartbeat for the frame watchdog

        // Real frames are flowing again → recovery worked. Reset the escalation
        // ladder so the next stall starts cheap again, and clear the stalled flag
        // that surfaces the on-screen recover affordance.
        restartLevel = 0
        if isStalled {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isStalled else { return }
                self.isStalled = false
            }
        }

        // First real frame → the preview is now showing pixels. The idle hint
        // waits on this so its display window starts when the page is visible,
        // not during the black startup gap (which was eating the whole window on
        // cold launch, so the hint "never appeared").
        if !isPreviewLive {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isPreviewLive else { return }
                self.isPreviewLive = true
            }
        }

        frameCounter += 1
        // OCR + color scan are expensive; only run them every heavyWorkInterval frames.
        let runHeavy = (frameCounter % heavyWorkInterval == 0)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])

        // Hand pose is light — always run it so finger tracking stays smooth.
        // OCR only runs on heavy frames.
        let requests: [VNRequest] = runHeavy ? [ocrRequest, handPoseRequest] : [handPoseRequest]
        do {
            try handler.perform(requests)
        } catch { return }

        let fingerData = fingerTip(from: handPoseRequest.results?.first)
        let finger = fingerData?.tip
        let fingerIsPointing = updateFingerStillness(finger)

        if runHeavy {
            lastWords = extractWords()
            // Arbitration between the two core gestures:
            //   • Finger held STILL over a word = pointing. Suppress mark detection
            //     so a colored cover / underline-looking texture can never
            //     pre-empt the word being pointed at.
            //   • Hand MOVING (or absent) = the user may be drawing an underline /
            //     circle with a pen. Run mark detection so drawing is still read
            //     even though a hand is in frame.
            if fingerIsPointing {
                lastMarks = []
            } else {
                // Only look for marks on words that sit COMFORTABLY INSIDE the
                // frame. Words cropped by the screen edge (e.g. "developers" →
                // "lopers", "discount" → "ount") have broken boxes; the strip
                // below them collides with the frame border / neighbouring line
                // and false-triggers as an underline — repeatedly winning over
                // the actual centered word the user marked. Dropping edge-cropped
                // words from mark candidates removes that whole error class.
                // Finger pointing still uses the full word list (below), so a
                // pointed edge word is unaffected.
                let central = lastWords.filter { isCentered($0.boundingBox) }
                lastMarks = colorMarkService.detectAll(in: pixelBuffer, words: central)
            }
            updateSnapshot(from: pixelBuffer)
        }
        let words = lastWords
        let marks = lastMarks

        // A freeze was requested — render this frame full-res, oriented to match
        // the preview, and publish it. Do it here so it captures a fresh frame.
        if freezeRequested {
            freezeRequested = false
            let still = renderFullFrame(from: pixelBuffer)
            DispatchQueue.main.async { [weak self] in self?.frozenImage = still }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if runHeavy {
                self.detectedWords = words
                self.updateColorMarks(marks)
            }
            self.fingerVisionPoint = finger
            self.updatePointedWord(finger: finger, dir: fingerData?.dir,
                                   words: words, pointing: fingerIsPointing)
            self.updateScanningState()
        }
    }

    private func extractWords() -> [DetectedWord] {
        guard let results = ocrRequest.results else { return [] }
        var words: [DetectedWord] = []

        for obs in results {
            guard let candidate = obs.topCandidates(1).first, candidate.confidence > 0.3 else { continue }
            let fullText = candidate.string
            var searchStart = fullText.startIndex

            for token in fullText.split(separator: " ", omittingEmptySubsequences: true) {
                let tokenStr = String(token)
                guard
                    let range = fullText.range(of: tokenStr, range: searchStart..<fullText.endIndex),
                    let box = try? candidate.boundingBox(for: range)
                else { continue }

                words.append(DetectedWord(
                    text: tokenStr,
                    boundingBox: box.boundingBox,
                    confidence: candidate.confidence,
                    context: fullText
                ))
                let afterToken = range.upperBound
                searchStart = fullText.index(afterToken, offsetBy: 1, limitedBy: fullText.endIndex) ?? fullText.endIndex
                if searchStart >= fullText.endIndex { break }
            }
        }
        return words
    }

    // Downscale the frame and store it as a small JPEG for library thumbnails.
    // Frame comes in rotated (.right); apply the same rotation so the saved
    // image matches what the user sees on screen.
    private func updateSnapshot(from pixelBuffer: CVPixelBuffer) {
        // JPEG encoding is expensive — throttle it so it doesn't starve the
        // capture pipeline (a frequent trigger of frame-flow stalls).
        let now = Date()
        guard now.timeIntervalSince(lastSnapshotTime) >= snapshotInterval else { return }
        lastSnapshotTime = now

        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)

        // Target ~600px on the long side — plenty for a card, keeps storage small.
        let extent = ci.extent
        let maxSide = max(extent.width, extent.height)
        guard maxSide > 0 else { return }
        let scale = min(1.0, 600.0 / maxSide)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)

        snapshotLock.lock()
        lastSnapshot = data
        snapshotLock.unlock()
    }

    // Full-resolution still oriented like the preview (.right), for the freeze
    // overlay. Not downscaled — it fills the screen and must stay crisp.
    private func renderFullFrame(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // The index fingertip plus a unit vector along the finger's pointing
    // direction (index MCP knuckle → tip). Direction lets us sample the word
    // just past the NAIL instead of guessing the hand always enters from below.
    private func fingerTip(from obs: VNHumanHandPoseObservation?) -> (tip: CGPoint, dir: CGVector)? {
        guard let obs else { return nil }

        func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            (try? obs.recognizedPoint(joint)).flatMap { $0.confidence > 0.3 ? $0.location : nil }
        }

        // Prefer the index finger; fall back to the middle finger if occluded.
        if let tip = point(.indexTip) {
            let base = point(.indexPIP) ?? point(.indexMCP)
            return (tip, direction(from: base, to: tip))
        }
        if let tip = point(.middleTip) {
            let base = point(.middlePIP) ?? point(.middleMCP)
            return (tip, direction(from: base, to: tip))
        }
        return nil
    }

    // Unit vector base → tip; falls back to "up the page" if the base joint is
    // missing (Vision space, bottom-left origin, so pointing away from the hand
    // that entered from the page bottom means +y).
    private func direction(from base: CGPoint?, to tip: CGPoint) -> CGVector {
        guard let base else { return CGVector(dx: 0, dy: 1) }
        let dx = tip.x - base.x, dy = tip.y - base.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return CGVector(dx: 0, dy: 1) }
        return CGVector(dx: dx / len, dy: dy / len)
    }

    // Returns true once the fingertip has stayed within fingerStillTolerance for
    // fingerStillDelay — i.e. the user is POINTING, not sweeping a pen along a
    // line. A moving hand (drawing) or no hand returns false, which keeps mark
    // detection alive. Processing-queue only.
    private func updateFingerStillness(_ finger: CGPoint?) -> Bool {
        guard let finger else {
            lastFingerPoint = nil
            fingerStillSince = nil
            return false
        }
        if let last = lastFingerPoint,
           hypot(finger.x - last.x, finger.y - last.y) <= fingerStillTolerance {
            // Still roughly in place — start / keep the stillness clock.
            if fingerStillSince == nil { fingerStillSince = Date() }
        } else {
            // Moved beyond tolerance — the hand is traveling (drawing). Reset.
            fingerStillSince = nil
        }
        lastFingerPoint = finger
        guard let since = fingerStillSince else { return false }
        return Date().timeIntervalSince(since) >= fingerStillDelay
    }

    // All mutations here run on main thread.
    //
    // Position-anchored confirmation: we don't care what OCR *calls* the word,
    // only that the finger dwells over the same spot. This is robust to OCR
    // string flicker, which was the main reason pointing never confirmed.
    //
    // `pointing` = the fingertip has actually STOPPED (held still for
    // fingerStillDelay). A word is only promoted to the confirmed result while
    // the finger is stopped ON it. Mid-travel — sweeping the hand toward the
    // target — the word under the probe is exposed for prefetch but NEVER
    // confirmed, so a word merely passed over on the way (e.g. "the") can't fire
    // a result before the finger reaches where the user is actually aiming.
    private func updatePointedWord(finger: CGPoint?, dir: CGVector?,
                                   words: [DetectedWord], pointing: Bool) {
        guard let finger else {
            clearHover()
            return
        }

        // Sample the spot the NAIL points at: step just past the fingertip along
        // the finger's own direction. This lands on the word being pointed at
        // regardless of which side the hand comes from, instead of the old fixed
        // "+y" guess that assumed the hand always enters from the page bottom.
        let d = dir ?? CGVector(dx: 0, dy: 1)
        let probe = CGPoint(
            x: min(max(finger.x + d.dx * fingerProjection, 0), 1),
            y: min(max(finger.y + d.dy * fingerProjection, 0), 1)
        )

        // Pick the pointed word:
        //   1. Prefer a word whose box actually CONTAINS the probe (the nail is
        //      resting on it). If several overlap, take the smallest — the tight
        //      match, never a big box that merely spans the area.
        //   2. Otherwise fall back to the nearest word EDGE within fingerReach —
        //      distance to the box, not its center, so a long word isn't lost to
        //      a short neighbour just because its center is farther away.
        let containing = words
            .filter { $0.boundingBox.contains(probe) }
            .min(by: { boxArea($0) < boxArea($1) })

        let candidate: DetectedWord?
        if let containing {
            candidate = containing
        } else {
            let nearest = words.min(by: { edgeDistance(probe, to: $0) < edgeDistance(probe, to: $1) })
            candidate = (nearest.map { edgeDistance(probe, to: $0) } ?? .greatestFiniteMagnitude) < fingerReach
                ? nearest : nil
        }

        guard let candidate else {
            clearHover()
            return
        }

        // Keep the anchor if the finger is still near where it started dwelling;
        // otherwise (re)start the dwell timer at the new spot.
        if let anchor = anchorPoint, hypot(probe.x - anchor.x, probe.y - anchor.y) < anchorTolerance {
            // Still holding — publish hovering word for prefetch, confirm on dwell.
            // Compare by text (ids regenerate each frame) to avoid needless publishes.
            if hoveringWord?.text != candidate.text {
                hoveringText = candidate.text
                hoveringWord = candidate
            }
            // Confirm ONLY when the fingertip has actually stopped (pointing) AND
            // has dwelled long enough. Without the `pointing` gate a word skimmed
            // over while moving the hand toward the target would confirm early.
            if pointing,
               let start = anchorStart, Date().timeIntervalSince(start) >= hoverDuration,
               pointedWord?.text != candidate.text {
                pointedWord = candidate
            }
        } else {
            // Moved to a new spot — reset dwell, expose for prefetch immediately.
            anchorPoint = probe
            anchorStart = Date()
            hoveringText = candidate.text
            hoveringWord = candidate
            pointedWord = nil
        }
    }

    private func clearHover() {
        hoveringText = nil
        hoveringWord = nil
        anchorPoint = nil
        anchorStart = nil
        pointedWord = nil
    }

    private func boxArea(_ word: DetectedWord) -> CGFloat {
        word.boundingBox.width * word.boundingBox.height
    }

    // Distance from a point to the NEAREST EDGE of a word's box (0 if inside).
    // Center distance unfairly penalizes long words; edge distance reflects how
    // close the nail actually is to the word.
    private func edgeDistance(_ p: CGPoint, to word: DetectedWord) -> CGFloat {
        let b = word.boundingBox
        let dx = max(b.minX - p.x, 0, p.x - b.maxX)
        let dy = max(b.minY - p.y, 0, p.y - b.maxY)
        return hypot(dx, dy)
    }

    // Match this frame's candidates to existing tracks by proximity, age the
    // survivors, drop only tracks that have been gone longer than the grace
    // window, then publish every track that has dwelled long enough. Handheld
    // jitter (small box drift, one/two-frame dropouts) is absorbed, so a stable
    // intent doesn't get reset or flicker.
    private func updateColorMarks(_ candidates: [ColorMark]) {
        let now = Date()

        // 1. Match each candidate to the nearest same-type track within range,
        //    updating that track's mark + lastSeen. Unmatched candidates spawn
        //    new tracks. Each track matches at most one candidate per frame.
        var used = Set<Int>()   // indices into trackedMarks already matched
        for cand in candidates {
            var bestIdx = -1
            var bestDist = markMatchDistance
            for (i, t) in trackedMarks.enumerated() where !used.contains(i) {
                guard t.mark.markType == cand.markType else { continue }
                let d = centerDistance(t.mark.boundingBox, cand.boundingBox)
                if d < bestDist { bestDist = d; bestIdx = i }
            }
            if bestIdx >= 0 {
                used.insert(bestIdx)
                trackedMarks[bestIdx].mark = cand          // adopt latest geometry/words
                trackedMarks[bestIdx].lastSeen = now
            } else {
                trackedMarks.append(TrackedMark(mark: cand, firstSeen: now, lastSeen: now))
            }
        }

        // 2. Drop tracks unseen beyond the grace period (brief dropouts survive).
        trackedMarks.removeAll { now.timeIntervalSince($0.lastSeen) > markGracePeriod }

        // 3. Publish tracks that have persisted long enough. Still-settling
        //    tracks keep the scanning pill lit but don't publish yet.
        var stable: [ColorMark] = []
        var confirming = false
        for t in trackedMarks {
            if now.timeIntervalSince(t.firstSeen) >= markStableDuration {
                stable.append(t.mark)
            } else {
                confirming = true
            }
        }
        anyMarkConfirming = confirming

        // Avoid thrashing colorMarks (and downstream) when the stable set's
        // identity is unchanged — compare by coarse position signature.
        let newSig = stable.map { markSignature($0) }.sorted()
        let oldSig = colorMarks.map { markSignature($0) }.sorted()
        if newSig != oldSig { colorMarks = stable }
    }

    // Normalized center-to-center distance between two boxes.
    private func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    // Coarse identity signature, ONLY for cheap set-equality of the published
    // list (not for tracking). Rounded loosely so sub-grid jitter can't flip it.
    private func markSignature(_ m: ColorMark) -> String {
        let b = m.boundingBox
        let gx = Int((b.midX * 12).rounded())
        let gy = Int((b.midY * 12).rounded())
        return "\(m.markType)@\(gx),\(gy)"
    }

    // Scanning = a target is detected but not yet confirmed:
    //   • finger is hovering a word but hasn't been held long enough, or
    //   • marks have been seen but aren't stable enough to publish yet.
    // Drives the bottom "recognizing…" hint.
    //
    // Debounced so it doesn't flicker: the raw signal blinks between frames as
    // OCR / mark detection jitters. Rising edge is immediate (feels responsive);
    // falling edge waits scanningOffGrace so a one-frame dropout can't blink the
    // pill out and let the idle hint flash in its place.
    private func updateScanningState() {
        let fingerConfirming = (hoveringText != nil && pointedWord == nil)
        let rawScanning = fingerConfirming || anyMarkConfirming

        if rawScanning {
            // Confirming right now — show immediately, clear any pending off timer.
            scanningOffSince = nil
            if !isScanning { isScanning = true }
        } else if isScanning {
            // Signal dropped. Hold the pill until it's been gone long enough,
            // so brief OCR/mark gaps don't cause a swap with the idle hint.
            if scanningOffSince == nil { scanningOffSince = Date() }
            if let since = scanningOffSince,
               Date().timeIntervalSince(since) >= scanningOffGrace {
                isScanning = false
                scanningOffSince = nil
            }
        } else {
            scanningOffSince = nil
        }
    }
}
