import AVFoundation
import Vision
import Observation
import CoreGraphics
import UIKit

// Manages the camera session and all Vision processing (OCR + hand pose).
//
// Recognition is FINGER-ONLY: the user points at a word and holds. Underline /
// circle ("color mark") detection was removed — on handheld, tilted paper it was
// unreliable and its per-word luma scan was the main frame-rate sink.
//
// ─────────────────────────────────────────────────────────────────────────────
// OBSERVATION MODEL — the freeze fix (part 1 of 2).
//
// This type is @Observable (Swift Observation, iOS 17+), NOT the old
// ObservableObject / @Published. That single change is the core of the freeze
// fix, and the reason must be spelled out:
//
//   Under ObservableObject, EVERY @Published mutation re-evaluates the WHOLE
//   body of every observing view. The frame pipeline publishes ~10×/sec
//   (finger point, probe, progress, hovering/pointed word …), so the entire
//   CameraView.body was recomputing ~10×/sec — including layout it no longer
//   even draws (detectedWords). Combined with a geometry read-back in that body,
//   iOS 26's stricter dependency tracking saw an AttributeGraph CYCLE and wedged
//   the whole SwiftUI graph. The hardware AVCaptureVideoPreviewLayer kept moving
//   underneath, so the picture animated while the blue dot, hints, card AND the
//   diagnostic HUD all went dead — the exact reported freeze.
//
//   @Observable tracks reads PER PROPERTY. A view re-evaluates only when a
//   property it ACTUALLY reads changes. detectedWords (written, never read by the
//   view) now triggers zero re-renders; the finger dot redraw touches only the dot.
//   The 10×/sec full-body churn — the fuel the cycle fed on — is gone.
//
// Property annotations below:
//   • plain `var`         → an OBSERVED output the view reads (dot, card, HUD…).
//   • `@ObservationIgnored` → internal machinery the view never reads. Excluding
//     it keeps the tracked surface minimal and avoids accidental invalidations.
//
// SESSION LIFECYCLE — the freeze fix (part 2 of 2).
//
// Everything that used to live here — a 1s frame watchdog, a dead-frame detector,
// a cold-start "never got a frame" rebuild, exponential-backoff restarts, a
// restart-flood lock, session teardown/rebuild — is GONE.
//
// Two findings drove this:
//   1. The err=-17281 / FigCaptureSourceRemote spam is NOISE on iOS 26, not the
//      freeze. Apple's own dev-forum threads show a clean, minimal
//      AVCaptureVideoDataOutput setup emits the identical assertions on iOS 26.x
//      but not on iOS 18 — "informational only". The old code treated the log as
//      a fault and reacted by tearing the session down and rebuilding it, which is
//      the single most reliable way to ACTUALLY wedge the shared camera server.
//      We were curing a disease that our own restarts caused.
//   2. The real freeze ("画面在动但没有蓝点/提示/卡片") was the AttributeGraph cycle
//      described above, plus a main-thread `sessionQueue.sync` in the old stop().
//
// The model here is now the minimal, Apple-blessed one (canonical AVCam):
//   • Configure the session ONCE and keep it for the app's lifetime.
//   • startRunning() on foreground, stopRunning() on background.
//   • All session mutations on a dedicated serial queue, always ASYNC — never a
//     synchronous hop from the main thread.
//   • React to exactly one runtime error, mediaServicesWereReset, by
//     re-arming the session. Everything else is left to the system.
// No self-inflicted churn, so nothing hammers mediaserverd.
// ─────────────────────────────────────────────────────────────────────────────
@Observable
final class CameraManager: NSObject {
    var detectedWords: [DetectedWord] = []
    var fingerVisionPoint: CGPoint? = nil  // Vision space, bottom-left origin
    // The point the app actually READS — the fingertip projected forward along the
    // finger's own direction (nail → just past it), i.e. the spot ABOVE the nail
    // where OCR sampling happens. The blue locking ring is drawn HERE, not at the
    // raw fingertip, so what the user sees the ring sit on is exactly the word being
    // recognized.
    var fingerProbePoint: CGPoint? = nil   // Vision space; the read/lock position
    var pointedWord: DetectedWord? = nil
    var hoveringText: String? = nil        // word under finger before confirmed
    var hoveringWord: DetectedWord? = nil  // same, with context — used for AI prefetch
    // 0…1 fill of the fingertip "locking" ring. Grows only while the finger is truly
    // stopped on one spot; snaps to 0 the instant it moves.
    var pointingProgress: Double = 0
    var isScanning: Bool = false           // a target is being confirmed → show bottom hint
    var permissionDenied: Bool = false     // camera access denied/restricted → show settings fallback
    var isPreviewLive: Bool = false        // first frame has arrived → preview is actually showing pixels

    // Live diagnostic readout, mirrored from the frame-flow heartbeat (~1s). Shown
    // as a tiny corner HUD when showDiagnostics is on, so a screenshot of a frozen
    // state is self-diagnosing. Empty until the first heartbeat.
    var diagLine: String = ""

    // A crisp still of the frame at lock time. Displayed over the live preview so
    // the result "freezes". Cleared on rescan.
    var frozenImage: UIImage? = nil
    @ObservationIgnored private var freezeRequested = false   // processing-queue only
    // MAIN-THREAD authority for "a frozen still should currently be showing".
    // freeze()/unfreeze() set this SYNCHRONOUSLY on the main thread; the
    // still-application block in captureOutput (which also hops to main) checks it
    // before assigning frozenImage. This closes a race that left a stuck frozen
    // frame over the live preview: freeze() only REQUESTS a still (rendered a few
    // frames later), while the old unfreeze() cleared frozenImage only if it was
    // already set AND never cancelled a pending request — so a freeze requested
    // just before 重新识别 landed AFTER unfreeze ran, with nothing left to clear it.
    // That looked like "camera won't start" (card gone, scan light back, blurred
    // still on top). With this flag, a still is applied only while it's intended.
    @ObservationIgnored private var freezeIntended = false    // main-thread only

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()

    // Weak ref to the on-screen preview layer, set by CameraPreviewView once it's
    // built. Used ONLY to convert a Vision point → device focus point via Apple's own
    // captureDevicePointConverted(fromLayerPoint:), which bakes in videoGravity +
    // rotation for us — so we never hand-roll the orientation transform. weak: the
    // view owns the layer; we just borrow it while it's alive.
    @ObservationIgnored weak var previewLayer: AVCaptureVideoPreviewLayer?

