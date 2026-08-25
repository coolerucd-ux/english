import AVFoundation
import Combine

// Speaks the looked-up English word aloud (the 🔊 button on the card).
// Uses the system US-English voice — no network, instant.
//
// Publishes `speakingText` so the card's 🔊 icon can pulse its sound-wave
// bars while the word is playing, then settle back when it finishes.
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()
    private let synthesizer = AVSpeechSynthesizer()

    // The word currently being spoken (nil when idle). Drives the icon animation.
    @Published private(set) var speakingText: String? = nil

    // Best available US-English voice, resolved once. iOS ships several quality
    // tiers (.default → .enhanced → .premium) but never picks the good ones
    // automatically — asking only for "en-US" gets the robotic compact voice.
    // We hunt for the highest-quality en-US voice the device actually has, so
    // the word sounds natural wherever the user has downloaded better voices.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = Self.bestUSVoice()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The camera capture session leaves the shared audio session in a state
        // that can silence TTS, and the default category is muted by the ring
        // switch. Switch to .playback so the word plays reliably on every tap —
        // even when the phone is on silent, which is what a 🔊 button implies.
        activatePlaybackSession()

        // Interrupt any ongoing utterance so rapid taps feel responsive.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        // Fall back to a plain en-US voice if no better one was resolved.
        utterance.voice = preferredVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.42          // a touch slower — clearer for learners
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.0
        synthesizer.speak(utterance)
    }

    // Picks the most natural US-English voice available on this device:
    //   1. Highest quality tier first (.premium > .enhanced > .default).
    //   2. Among equal tiers, prefer a known-pleasant voice (Ava/Samantha/Allison).
    // Enhanced/premium voices aren't bundled — the user downloads them in
    // Settings › Accessibility › Spoken Content › Voices. If none are present we
    // still return the best default, which is no worse than before.
    private static func bestUSVoice() -> AVSpeechSynthesisVoice? {
        let usVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }
        guard !usVoices.isEmpty else { return nil }

        // Names Apple ships that sound noticeably more human, best first.
        let preferredNames = ["Ava", "Samantha", "Allison", "Nathan", "Evan"]

        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            // Quality dominates; a matching pleasant name is the tiebreaker.
            let qualityScore: Int
            switch v.quality {
            case .premium:  qualityScore = 300
            case .enhanced: qualityScore = 200
            default:        qualityScore = 100
            }
            let nameBonus = preferredNames.firstIndex(where: { v.name.contains($0) })
                .map { 50 - $0 } ?? 0
            return qualityScore + nameBonus
        }

        return usVoices.max(by: { rank($0) < rank($1) })
    }


    private func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .duckOthers lowers any background audio instead of cutting it.
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Non-fatal: if the session can't be set we still attempt to speak.
            print("SpeechService: audio session setup failed — \(error)")
        }
    }
}

// Delegate callbacks may arrive off the main thread — hop back before touching
// @Published state.
extension SpeechService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakingText = utterance.speechString }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakingText = nil }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakingText = nil }
    }
}
