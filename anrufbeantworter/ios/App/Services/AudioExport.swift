import AVFoundation
import AnrufbeantworterCore

/// Rendert die Ansage mit derselben Stimme in eine Audiodatei (AAC/.m4a),
/// z. B. um sie in die Mailbox aufzusprechen oder an Kollegen zu schicken.
final class AudioExport {
    enum Fehler: LocalizedError {
        case keinAudio
        var errorDescription: String? { "Die Stimme hat kein Audio geliefert. Bitte eine andere Stimme wählen." }
    }

    private let synth = AVSpeechSynthesizer()

    /// Schreibt die Abschnitte nacheinander mit Pausen in eine Datei und gibt deren URL zurück.
    func exportiere(abschnitte: [String], einstellung: StimmenEinstellung, lexikon: [AusspracheEintrag], dateiname: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(dateiname).appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: url)
        let ziel = Ziel(url: url)
        let utterances = Sprecher.utterances(abschnitte, einstellung: einstellung, lexikon: lexikon)
        for (i, u) in utterances.enumerated() {
            try await schreibe(u, in: ziel)
            if i < utterances.count - 1 { try ziel.stille(Double(einstellung.pauseMs) / 1000) }
        }
        guard ziel.datei != nil else { throw Fehler.keinAudio }
        try ziel.stille(0.4)
        ziel.datei = nil // schließt die Datei
        return url
    }

    private func schreibe(_ u: AVSpeechUtterance, in ziel: Ziel) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var fertig = false
            synth.write(u) { buffer in
                guard !fertig else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    fertig = true
                    cont.resume()
                    return
                }
                do {
                    try ziel.schreibe(pcm)
                } catch {
                    fertig = true
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private final class Ziel {
        let url: URL
        var datei: AVAudioFile?

        init(url: URL) { self.url = url }

        func schreibe(_ pcm: AVAudioPCMBuffer) throws {
            if datei == nil {
                let f = pcm.format
                datei = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: f.sampleRate,
                        AVNumberOfChannelsKey: f.channelCount,
                        AVEncoderBitRateKey: 64_000,
                    ],
                    commonFormat: f.commonFormat,
                    interleaved: f.isInterleaved
                )
                try stille(0.3) // kurzer ruhiger Einstieg
            }
            try datei?.write(from: pcm)
        }

        func stille(_ sekunden: Double) throws {
            guard let datei else { return }
            let format = datei.processingFormat
            let frames = AVAudioFrameCount(sekunden * format.sampleRate)
            guard frames > 0, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            b.frameLength = frames
            for buf in UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList) {
                if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) }
            }
            try datei.write(from: b)
        }
    }
}
