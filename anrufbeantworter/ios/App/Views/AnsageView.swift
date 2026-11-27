import SwiftUI
import AnrufbeantworterCore

/// Startseite: aktueller Status, die Ansage zum Lesen und Anhören, Export für die Mailbox.
struct AnsageView: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: Tab
    @State private var exportURL: URL?
    @State private var exportiert = false
    @State private var exportFehler: String?
    @State private var exportLaeuft = false
    @State private var hinweisVorExport = false
    @State private var countdown: Int?

    var body: some View {
        let ansage = model.ansage()
        let hinweise = model.offeneNamensHinweise
        List {
            Section {
                StatusKopf(ansage: ansage)
            }

            if !hinweise.isEmpty {
                Section {
                    Button {
                        model.pruefAuftrag = hinweise.map(\.name)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(hinweise.count == 1 ? "1 Name wurde" : "\(hinweise.count) Namen wurden") noch nicht angehört")
                                    .font(.subheadline.weight(.semibold))
                                Text(hinweise.map(\.name).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "ear.badge.waveform").foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("Empfehlung, kein Muss: Kurz anhören, ob die Stimme die Namen richtig ausspricht.")
                }
            }

            Section("So hören Anrufer dich") {
                ForEach(Array(ansage.abschnitte.enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.teil.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(a.text)
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    model.sprecher.sprichtGerade ? model.sprecher.stopp() : model.ansageAnhoeren()
                } label: {
                    Label(model.sprecher.sprichtGerade ? "Stopp" : "Anhören",
                          systemImage: model.sprecher.sprichtGerade ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if model.konfig.cloudAktiv {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cloud-Anrufbeantworter aktiv").font(.subheadline.weight(.semibold))
                            Text(model.cloud.syncFehler.map { "Übertragung fehlgeschlagen: \($0)" }
                                 ?? model.cloud.letzteUebertragung.map { "Zuletzt übertragen \($0.formatted(date: .omitted, time: .shortened))" }
                                 ?? "Ansage wechselt automatisch mit Status und Kalender")
                                .font(.caption).foregroundStyle(model.cloud.syncFehler == nil ? Color.secondary : Color.red)
                        }
                    } icon: {
                        Image(systemName: "icloud.and.arrow.up").foregroundStyle(.tint)
                    }
                    NavigationLink("Einstellungen & Probeanruf") { CloudView() }
                } footer: {
                    Text("Erkannte Anrufer werden in der Cloud zusätzlich mit Namen begrüßt („Guten Tag, Frau Dr. Schneider!“).")
                }
            }

            Section {
                Button {
                    hinweise.isEmpty ? exportieren() : (hinweisVorExport = true)
                } label: {
                    Label(exportLaeuft ? "Wird erzeugt …" : "Als Audiodatei teilen", systemImage: "square.and.arrow.up")
                }
                .disabled(exportLaeuft)
                Button {
                    starteCountdown()
                } label: {
                    Label(countdown.map { "Startet in \($0) …" } ?? "Zum Aufsprechen abspielen (Countdown)", systemImage: "timer")
                }
                NavigationLink {
                    MailboxAnleitungView()
                } label: {
                    Label("Ansage in die Mailbox bringen", systemImage: "questionmark.circle")
                }
            } header: {
                Text(model.konfig.cloudAktiv ? "Mailbox (Ausweichlösung)" : "Aktivieren")
            } footer: {
                Text(model.konfig.cloudAktiv
                     ? "Nur nötig, falls du zusätzlich die Mailbox deines Netzbetreibers mit derselben Ansage besprechen möchtest."
                     : "iOS erlaubt keiner App, Anrufe selbst anzunehmen. Die Ansage läuft über deine Mailbox oder, empfohlen, über den Cloud-Anrufbeantworter.")
            }
        }
        .navigationTitle("Anrufbeantworter")
        .confirmationDialog("Noch nicht angehörte Namen", isPresented: $hinweisVorExport, titleVisibility: .visible) {
            Button("Erst anhören") { model.pruefAuftrag = hinweise.map(\.name) }
            Button("Trotzdem exportieren") { exportieren() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("\(hinweise.map(\.name).joined(separator: ", ")) könnte falsch ausgesprochen werden.")
        }
        .sheet(isPresented: $exportiert) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .alert("Export fehlgeschlagen", isPresented: Binding(get: { exportFehler != nil }, set: { if !$0 { exportFehler = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportFehler ?? "")
        }
    }

    private func exportieren() {
        exportLaeuft = true
        let ansage = model.ansage()
        let k = model.konfig
        Task {
            defer { exportLaeuft = false }
            do {
                exportURL = try await AudioExport().exportiere(
                    abschnitte: ansage.abschnitte.map(\.text), einstellung: k.stimme, lexikon: k.lexikon,
                    dateiname: "Ansage \(k.profil.name) – \(ansage.status.status.modus.label)")
                exportiert = true
            } catch {
                exportFehler = error.localizedDescription
            }
        }
    }

    /// Für das Aufsprechen über ein zweites Gerät: 5 Sekunden Zeit, um am iPhone "Aufnehmen" zu tippen.
    private func starteCountdown() {
        guard countdown == nil else { return }
        countdown = 5
        Task {
            while let c = countdown, c > 0 {
                try? await Task.sleep(for: .seconds(1))
                countdown = c - 1
            }
            countdown = nil
            model.ansageAnhoeren()
        }
    }
}

struct StatusKopf: View {
    let ansage: Ansage

    var body: some View {
        let s = ansage.status.status
        HStack(spacing: 12) {
            Image(systemName: s.modus.symbol)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(farbe(s.modus).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(farbe(s.modus))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.modus.label).font(.headline)
                Text(untertitel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var untertitel: String {
        let s = ansage.status.status
        let quelle = switch ansage.status.quelle {
        case .manuell: "sofort gesetzt"
        case .kalender: "aus dem Kalender"
        case .standard: "Standardansage"
        }
        guard let bis = s.bis else { return quelle }
        let f = Date.FormatStyle().locale(Locale(identifier: "de_DE"))
        let bisText = s.modus.istGanztaegig ? bis.formatted(f.day().month().year()) : bis.formatted(f.day().month().hour().minute())
        return "\(quelle) · bis \(bisText)"
    }
}

func farbe(_ m: Modus) -> Color {
    switch m {
    case .standard: .green
    case .termin: .orange
    case .abwesend: .blue
    case .urlaub: .pink
    case .krank: .red
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Ehrliche Anleitung, wie die Ansage aktiv wird.
struct MailboxAnleitungView: View {
    var body: some View {
        List {
            Section {
                Text("Apple erlaubt keiner App, Anrufe auf dem iPhone selbst anzunehmen. Angenommen wird immer von deiner **Mailbox** (iPhone-Voicemail bzw. Mailbox des Netzbetreibers). Diese App erzeugt die einheitliche Ansage mit sauberer Aussprache, und du spielst sie einmal in die Mailbox ein.")
            }
            Section("Weg 1: iPhone-Voicemail") {
                Schritt(1, "Ansage hier mit „Als Audiodatei teilen“ per AirDrop an ein zweites Gerät (iPad, Mac, zweites Handy) schicken oder die App dort installieren.")
                Schritt(2, "Am iPhone: Telefon › Voicemail › Begrüßung › Eigene › Aufnehmen.")
                Schritt(3, "Am zweiten Gerät „Zum Aufsprechen abspielen“ tippen, Lautsprecher nah ans iPhone-Mikrofon halten, in ruhiger Umgebung.")
                Schritt(4, "Anhören und sichern.")
            }
            Section {
                Schritt(1, "Mailbox anrufen (häufig: Telekom 3311, Vodafone 5500, o2 333; bitte beim Anbieter prüfen).")
                Schritt(2, "Im Menü „Ansage aufnehmen“ wählen.")
                Schritt(3, "Ansage vom zweiten Gerät abspielen wie oben.")
            } header: {
                Text("Weg 2: Mailbox des Netzbetreibers")
            } footer: {
                Text("Manche Netzbetreiber bieten auch ein Webportal zum Hochladen einer Audiodatei an. Dann einfach die geteilte .m4a-Datei hochladen.")
            }
            Section {
                Text("Wenn sich dein Status ändert (Termin, Urlaub …), erinnert dich die App, die passende Ansage einzuspielen. Tipp: Für wiederkehrende Fälle (Standard, Urlaub mit Vertretung) einmal aufsprechen und beim Netzbetreiber als zweite Ansage speichern, falls er das anbietet.")
            } header: {
                Text("Wechsel der Ansage")
            }
            Section {
                Text("Statt der Mailbox nimmt der Cloud-Anrufbeantworter ab: Das iPhone leitet per Rufumleitung (`**61*…#`) dorthin um. Die Ansage wechselt dann automatisch mit Status und Kalender, und erkannte Anrufer werden mit Namen begrüßt. Die Firmen-Telefonanlage bleibt außen vor.")
                NavigationLink("Cloud-Anrufbeantworter einrichten") { CloudView() }
            } header: {
                Text("Empfohlen: Cloud-Anrufbeantworter")
            }
        }
        .navigationTitle("Ansage aktivieren")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Schritt: View {
    let nr: Int
    let text: LocalizedStringKey
    init(_ nr: Int, _ text: LocalizedStringKey) {
        self.nr = nr
        self.text = text
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(nr)").font(.caption.bold()).frame(width: 22, height: 22).background(Circle().fill(.tint.opacity(0.15)))
            Text(text)
        }
    }
}
