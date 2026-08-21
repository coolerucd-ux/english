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
    private let hoverDuration: TimeInterval = 0.4
    private let anchorTolerance: CGFloat = 0.05    // stay within this to keep the anchor
    // We sample the word the NAIL points at: project a point just past the
    // fingertip along the finger's own pointing direction (knuckle → tip), then
    // prefer the word whose box contains it. This replaces the old fixed
    // "hand enters from below" +y guess, which grabbed whichever word sat around
    // the hand rather than the one being pointed at.
    private let fingerProjection: CGFloat = 0.03   // how far past the nail to sample
    private let fingerReach: CGFloat = 0.05        // fallback: max nail→word-edge gap to count

    // Color mark stabilization — keyed on POSITION, not text (same reason as above).
    // Only touched on main thread.
    private var markStableKey: String? = nil
    private var markStableStart: Date? = nil
    private var publishedMarkKey: String? = nil    // dedupe: don't republish the same stable mark every frame
    private let markStableDuration: TimeInterval = 0.4

    // OCR / color scan are heavy — run them every N frames and reuse the last
    // result in between. Hand pose stays every-frame so the finger dot is smooth.
    private var frameCounter = 0
    private let heavyWorkInterval = 3
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

    override init() {
        super.init()
        setupCamera()
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
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        print("🔴 相机会话运行时错误：\(err?.code ?? 0) — 尝试重启")
        restartSession()
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        restartSession()
    }

    private func restartSession() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        markFrameSeen()   // give the restart a fresh grace window before the watchdog fires again
        processingQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.startRunning()
        }
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
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.setDenied(false)
                    self?.startSession()
                } else {
                    self?.setDenied(true)
                }
            }
        default:
            // Denied or restricted — surface the settings fallback.
            setDenied(true)
        }
    }

    // Note: we deliberately do NOT probe the network here. iOS shows its network
    // permission prompt on the app's first outbound request, and that happens
    // naturally on the user's first word lookup (AIService POST). Prompting only
    // then keeps users who just want to scan around from being interrupted.

    private func setDenied(_ denied: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.permissionDenied != denied else { return }
            self.permissionDenied = denied
        }
    }

    private func startSession() {
        guard !session.isRunning else { return }
        markFrameSeen()   // start the grace window now, before frames arrive
        processingQueue.async { self.session.startRunning() }
        startWatchdog()
    }

    func stop() {
        stopWatchdog()
        processingQueue.async { self.session.stopRunning() }
    }

    // MARK: - Frame watchdog

    private func markFrameSeen() {
        frameLock.lock()
        lastFrameTime = Date()
        frameLock.unlock()
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

    // Runs on the main thread once a second. Restart if the session thinks it's
    // running but no frame has arrived within frameStallTimeout — subject to a
    // cooldown so a restart-in-progress isn't immediately restarted again.
    private func checkFrameFlow() {
        guard session.isRunning else { return }

        frameLock.lock()
        let since = Date().timeIntervalSince(lastFrameTime)
        frameLock.unlock()

        guard since >= frameStallTimeout else { return }
        guard Date().timeIntervalSince(lastRestartTime) >= restartCooldown else { return }

        lastRestartTime = Date()
        print("🔴 看门狗：\(String(format: "%.1f", since))s 无新帧 — 强制重启会话")
        restartSession()
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
                lastMarks = colorMarkService.detectAll(in: pixelBuffer, words: lastWords)
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
            self.updatePointedWord(finger: finger, dir: fingerData?.dir, words: words)
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
    private func updatePointedWord(finger: CGPoint?, dir: CGVector?, words: [DetectedWord]) {
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
            if let start = anchorStart, Date().timeIntervalSince(start) >= hoverDuration,
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

    // Require marks over the same PAGE REGION to persist for markStableDuration
    // before publishing. Keyed on rounded position (not text) so OCR string
    // flicker within a stable underline doesn't keep resetting the timer.
    private func updateColorMarks(_ candidates: [ColorMark]) {
        guard !candidates.isEmpty else {
            markStableKey = nil
            markStableStart = nil
            publishedMarkKey = nil
            if !colorMarks.isEmpty { colorMarks = [] }
            return
        }

        let key = positionKey(candidates)
        if key != markStableKey {
            // Region changed — restart the dwell timer.
            markStableKey = key
            markStableStart = Date()
        } else if let start = markStableStart,
                  Date().timeIntervalSince(start) >= markStableDuration,
                  publishedMarkKey != key {
            // Region held long enough and not yet published — publish now.
            publishedMarkKey = key
            colorMarks = candidates
        }
    }

    // A location-based signature: mark type + box rounded to a coarse grid.
    // Stable across OCR text jitter, sensitive to the mark actually moving.
    private func positionKey(_ marks: [ColorMark]) -> String {
        marks.map { m -> String in
            let b = m.boundingBox
            let gx = Int((b.midX * 20).rounded())
            let gy = Int((b.midY * 20).rounded())
            let gw = Int((b.width * 20).rounded())
            return "\(m.markType)@\(gx),\(gy),\(gw)"
        }
        .sorted()
        .joined(separator: "~")
    }

    // Scanning = a target is detected but not yet confirmed:
    //   • finger is hovering a word but hasn't been held long enough, or
    //   • marks have been seen but aren't stable enough to publish yet.
    // Drives the bottom "recognizing…" hint.
    private func updateScanningState() {
        let fingerConfirming = (hoveringText != nil && pointedWord == nil)
        let marksConfirming = (markStableKey != nil && publishedMarkKey != markStableKey)
        let scanning = fingerConfirming || marksConfirming
        if scanning != isScanning { isScanning = scanning }
    }
}