    // Autofocus-aim throttle (main-thread only). We steer continuous AF at the word
    // the finger points at (refocus(onVisionPoint:)). Refocusing every frame makes AF
    // "pump", so we only re-aim when the target moved meaningfully AND enough time has
    // passed since the last aim. lastFocusPoint is in DEVICE POI space ([0,1]).
    @ObservationIgnored private var lastFocusPoint: CGPoint? = nil
    @ObservationIgnored private var lastFocusAt: Date = .distantPast
    private let focusMoveThreshold: CGFloat = 0.06   // device-space move that warrants a re-aim
    private let focusMinInterval: TimeInterval = 0.8 // min seconds between re-aims (anti-pump)
    // Mirrors CameraView.imageSize: hd1280x720 captured landscape, treated as portrait
    // 720×1280 by VNImageRequestHandler(orientation: .right). Kept in sync with the
    // view's constant so the Vision→layer mapping here matches the green dot exactly.
    @ObservationIgnored private let focusImageSize = CGSize(width: 720, height: 1280)
    // TWO queues, deliberately separate (canonical AVCam design):
    //  • processingQueue — the video-output DELEGATE queue. Every frame's heavy
    //    Vision work (OCR + hand pose) runs here.
    //  • sessionQueue — session LIFECYCLE only (configure / start / stop). Session
    //    control calls block synchronously and can take a while when the system is
    //    under pressure; keeping them off the frame queue (and off main) means they
    //    never wedge frame delivery or the UI.
    // Everything below is INTERNAL machinery — mutated on the processing/session
    // queues and never read by any view. Under @Observable a stored `var` is tracked
    // by default; @ObservationIgnored keeps these OFF the tracked surface (no
    // accidental invalidations, and no cross-thread Observation registrar access
    // from the frame queue). `let` constants never mutate, so they need no annotation.
    @ObservationIgnored private let processingQueue = DispatchQueue(label: "pw.vision", qos: .userInitiated)
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "pw.session")

    // OCR is restricted to this band of the frame (normalized, bottom-left origin):
    // full width × middle 60% height. The user always points near center, so
    // recognizing edge-to-edge just burned frames. CRITICAL: Vision reports each
    // observation's boundingBox RELATIVE TO THIS ROI, not the full frame, so OCR
    // boxes are remapped to full-frame space in extractWords() before being
    // compared with the finger position.
    @ObservationIgnored private let ocrRegionOfInterest = CGRect(x: 0.0, y: 0.2, width: 1.0, height: 0.6)

    @ObservationIgnored private lazy var ocrRequest: VNRecognizeTextRequest = {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate          // 精确模式，读印刷体更准
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["en-US"]      // 只识别英文
        req.minimumTextHeight = 0.01              // 允许更小的字
        req.regionOfInterest = ocrRegionOfInterest
        return req
    }()

    @ObservationIgnored private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 1
        return req
    }()

    // Finger tracking — spatial + temporal, NOT text-anchored. OCR text flickers
    // frame-to-frame, so we anchor confirmation on the fingertip's POSITION: hold
    // roughly the same spot for hoverDuration and we confirm whatever the freshest
    // OCR word at that spot is. Only touched on the main thread.
    //
    // DWELL = an ACCUMULATOR with grace-holds, not a hard clock (the fix for
    // "can't lock in a car / subway"). The old code timed CONTINUOUS stillness: any
    // jitter frame, OCR text flicker, or dropped OCR result reset anchorStart to now
    // and the fill snapped back to 0 — so on a shaking bus the bar climbed and reset
    // forever and never fired. Now:
    //   • progress ACCRUES while the finger stays on roughly one target (position-
    //     based, so OCR text flicker doesn't count as a new target);
    //   • a brief finger/OCR dropout HOLDS progress (a grace window) instead of
    //     resetting — jitter can't knock the bar down, it only pauses it;
    //   • a full reset happens only when the finger genuinely moves to a DIFFERENT
    //     word, or leaves past the grace window.
    // Net: shaky input still fills in about hoverDuration of cumulative good frames.
    @ObservationIgnored private var dwellProgress: Double = 0
    @ObservationIgnored private var dwellLastTick: Date? = nil
    @ObservationIgnored private var dwellAnchor: CGPoint? = nil     // where the dwell is centered
    @ObservationIgnored private var dwellWord: String? = nil       // best-known label at the anchor
    @ObservationIgnored private var candidateLostSince: Date? = nil // OCR briefly lost the word
    @ObservationIgnored private var fingerLostSince: Date? = nil    // hand pose briefly dropped
    private let hoverDuration: TimeInterval = 0.65  // cumulative STILL-frame time before confirming
    private let dwellAnchorTolerance: CGFloat = 0.045 // probe within this of the anchor = same target
    private let candidateLostGrace: TimeInterval = 0.6 // hold the dwell through OCR dropouts
    private let fingerLostGrace: TimeInterval = 0.4    // hold the dwell through hand-pose dropouts
    private let dwellDtClamp: TimeInterval = 0.2       // cap per-frame dt (pauses/backgrounding)
    private let fingerProjection: CGFloat = 0.018   // how far past the nail to sample
    private let fingerReach: CGFloat = 0.045        // fallback: max nail→word-edge gap to count

    // isScanning debounce (main-thread only). Rising edge immediate; falling edge
    // waits scanningOffGrace so a one-frame OCR dropout can't blink the pill out.
    @ObservationIgnored private var scanningOffSince: Date? = nil
    private let scanningOffGrace: TimeInterval = 0.45

    // OCR is heavy — run it every N frames and reuse the last result in between.
    // Hand pose stays every-frame so the finger dot is smooth. Every 3rd frame
    // (~0.3s at our fps) keeps the word list fresh enough that the dot lands on a
    // just-arrived word quickly, without paying OCR's cost on every frame.
    @ObservationIgnored private var frameCounter = 0
    private let heavyWorkInterval = 3
    @ObservationIgnored private var lastWords: [DetectedWord] = []

    // Diagnostic heartbeat (processing-queue only) — a one-line pipeline snapshot
    // every diagLogInterval seconds, mirrored into diagLine for the on-screen HUD.
    @ObservationIgnored private var diagLastLog: Date = .distantPast
    @ObservationIgnored private var diagFrameCount = 0
    private let diagLogInterval: TimeInterval = 1.0

    // Finger entry mute (processing-queue only) — ignore the first fingerEntryMute
    // after a hand appears, so a hand merely sweeping into frame can't instantly
    // start accruing dwell on whatever it passes over first.
    @ObservationIgnored private var fingerFirstSeen: Date? = nil
    private let fingerEntryMute: TimeInterval = 0.12

    // Finger POSITION smoothing + outlier rejection (processing-queue only).
    // Vision's per-frame tip is noisy and occasionally teleports to a mislabeled
    // joint. smoothedFinger is an exponential moving average so the dot glides
    // instead of buzzing; a raw sample that jumps more than fingerJumpReject from
    // the smoothed position is treated as a glitch and DROPPED (the dot holds
    // still), which is what stops the one-frame leap onto the thumb. A few
    // consecutive far samples (genuine fast move) overrides the guard so we don't
    // get stuck — see updateSmoothedFinger.
    @ObservationIgnored private var smoothedFinger: CGPoint? = nil
    @ObservationIgnored private var fingerRejectStreak = 0
    private let fingerSmoothing: CGFloat = 0.5      // 0 = no smoothing, 1 = frozen
    private let fingerJumpReject: CGFloat = 0.12    // normalized dist that counts as a teleport
    private let fingerRejectLimit = 3               // this many far samples = real move, accept

    // STILLNESS GATE (processing-queue only). "毫秒级出结果" is only safe if a fast
    // finger SWEEPING across the page can't fire — the dwell window can then be tiny
    // because settling itself is the intent signal. We measure the smoothed tip's
    // speed (normalized units / sec) between frames: below fingerStillSpeed = "still".
    // updatePointedWord accrues dwell ONLY while still, so a moving finger racks up no
    // progress no matter how short hoverDuration is. lastStillSample/At hold the prior
    // sample for the speed estimate.
    @ObservationIgnored private var lastStillSample: CGPoint? = nil
    @ObservationIgnored private var lastStillAt: Date? = nil
    @ObservationIgnored private var fingerStill = false
    private let fingerStillSpeed: CGFloat = 0.35    // norm units/sec under which the finger counts as parked

    // DIRECTION smoothing (processing-queue only). The probe = fingertip + dir*projection.
    // The tip is EMA-smoothed, but dir was recomputed RAW from the MCP→tip joints every
    // frame, so the projected probe jittered even when the tip was steady. We EMA the
    // direction too (as a vector, then renormalize) so the probe — and thus the dot and
    // the word hit-test — sits still on the pointed word.
    @ObservationIgnored private var smoothedDir: CGVector? = nil
    private let dirSmoothing: CGFloat = 0.6         // 0 = no smoothing, 1 = frozen

    // Most recent frame kept ONLY as a live pixel-buffer reference, encoded to JPEG
    // lazily (once, at lock time) — never on the hot path. Retaining the buffer each
    // heavy frame is near-zero cost; the constant full-res encode the old code did
    // every 0.6s was a real thermal bug that throttled the pipeline.
    @ObservationIgnored private let snapshotLock = NSLock()
    @ObservationIgnored private var latestPixelBuffer: CVPixelBuffer? = nil   // guarded by snapshotLock

    @ObservationIgnored private let ciContext = CIContext()

    // Encode the most recent retained frame to a JPEG on demand — called once when a
    // word locks (main thread), NOT per frame. Full capture resolution capped at
    // 1600px, quality 0.9, so the full-screen detail page stays crisp (~150-300KB).
    func currentSnapshot() -> Data? {
        snapshotLock.lock()
        let pb = latestPixelBuffer
        snapshotLock.unlock()
        guard let pb else { return nil }

        let ci = CIImage(cvPixelBuffer: pb).oriented(.right)
        let extent = ci.extent
        let maxSide = max(extent.width, extent.height)
        guard maxSide > 0 else { return nil }
        let scale = min(1.0, 1600.0 / maxSide)
        let scaled = scale < 1.0 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
    }

    // Freeze the preview: render the next frame full-screen as a still and publish
    // it. The live session keeps running underneath (cheaper than stop/restart and
    // avoids a black flash on resume) — the still just covers it.
    func freeze() {
        // Mark intent on the main thread FIRST, so a racing unfreeze() (also main)
        // can revoke it deterministically. Then ask the frame queue for a still.
        assertMainThenSet(intended: true)
        processingQueue.async { [weak self] in self?.freezeRequested = true }
    }

    // Resume live preview. Revoke the freeze intent (so a still that hasn't been
    // rendered yet is never applied) and drop any still already on screen.
    func unfreeze() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.freezeIntended = false
            if self.frozenImage != nil { self.frozenImage = nil }
        }
    }

    // Set freezeIntended on the main thread. (freeze() may be called from main
    // already; dispatch keeps the ordering with unfreeze() well-defined either way.)
    private func assertMainThenSet(intended: Bool) {
        if Thread.isMainThread {
            freezeIntended = intended
        } else {
            DispatchQueue.main.async { [weak self] in self?.freezeIntended = intended }
        }
    }

    // Whether the app is the foreground app right now (driven by scenePhase). iOS
    // makes the camera UNAVAILABLE in the background, so we never call startRunning()
    // while backgrounded. Atomic because the session queue reads it.
    @ObservationIgnored private let foregroundLock = NSLock()
    @ObservationIgnored private var _isForeground = true
    private func isForeground() -> Bool {
        foregroundLock.lock(); defer { foregroundLock.unlock() }
        return _isForeground
    }
    func setForeground(_ on: Bool) {
        foregroundLock.lock()
        _isForeground = on
        foregroundLock.unlock()
    }

    override init() {
        super.init()
        setupCamera()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Force the scanning latch back to idle. Called at entry points where we are
    // idle by definition, so a value left true from before can't linger.
    func resetScanningState() {
        scanningOffSince = nil
        if isScanning { isScanning = false }
    }

    // Wipe ALL detection outputs — called when a card is dismissed / 重新识别. Without
    // this the next frame re-fires recompute() with the stale pointed word.
    func resetDetection() {
        pointedWord = nil
        hoveringWord = nil
        hoveringText = nil
        dwellProgress = 0
        dwellLastTick = nil
        dwellAnchor = nil
        dwellWord = nil
        candidateLostSince = nil
        fingerLostSince = nil
        pointingProgress = 0
        fingerProbePoint = nil
        resetScanningState()
    }

    // MARK: - Setup

    private func setupCamera() {
        observeSessionHealth()
        // Configure ONCE, off the main thread. The graph is built a single time and
        // kept for the app's lifetime; start/stop just toggle running.
        sessionQueue.async { [weak self] in self?.ensureConfigured() }
    }

    // Idempotent capture-graph configuration. ALWAYS runs on the SESSION queue. Adds
    // whatever's missing — a video input and our video output — and is a pure
    // guard-return once both are present. NO teardown, NO churn on the happy path.
    private func ensureConfigured() {
        let hasInput = session.inputs.contains {
            ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true
        }
        let hasOutput = session.outputs.contains { $0 === videoOutput }
        guard !hasInput || !hasOutput else { return }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // Keep the camera running in a multi-app / Split View layout. Without this,
        // iOS interrupts the session (reason=4) and per Apple's docs it "may only run
        // if your app occupies the full screen" — a common black-preview cause.
        // Guarded because it isn't supported on every device.
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }

        if !hasInput,
           let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            configureFocus(device)
        }

        if !hasOutput {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }

        session.commitConfiguration()
    }

    // Tune focus for the "finger on paper / finger at a billboard" use case. We AIM
    // autofocus explicitly at the word the finger points at (see refocus(onVisionPoint:)),
    // AND restrict the range to .far. Both matter:
    //   • The POI puts the focus on the pointed text specifically.
    //   • .far keeps AF from ever racking all the way to macro. Without it, AF could
    //     grab the very-near fingertip for an instant and then hunt the ENTIRE lens
    //     travel back out to the distant sign — a 6-8s "everything blurs then slowly
    //     re-sharpens" pump the user saw. Both a near book and a far sign are still
    //     comfortably inside .far (it excludes only extreme macro), so nothing we care
    //     about is lost. This is the fix for the auto-recovering blur regression.
    // Continuous AF (a moved page/target re-sharpens) and smooth AF (damps visible
    // pumping) stay. Best-effort — every capability is guarded.
    private func configureFocus(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .far
            }
            // Cap capture to 15fps. Our Vision pipeline only keeps up with ~10fps, so
            // running the sensor at 30 just pays thermal/power cost for frames we
            // discard — and sustained heat is what makes iOS reclaim the source.
            let capFPS = 15.0
            if let range = device.activeFormat.videoSupportedFrameRateRanges.first,
               range.minFrameRate <= capFPS {
                let dur = CMTime(value: 1, timescale: CMTimeScale(capFPS))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            device.unlockForConfiguration()
        } catch {
            // Couldn't lock (device busy mid-transition) — the default AF still works.
        }
    }

    // Observe session health. We deliberately react to almost nothing: iOS owns
    // interruptions and resumes the session on its own. The ONE runtime error worth
    // reacting to is mediaServicesWereReset — the media server genuinely bounced and
    // our session needs re-arming.
    private func observeSessionHealth() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: AVCaptureSession.runtimeErrorNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                       name: AVCaptureSession.wasInterruptedNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: AVCaptureSession.interruptionEndedNotification, object: session)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let code = err?.code ?? 0
        print("🔴 相机会话运行时错误：\(code)")
        // Only the media server reset warrants a re-arm. For everything else — notably
        // the -17281 "capture source" family, which is informational log noise on
        // iOS 26 — do NOTHING. An immediate restart there just re-hammers a server
        // that's already fine, and THAT churn is what wedged the camera before.
        guard code == AVError.Code.mediaServicesWereReset.rawValue else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.isForeground() else { return }
            self.ensureConfigured()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        // Frame delivery pauses during an interruption (backgrounded, another camera
        // client, multi-app, a call). iOS resumes the session itself. We just log —
        // fighting the system here is what thrashed the shared camera server.
        print("🟡 相机会话被系统中断：reason=\(reason) — 等待系统恢复")
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        // The interruption cleared; AVCaptureSession auto-resumes if it was running.
        // No forced restart on top of the system's own resume.
        print("🟢 相机中断结束 — 系统自动恢复帧流")
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
                    self?.probeNetworkPermission()
                } else {
                    self?.setDenied(true)
                }
            }
        default:
            setDenied(true)
        }
    }

    // Trigger the iOS network-permission prompt eagerly, right after camera access is
    // granted, so the user answers it up front instead of on the first word lookup.
    // Fire-and-forget, at most once per launch.
    @ObservationIgnored private var didProbeNetwork = false
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
        guard let url = URL(string: Config.apiURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        // Unauthenticated HEAD — it will bounce (401/405), which is fine: the only
        // goal is to trigger the iOS "wireless data" permission prompt up front so
        // the first real word lookup isn't sacrificed to it.
        Self.probeSession.dataTask(with: req) { _, _, _ in }.resume()
    }

    private func setDenied(_ denied: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.permissionDenied != denied else { return }
            self.permissionDenied = denied
        }
    }

    // Start the session. All work is ASYNC on the session queue — never a
    // synchronous hop from main. Idempotent: reconfigure if needed, then start only
    // if not already running.
    private func startSession() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        setForeground(true)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.ensureConfigured()
            // scenePhase can flip to background between the caller and this block.
            // Starting the camera while backgrounded is the reason=1 / server-thrash
            // trap, so re-check here.
            guard self.isForeground() else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    // Stop the session — called from scenePhase == .background and onDisappear.
    // ASYNC on the session queue (canonical AVCam). The old code did a
    // `sessionQueue.sync` FROM THE MAIN THREAD, which hangs the UI whenever the queue
    // is busy — a freeze cause in its own right. A background-task assertion gives
    // the async stop time to finish even as the app suspends.
    func stop() {
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "pw.camera.stop")
        sessionQueue.async { [weak self] in
            guard let self else {
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                return
            }
            if self.session.isRunning { self.session.stopRunning() }
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        // The next start must wait for a fresh first frame before the preview is
        // considered live again.
        DispatchQueue.main.async { [weak self] in
            self?.isPreviewLive = false
        }
    }

    // Steer continuous autofocus at the WORD the finger points at, so the plane that
    // gets sharp is the text — near (a book) or far (a billboard) — not whatever sits
    // in the frame center. This is what makes the distant-sign case work: AF locks on
    // the far text (the finger goes soft, an accepted depth-of-field trade), and it
    // also self-bootstraps — the aim uses the probe's SCREEN position, so it sharpens
    // that spot even before OCR reads a single word there.
    //
    // Called from the main-thread UI publish with the current Vision probe point.
    // Two-stage convert, both legs TRUSTED:
    //   Vision(norm, bottom-left) → layer point   … same aspect-fill math as the dot
    //   layer point → device POI                  … Apple's captureDevicePointConverted
    // Throttled hard (distance + interval) so AF doesn't pump. Best-effort throughout.
    func refocus(onVisionPoint visionPoint: CGPoint?) {
        guard let visionPoint, let layer = previewLayer else { return }

        // Vision (normalized, bottom-left origin) → point in the preview LAYER's
        // coordinates, using the exact aspect-fill mapping the green dot uses.
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = max(bounds.width / focusImageSize.width, bounds.height / focusImageSize.height)
        let cropX = (focusImageSize.width * scale - bounds.width) / 2
        let cropY = (focusImageSize.height * scale - bounds.height) / 2
        let layerPoint = CGPoint(
            x: visionPoint.x * focusImageSize.width * scale - cropX,
            y: (1 - visionPoint.y) * focusImageSize.height * scale - cropY
        )

        // Layer point → device point of interest ([0,1], top-left in device space).
        // Apple's converter accounts for videoGravity (.resizeAspectFill) and rotation,
        // so we don't hand-roll the orientation transform that was the risky part.
        let poi = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        guard poi.x >= 0, poi.x <= 1, poi.y >= 0, poi.y <= 1 else { return }

        // Anti-pump throttle: skip if the target barely moved and we re-aimed recently.
        let now = Date()
        if let last = lastFocusPoint,
           hypot(poi.x - last.x, poi.y - last.y) < focusMoveThreshold,
           now.timeIntervalSince(lastFocusAt) < focusMinInterval {
            return
        }
        lastFocusPoint = poi
        lastFocusAt = now

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = (self.session.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.video) })?.device else { return }
            guard device.isFocusPointOfInterestSupported else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = poi
                // ONE-SHOT autofocus — NOT continuous. This is the fix for the
                // "background blurs then slowly re-sharpens over 6-8s" hunt. In
                // .continuousAutoFocus, moving focusPointOfInterest restarts a scan,
                // and the device also hunts autonomously on any scene change; a
                // handheld probe drifting past the throttle every ~0.8s therefore kept
                // restarting scans so the lens never settled. A single .autoFocus
                // converges on the pointed word once and HOLDS. The next real re-aim
                // (finger moved past focusMoveThreshold) fires exactly one more scan.
                // Holding also suits a moving car/subway: the page's focus distance is
                // ~constant, so a lock stays sharp instead of hunting on motion blur.
                // Falls back to continuous only where one-shot focus isn't available.
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                // Bias exposure at the same spot so the text is well-lit too — cheap,
                // and it makes distant/backlit signs read better.
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = poi
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {
                // Device busy mid-transition — default continuous AF still works.
            }
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

        // First real frame → the preview is now showing pixels. The idle hint waits
        // on this so its window starts when the page is visible.
        if !isPreviewLive {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isPreviewLive else { return }
                self.isPreviewLive = true
            }
        }

        frameCounter += 1
        let runHeavy = (frameCounter % heavyWorkInterval == 0)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])

        // Hand pose and OCR run as SEPARATE perform() calls — never bundled. The blue
        // dot, scan hint and card ALL ride on captureOutput publishing finger/word
        // results; when the two shared one perform(), a slow OCR pass on a dense page
        // blocked/aborted the whole call and the light hand-pose result never came out
        // either. Now hand pose runs on its own handler first and its result is used no
        // matter what OCR does; OCR is isolated so its failure only skips one refresh.
        var finger: CGPoint? = nil
        var fingerData: (tip: CGPoint, dir: CGVector)? = nil
        do {
            try handler.perform([handPoseRequest])
            fingerData = fingerTip(from: handPoseRequest.results?.first)
            finger = fingerData?.tip
        } catch {
            // No finger this tick — but we DON'T return: the UI publish below still
            // runs so a stale dot clears instead of freezing on screen.
        }
        // Smooth the raw tip and drop teleport glitches (mislabeled joints) BEFORE
        // it drives the dot and the dwell — so the dot glides and never leaps to a
        // thumb for one frame. Direction keeps using the raw tip (it's a local
        // vector, not a screen position, so smoothing it adds nothing).
        finger = updateSmoothedFinger(finger)
        let withinEntryMute = updateEntryMute(finger)
        let still = updateStillness(finger)
        // Smooth the pointing direction too (the tip is already smoothed) so the
        // projected probe doesn't jitter frame-to-frame. Cleared when the finger drops.
        let smoothedDirection = updateSmoothedDir(finger != nil ? fingerData?.dir : nil)

        if runHeavy {
            do {
                let ocrHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
                try ocrHandler.perform([ocrRequest])
                lastWords = extractWords()
            } catch {
                // Keep the previous words; a single missed OCR pass is invisible.
            }
            // Retain THIS frame for a possible snapshot — a cheap reference, no encode.
            snapshotLock.lock()
            latestPixelBuffer = pixelBuffer
            snapshotLock.unlock()
        }
        let words = lastWords

        // Diagnostic heartbeat — throttled to ~1s. If this keeps printing with fps>0,
        // the camera is delivering frames; a blank screen is then a DETECTION gap
        // (words 0) or a UI issue, not a capture stall.
        diagFrameCount += 1
        let dnow = Date()
        if dnow.timeIntervalSince(diagLastLog) >= diagLogInterval {
            let fps = Double(diagFrameCount) / max(0.001, dnow.timeIntervalSince(diagLastLog))
            print(String(format: "📷 帧流 fps=%.0f | words=%d | finger=%@ | running=%@",
                         fps, words.count,
                         finger != nil ? "有" : "无",
                         session.isRunning ? "是" : "否"))
            let running = session.isRunning
            let hasFinger = finger != nil
            let wc = words.count
            DispatchQueue.main.async { [weak self] in
                self?.diagLine = String(format: "fps=%.0f w=%d f=%@ run=%@",
                                        fps, wc, hasFinger ? "Y" : "N", running ? "Y" : "N")
            }
            diagLastLog = dnow
            diagFrameCount = 0
        }

        // A freeze was requested — render this frame full-res, oriented to match the
        // preview, and publish it. Apply it on main ONLY if the freeze is still
        // intended: the user may have tapped 重新识别 (unfreeze) between the request
        // and now, in which case freezeIntended was revoked and we must NOT slap a
        // stale still over the live preview (that was the stuck-frozen-frame bug).
        if freezeRequested {
            freezeRequested = false
            let stillImage = renderFullFrame(from: pixelBuffer)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.freezeIntended else { return }
                self.frozenImage = stillImage
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if runHeavy {
                self.detectedWords = words
            }
            self.fingerVisionPoint = finger
            self.updatePointedWord(finger: finger, dir: smoothedDirection,
                                   words: words, withinEntryMute: withinEntryMute,
                                   still: still)
            self.updateScanningState()
            // Steer AF at what the finger points at (probe = the read spot; fall back
            // to the raw tip on the very first frame before a probe is computed). The
            // method self-throttles, so calling it every publish is cheap.
            self.refocus(onVisionPoint: self.fingerProbePoint ?? finger)
        }
    }

    private func extractWords() -> [DetectedWord] {
        guard let results = ocrRequest.results else { return [] }
        var words: [DetectedWord] = []

        // Vision returns bounding boxes relative to the ROI sub-rect. Map each back
        // into full-frame normalized space so they line up with finger coordinates.
        let roi = ocrRegionOfInterest
        func toFullFrame(_ b: CGRect) -> CGRect {
            CGRect(x: roi.origin.x + b.origin.x * roi.width,
                   y: roi.origin.y + b.origin.y * roi.height,
                   width: b.width * roi.width,
                   height: b.height * roi.height)
        }

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
                    boundingBox: toFullFrame(box.boundingBox),
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

    // Full-resolution still oriented like the preview (.right), for the freeze
    // overlay. Not downscaled — it fills the screen and must stay crisp.
    private func renderFullFrame(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // The index fingertip plus a unit vector along the finger's pointing direction
    // (index MCP knuckle → tip). Direction lets us sample the word just past the NAIL
    // instead of guessing the hand always enters from below.
    //
    // ANTI-MISDETECTION (the fix for "dot jumps to the thumb / a knuckle"):
    // Vision emits a full 21-joint skeleton per hand, and when the pointing finger
    // foreshortens toward the lens, or the hand is cropped at the frame edge, or
    // several fingers bunch up, it MISLABELS joints — handing back a thumb tip or a
    // knuckle tagged as `.indexTip` with a middling confidence. The old code took
    // any point over 0.3, so it followed those bad labels. Now we:
    //   1. Raise the tip confidence gate to 0.5 (the misdetections cluster low).
    //   2. Require the finger to be ANATOMICALLY EXTENDED — tip farther from the
    //      wrist than DIP, than PIP, than MCP (a straight pointing finger is
    //      monotonic outward). A scrambled skeleton or a bent finger fails this and
    //      the whole frame is rejected, so a mislabeled thumb never becomes the dot.
    private func fingerTip(from obs: VNHumanHandPoseObservation?) -> (tip: CGPoint, dir: CGVector)? {
        guard let obs else { return nil }

        // Tip gate is 0.4 (was 0.5). A slightly-soft hand — the common case right
        // after a focus change, and the reason the dot used to need "wave the phone
        // to make it appear" — now clears the bar, so the dot shows sooner. The
        // isExtended() anatomy check below stays the real anti-misdetection filter,
        // so dropping the gate doesn't bring the thumb/knuckle false positives back.
        func point(_ joint: VNHumanHandPoseObservation.JointName, _ minConf: Float = 0.4) -> CGPoint? {
            (try? obs.recognizedPoint(joint)).flatMap { $0.confidence > minConf ? $0.location : nil }
        }

        // Wrist anchors the "is this finger extended?" test. Low gate — the wrist is
        // usually easy to see and we only need a rough origin for the distance chain.
        let wrist = point(.wrist, 0.3)

        // True when tip→DIP→PIP→MCP get progressively closer to the wrist, i.e. the
        // finger is straight and pointing — not a scrambled skeleton or a curled digit.
        func isExtended(_ tip: CGPoint,
                        _ dip: VNHumanHandPoseObservation.JointName,
                        _ pip: VNHumanHandPoseObservation.JointName,
                        _ mcp: VNHumanHandPoseObservation.JointName) -> Bool {
            guard let wrist else { return true }   // no wrist → skip the test, don't over-reject
            func dist(_ j: VNHumanHandPoseObservation.JointName) -> CGFloat? {
                point(j, 0.3).map { hypot($0.x - wrist.x, $0.y - wrist.y) }
            }
            let dTip = hypot(tip.x - wrist.x, tip.y - wrist.y)
            guard let dDip = dist(dip), let dPip = dist(pip), let dMcp = dist(mcp) else {
                return true   // missing a joint → can't disprove; allow it
            }
            return dTip > dDip && dDip > dPip && dPip > dMcp
        }

        if let tip = point(.indexTip),
           isExtended(tip, .indexDIP, .indexPIP, .indexMCP) {
            let base = point(.indexPIP, 0.3) ?? point(.indexMCP, 0.3)
            return (tip, direction(from: base, to: tip))
        }
        if let tip = point(.middleTip),
           isExtended(tip, .middleDIP, .middlePIP, .middleMCP) {
            let base = point(.middlePIP, 0.3) ?? point(.middleMCP, 0.3)
            return (tip, direction(from: base, to: tip))
        }
        return nil
    }

    // Smooths the raw fingertip and rejects teleport glitches. Returns the position
    // the dot should show (nil = no reliable finger this frame). Processing-queue only.
    private func updateSmoothedFinger(_ raw: CGPoint?) -> CGPoint? {
        guard let raw else {
            smoothedFinger = nil
            fingerRejectStreak = 0
            return nil
        }
        guard let prev = smoothedFinger else {
            smoothedFinger = raw          // first sample — adopt as-is
            fingerRejectStreak = 0
            return raw
        }
        let jump = hypot(raw.x - prev.x, raw.y - prev.y)
        if jump > fingerJumpReject {
            // Looks like a teleport (likely a mislabeled joint). Hold the dot still,
            // but if far samples keep coming it's a real fast move — accept then.
            fingerRejectStreak += 1
            if fingerRejectStreak < fingerRejectLimit {
                return prev               // drop the glitch, keep the dot put
            }
            smoothedFinger = raw          // sustained move — snap to the new spot
            fingerRejectStreak = 0
            return raw
        }
        fingerRejectStreak = 0
        // Exponential moving average — glide toward the raw sample.
        let a = fingerSmoothing
        let sm = CGPoint(x: prev.x * a + raw.x * (1 - a),
                         y: prev.y * a + raw.y * (1 - a))
        smoothedFinger = sm
        return sm
    }

    // Update the stillness flag from the smoothed tip's frame-to-frame speed. Returns
    // true when the finger is parked (below fingerStillSpeed). This is the intent gate:
    // dwell only accrues while still, so a short hoverDuration can't fire on a sweep.
    private func updateStillness(_ p: CGPoint?) -> Bool {
        guard let p else {
            lastStillSample = nil
            lastStillAt = nil
            fingerStill = false
            return false
        }
        let now = Date()
        defer { lastStillSample = p; lastStillAt = now }
        guard let prev = lastStillSample, let prevAt = lastStillAt else {
            // First sample — no speed yet. Treat as moving so a hand landing mid-sweep
            // needs one settled frame before it can accrue.
            fingerStill = false
            return false
        }
        let dt = now.timeIntervalSince(prevAt)
        guard dt > 0 else { return fingerStill }
        let speed = hypot(p.x - prev.x, p.y - prev.y) / CGFloat(dt)
        fingerStill = speed < fingerStillSpeed
        return fingerStill
    }

    // EMA the pointing direction and renormalize. nil input (no finger) clears the
    // filter so a new hand starts fresh. Keeps the projected probe from jittering.
    private func updateSmoothedDir(_ raw: CGVector?) -> CGVector? {
        guard let raw else { smoothedDir = nil; return nil }
        guard let prev = smoothedDir else { smoothedDir = raw; return raw }
        let a = dirSmoothing
        var dx = prev.dx * a + raw.dx * (1 - a)
        var dy = prev.dy * a + raw.dy * (1 - a)
        let len = hypot(dx, dy)
        if len > 0.0001 { dx /= len; dy /= len } else { dx = raw.dx; dy = raw.dy }
        let sm = CGVector(dx: dx, dy: dy)
        smoothedDir = sm
        return sm
    }

    // Unit vector base → tip; falls back to "up the page" if the base joint is missing.
    private func direction(from base: CGPoint?, to tip: CGPoint) -> CGVector {
        guard let base else { return CGVector(dx: 0, dy: 1) }
        let dx = tip.x - base.x, dy = tip.y - base.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return CGVector(dx: 0, dy: 1) }
        return CGVector(dx: dx / len, dy: dy / len)
    }

    // Ignore the first fingerEntryMute seconds after a hand APPEARS, so a hand merely
    // sweeping into frame can't instantly start accruing dwell on whatever word it
    // passes over first. Returns true while still inside that mute window (dwell time
    // is not accrued then). Processing-queue only.
    private func updateEntryMute(_ finger: CGPoint?) -> Bool {
        guard finger != nil else {
            fingerFirstSeen = nil
            return false
        }
        let now = Date()
        if fingerFirstSeen == nil { fingerFirstSeen = now }
        guard let seen = fingerFirstSeen else { return false }
        return now.timeIntervalSince(seen) < fingerEntryMute
    }

    // All mutations here run on the main thread.
    //
    // DWELL AS AN ACCUMULATOR (the shaking-scenario fix). Instead of timing
    // CONTINUOUS stillness — where any jitter frame, OCR text flicker, or dropped
    // OCR result reset the clock and the fill snapped to 0 — progress ACCRUES per
    // frame while the finger stays on roughly one target, and a brief finger/OCR
    // dropout only PAUSES it (a grace window) rather than wiping it. A full reset
    // happens only when the finger genuinely moves to a DIFFERENT word or leaves past
    // the grace. Net: on a shaking bus the bar still fills after hoverDuration of
    // cumulative good frames instead of climbing-and-resetting forever.
    private func updatePointedWord(finger: CGPoint?, dir: CGVector?,
                                   words: [DetectedWord], withinEntryMute: Bool,
                                   still: Bool) {
        let now = Date()

        // ── Hand pose dropped this frame ────────────────────────────────────────
        guard let finger else {
            // Hold the dwell through a brief hand-pose dropout: a one/two-frame miss
            // on shaky input shouldn't wipe accrued progress. Beyond the grace, clear.
            if dwellAnchor != nil {
                if fingerLostSince == nil { fingerLostSince = now }
                if now.timeIntervalSince(fingerLostSince ?? now) <= fingerLostGrace {
                    // Keep the dot PINNED at the committed spot through a brief
                    // hand-pose dropout instead of nil-ing it. Nil-ing it made the dot
                    // blink off/on every dropped frame on shaky input — the reported
                    // "反复消失出现". Progress + word are held; accrual is paused.
                    fingerProbePoint = dwellAnchor
                    dwellLastTick = nil      // don't count the paused gap as dwell time
                    return
                }
            }
            clearHover()
            return
        }
        fingerLostSince = nil

        // Sample the spot the NAIL points at: step just past the fingertip along the
        // finger's own direction, so it lands on the pointed word regardless of which
        // side the hand comes from.
        let d = dir ?? CGVector(dx: 0, dy: 1)
        let probe = CGPoint(
            x: min(max(finger.x + d.dx * fingerProjection, 0), 1),
            y: min(max(finger.y + d.dy * fingerProjection, 0), 1)
        )

        // Is the probe still on the current dwell target? POSITION-based, so OCR text
        // flicker at the same physical spot does NOT count as moving to a new target.
        let onAnchor = dwellAnchor.map { hypot(probe.x - $0.x, probe.y - $0.y) < dwellAnchorTolerance } ?? false

        // PIN THE DOT once the finger has committed to a word. While on-anchor the dot
        // is drawn at the fixed anchor, NOT the live probe — the probe micro-jitters
        // every frame (the fingertip is EMA-smoothed but the pointing DIRECTION is
        // recomputed raw each frame), which was the reported "小范围移动". Only a genuine
        // move off the anchor lets the dot follow the probe again.
        fingerProbePoint = onAnchor ? (dwellAnchor ?? probe) : probe

        // Pick the pointed word by PROXIMITY to the probe (= where the green dot is).
        //
        // An earlier "intent" attempt selected the word closest to the pointing RAY, to
        // disambiguate a finger between two words. It backfired: the hand-pose direction
        // carries a lateral tilt, and ray-offset ignores distance ALONG the ray, so a word
        // off to the (upper-)side that merely lined up with the tilt won over the word
        // actually under the dot — the reported "经常识别右边词". Proximity is noisier in
        // theory but matches the dot the user sees, so it's what we use.
        //
        // The probe can still OVERSHOOT into a neighbour on tight lines, so containment
        // alone isn't enough: we also allow the nearest word within reach, then pick the
        // candidate whose box CENTER is closest to the probe.
        var candidates = words.filter { $0.boundingBox.contains(probe) }
        if let nearest = words.min(by: { edgeDistance(probe, to: $0) < edgeDistance(probe, to: $1) }),
           edgeDistance(probe, to: nearest) < fingerReach,
           !candidates.contains(where: { $0.text == nearest.text && $0.boundingBox == nearest.boundingBox }) {
            candidates.append(nearest)
        }
        let candidate = candidates.min(by: {
            centerDistance(probe, to: $0) < centerDistance(probe, to: $1)
        })

        // ── OCR produced no word at the probe this frame ────────────────────────
        guard let candidate else {
            // Still hovering the same physical spot where we HAD a word → hold the
            // dwell through the OCR dropout (grace) instead of resetting to 0.
            if onAnchor, dwellWord != nil {
                if candidateLostSince == nil { candidateLostSince = now }
                if now.timeIntervalSince(candidateLostSince ?? now) <= candidateLostGrace {
                    dwellLastTick = nil      // pause accrual during the dropout
                    return
                }
            }
            clearHover()
            return
        }
        candidateLostSince = nil

        // Same target is POSITION-based: the probe is still within tolerance of the
        // anchor. OCR text flicker at that spot (e.g. "the"↔"thc" between frames) must
        // NOT reset the dwell — resetting on flicker was the reported "反复放大". So we
        // stay in the accrue branch whenever on-anchor, and keep the anchor's ORIGINAL
        // label stable rather than flip-flopping it with every OCR wobble.
        if onAnchor || dwellWord == nil {
            // First commit on this target: plant the anchor here so the dot pins from
            // frame one and progress starts accruing immediately (no throwaway frame).
            if dwellWord == nil {
                dwellWord = candidate.text
                dwellAnchor = probe
                fingerProbePoint = probe
            }
            // Track the freshest candidate for the card/prefetch context, but only when
            // it matches the committed label — a flicker to a different string is
            // ignored so the dot's target stays put.
            if hoveringWord?.text != candidate.text, candidate.text == dwellWord {
                hoveringText = candidate.text
                hoveringWord = candidate
            } else if hoveringWord == nil {
                hoveringText = dwellWord
                hoveringWord = candidate
            }
            // Accrue cumulative STILL-frame time. Two gates:
            //   • entry mute — a hand just sweeping into frame doesn't count yet;
            //   • stillness — progress accrues ONLY while the finger is parked. A finger
            //     still gliding over the page racks up nothing, so hoverDuration can be
            //     tiny (0.3s) without a moving sweep firing. When moving we PAUSE (null
            //     the tick) so the gap isn't later counted as dwell, but we DON'T reset
            //     accrued progress — a momentary jitter above threshold won't knock the
            //     bar down, matching the anti-shake behaviour elsewhere.
            if !withinEntryMute && still {
                let last = dwellLastTick ?? now
                let dt = min(max(now.timeIntervalSince(last), 0), dwellDtClamp)
                dwellProgress = min(1, dwellProgress + dt / hoverDuration)
                dwellLastTick = now
            } else {
                dwellLastTick = nil   // paused: don't count this gap toward dwell
            }
            setPointingProgress(dwellProgress)
            // Confirm with the committed word (hoveringWord), falling back to the
            // current candidate — never a flickered neighbour.
            let locked = hoveringWord ?? candidate
            if dwellProgress >= 1, pointedWord?.text != locked.text {
                pointedWord = locked
            }
        } else {
            // Finger genuinely moved to a DIFFERENT word / spot — restart the dwell.
            dwellAnchor = probe
            dwellWord = candidate.text
            dwellProgress = 0
            dwellLastTick = now
            candidateLostSince = nil
            fingerLostSince = nil
            hoveringText = candidate.text
            hoveringWord = candidate
            pointedWord = nil
            setPointingProgress(0)
        }
    }

    // Only publishes when the value actually changes — the ring animates in the view,
    // so a per-frame identical write would churn SwiftUI needlessly.
    private func setPointingProgress(_ v: Double) {
        if abs(pointingProgress - v) > 0.001 { pointingProgress = v }
    }

    private func clearHover() {
        hoveringText = nil
        hoveringWord = nil
        dwellProgress = 0
        dwellLastTick = nil
        dwellAnchor = nil
        dwellWord = nil
        candidateLostSince = nil
        fingerLostSince = nil
        pointedWord = nil
        fingerProbePoint = nil
        setPointingProgress(0)
    }

    // Distance from a point to a word's box CENTER — the final tie-break among
    // pointing candidates.
    private func centerDistance(_ p: CGPoint, to word: DetectedWord) -> CGFloat {
        let b = word.boundingBox
        return hypot(b.midX - p.x, b.midY - p.y)
    }

    // Distance from a point to the NEAREST EDGE of a word's box (0 if inside).
    private func edgeDistance(_ p: CGPoint, to word: DetectedWord) -> CGFloat {
        let b = word.boundingBox
        let dx = max(b.minX - p.x, 0, p.x - b.maxX)
        let dy = max(b.minY - p.y, 0, p.y - b.maxY)
        return hypot(dx, dy)
    }

    // Scanning = a word is under the finger but not yet held long enough to confirm.
    // Debounced: rising edge immediate, falling edge waits scanningOffGrace.
    private func updateScanningState() {
        let rawScanning = (hoveringText != nil && pointedWord == nil)

        if rawScanning {
            scanningOffSince = nil
            if !isScanning { isScanning = true }
        } else if isScanning {
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
