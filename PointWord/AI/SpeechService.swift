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
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45   // slightly slower than default — clearer for learners
        synthesizer.speak(utterance)
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
