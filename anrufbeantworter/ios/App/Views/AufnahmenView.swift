import SwiftUI
import AVFoundation
import AnrufbeantworterCore

struct AufnahmeBaustein: Decodable, Identifiable, Equatable {
    var key: String
    var titel: String
    var text: String
    var gebraucht: Bool
    /// "fehlt" | "vorhanden" | "veraltet"
    var stand: String
    var sekunden: Double?
    var aufgenommenerText: String?
    var id: String { key }
}

struct AufnahmenListe: Decodable {
    var bausteine: [AufnahmeBaustein]
    var referenzSekunden: Double
    var stimmeBereit: Bool
}

/// Mikrofonaufnahme als WAV (16 bit, mono, 44,1 kHz) – so verarbeitet sie der Server direkt.
@MainActor
@Observable
final class Rekorder {
    enum Fehler: LocalizedError {
        case keinMikrofon
        var errorDescription: String? { "Kein Zugriff auf das Mikrofon. Bitte in den iOS-Einstellungen erlauben." }
    }

    private(set) var nimmtAuf = false
    private(set) var dauer: TimeInterval = 0
    private(set) var pegel: Float = 0
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var player: AVAudioPlayer?
    let datei = FileManager.default.temporaryDirectory.appendingPathComponent("baustein.wav")

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw Fehler.keinMikrofon }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try s.setActive(true)
        try? FileManager.default.removeItem(at: datei)
        let r = try AVAudioRecorder(url: datei, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        nimmtAuf = true
        dauer = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.dauer = r.currentTime
                self.pegel = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
            }
        }
    }

    func stopp() -> Data? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        nimmtAuf = false
        pegel = 0
        return try? Data(contentsOf: datei)
    }

    func abspielen(_ daten: Data) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        player = try AVAudioPlayer(data: daten)
        player?.play()
    }
}

/// Liste der Bausteine: Was ist aufgenommen, was fehlt?
struct AufnahmenView: View {
    @Environment(AppModel.self) private var model
    @State private var liste: AufnahmenListe?
    @State private var auswahl: AufnahmeBaustein?
    @State private var fehler: String?
    @State private var testText = "Guten Tag, Frau Dr. Schneider!"
    @State private var rekorder = Rekorder()

    var body: some View {
        List {
            if let l = liste {
                let benoetigt = l.bausteine.filter(\.gebraucht)
                let fertig = benoetigt.filter { $0.stand == "vorhanden" }.count
                Section {
                    Label("\(fertig) von \(benoetigt.count) benötigten Bausteinen aufgenommen",
                          systemImage: fertig == benoetigt.count ? "checkmark.seal.fill" : "mic.badge.plus")
                        .foregroundStyle(fertig == benoetigt.count ? .green : .orange)
                    Text("Deine Ansage besteht aus deinen eigenen Aufnahmen. Nur der Name des Anrufers kommt von der KI – sie lernt deine Stimme aus diesen Aufnahmen (bisher \(Int(l.referenzSekunden)) Sekunden, empfohlen: mindestens 10).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Benötigt") {
                    ForEach(benoetigt) { zeile($0) }
                }
                if l.stimmeBereit {
                    Section {
                        TextField("Testsatz", text: $testText)
                        Button("▶ So klingt die KI in deiner Stimme") {
                            Task {
                                do {
                                    let daten = try await model.cloud.stimmtest(model.konfig, text: testText)
                                    try rekorder.abspielen(daten)
                                } catch { fehler = error.localizedDescription }
                            }
                        }
                    } header: {
                        Text("Stimmtest")
                    } footer: {
                        Text("Klingt der Name nicht wie du? Mehr oder längere Bausteine aufnehmen, dann lernt die KI deine Stimme besser.")
                    }
                }
                Section("Weitere (für andere Status)") {
                    ForEach(l.bausteine.filter { !$0.gebraucht }) { zeile($0) }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Aufnahmen")
        .task { await laden() }
        .refreshable { await laden() }
        .sheet(item: $auswahl, onDismiss: { Task { await laden() } }) { b in
            AufnahmeSheet(baustein: b)
        }
        .alert("Fehler", isPresented: Binding(get: { fehler != nil }, set: { if !$0 { fehler = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(fehler ?? "") }
    }

    private func zeile(_ b: AufnahmeBaustein) -> some View {
        Button { auswahl = b } label: {
            HStack(alignment: .top) {
                Image(systemName: b.stand == "vorhanden" ? "checkmark.circle.fill" : b.stand == "veraltet" ? "exclamationmark.circle.fill" : "mic.circle")
                    .foregroundStyle(b.stand == "vorhanden" ? .green : b.stand == "veraltet" ? .orange : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.titel).foregroundStyle(.primary)
                    Text(b.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if b.stand == "veraltet" { Text("Text geändert – bitte neu aufnehmen").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }

    private func laden() async {
        do { liste = try await model.cloud.aufnahmen(model.konfig) } catch { fehler = error.localizedDescription }
    }
}

/// Aufnahme eines Bausteins: Text zum Ablesen, aufnehmen, anhören, speichern.
struct AufnahmeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let baustein: AufnahmeBaustein
    @State private var rekorder = Rekorder()
    @State private var neu: Data?
    @State private var fehler: String?
    @State private var speichert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(baustein.titel).font(.headline).foregroundStyle(.secondary)
                ScrollView {
                    Text(baustein.text)
                        .font(.title2.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxHeight: 260)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                if rekorder.nimmtAuf {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(rekorder.pegel)).tint(.red)
                        Text(String(format: "%.1f s", rekorder.dauer)).monospacedDigit()
                    }
                }

                Button {
                    if rekorder.nimmtAuf {
                        neu = rekorder.stopp()
                        if let neu { try? rekorder.abspielen(neu) }
                    } else {
                        Task {
                            do { try await rekorder.start() } catch { fehler = error.localizedDescription }
                        }
                    }
                } label: {
                    Image(systemName: rekorder.nimmtAuf ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 72))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel(rekorder.nimmtAuf ? "Aufnahme beenden" : "Aufnahme starten")

                if let neu, !rekorder.nimmtAuf {
                    HStack {
                        Button("▶ Anhören") { try? rekorder.abspielen(neu) }.buttonStyle(.bordered)
                        Button(speichert ? "Speichert …" : "Verwenden") {
                            speichert = true
                            Task {
                                defer { speichert = false }
                                do {
                                    try await model.cloud.aufnahmeHochladen(model.konfig, key: baustein.key, wav: neu)
                                    dismiss()
                                } catch {
                                    fehler = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(speichert)
                    }
                } else if baustein.stand != "fehlt", !rekorder.nimmtAuf {
                    Button("▶ Bisherige Aufnahme anhören") {
                        Task {
                            do {
                                let daten = try await model.cloud.aufnahme(model.konfig, key: baustein.key)
                                try rekorder.abspielen(daten)
                            } catch { fehler = error.localizedDescription }
                        }
                    }
                }
                Spacer()
                Text("Ruhiger Raum, Handy etwa 20–30 cm vor dem Mund, freundlich und in normalem Tempo sprechen. Stille am Anfang und Ende wird automatisch abgeschnitten.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") {
                        _ = rekorder.stopp()
                        dismiss()
                    }
                }
            }
            .alert("Hinweis", isPresented: Binding(get: { fehler != nil }, set: { if !$0 { fehler = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(fehler ?? "") }
        }
    }
}
