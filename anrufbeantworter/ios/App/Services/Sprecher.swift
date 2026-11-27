import AVFoundation
import AnrufbeantworterCore

/// Sprachausgabe auf dem Gerät mit iOS-Stimmen (keine Cloud, keine Kosten, datenschutzfreundlich).
/// Wendet das Aussprache-Wörterbuch an: IPA über `AVSpeechSynthesisIPANotationAttribute`, sonst Lautschrift.
@MainActor
@Observable
final class Sprecher {
    private(set) var sprichtGerade = false

    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let beobachter = SynthBeobachter()

    init() {
        synth.delegate = beobachter
        beobachter.beiAenderung = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sprichtGerade = self.synth.isSpeaking
            }
        }
    }

    // MARK: Stimmen

    /// Deutsche Stimmen, beste Qualität zuerst (Premium > Erweitert > Standard). Spaßstimmen werden ausgeblendet.
    nonisolated static func deutscheStimmen() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
            }
    }

    nonisolated static func stimme(_ id: String?) -> AVSpeechSynthesisVoice? {
        if let id, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return deutscheStimmen().first ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    nonisolated static func qualitaetsLabel(_ v: AVSpeechSynthesisVoice) -> String {
        if v.voiceTraits.contains(.isPersonalVoice) { return "Eigene Stimme" }
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Erweitert"
        default: return "Standard"
        }
    }

    // MARK: Sprechen

    func sprich(_ text: String, einstellung: StimmenEinstellung, lexikon: [AusspracheEintrag]) {
        sprich(abschnitte: [text], einstellung: einstellung, lexikon: lexikon)
    }

    func sprich(abschnitte: [String], einstellung: StimmenEinstellung, lexikon: [AusspracheEintrag]) {
        stopp()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        for u in Self.utterances(abschnitte, einstellung: einstellung, lexikon: lexikon) {
            synth.speak(u)
        }
    }

    func stopp() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Eine Äußerung pro Abschnitt, damit zwischen den Abschnitten eine ruhige Pause entsteht.
    nonisolated static func utterances(_ abschnitte: [String], einstellung: StimmenEinstellung, lexikon: [AusspracheEintrag]) -> [AVSpeechUtterance] {
        let voice = stimme(einstellung.stimmeID)
        return abschnitte.enumerated().map { i, text in
            let u = AVSpeechUtterance(attributedString: attributiert(text, lexikon: lexikon))
            u.voice = voice
            u.rate = einstellung.tempo
            u.pitchMultiplier = einstellung.tonhoehe
            u.postUtteranceDelay = i < abschnitte.count - 1 ? Double(einstellung.pauseMs) / 1000 : 0
            return u
        }
    }

    nonisolated static func attributiert(_ text: String, lexikon: [AusspracheEintrag]) -> NSAttributedString {
        let ipaKey = NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute)
        let out = NSMutableAttributedString()
        for teil in Aussprache.zerlege(text, lexikon: lexikon) {
            switch teil {
            case .text(let t):
                out.append(NSAttributedString(string: t))
            case .korrigiert(let original, _, let ipa?):
                out.append(NSAttributedString(string: original, attributes: [ipaKey: ipa]))
            case .korrigiert(_, let laut?, nil):
                out.append(NSAttributedString(string: laut))
            case .korrigiert(let original, nil, nil):
                out.append(NSAttributedString(string: original))
            }
        }
        return out
    }
}

private final class SynthBeobachter: NSObject, AVSpeechSynthesizerDelegate {
    var beiAenderung: (() -> Void)?
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { beiAenderung?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { beiAenderung?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { beiAenderung?() }
}
