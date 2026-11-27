import SwiftUI
import AVFoundation
import AnrufbeantworterCore

/// Einrichtung des Cloud-Anrufbeantworters: Verbindung, Rufumleitung, Probeanruf.
struct CloudView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var token = ""
    @State private var mobilnummer = ""
    @State private var klingelSekunden = 20
    @State private var meldung: String?
    @State private var fehler: String?
    @State private var arbeitet = false
    @State private var vorschau: String?
    @State private var kopiert: String?

    var body: some View {
        let cloud = model.cloud
        Form {
            Section {
                Text("Statt der Mailbox nimmt ein Cloud-Anrufbeantworter ab. Dein iPhone leitet dafür Anrufe, die du nicht annimmst, an eine eigene Nummer um. Vorteile: Die Ansage wechselt **automatisch** mit Status und Kalender, erkannte Anrufer werden **mit Namen** begrüßt, deine Aussprache-Korrekturen gelten auch dort, und Nachrichten landen hier in der App.")
                    .font(.callout)
            }

            Section {
                TextField("Server, z. B. https://ab.zollsoft.de", text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(cloud.hatZugang ? "Zugangsschlüssel (gespeichert)" : "Zugangsschlüssel", text: $token)
                Button(arbeitet ? "Verbinde …" : "Verbinden") { verbinden() }
                    .disabled(arbeitet || server.isEmpty || (token.isEmpty && !cloud.hatZugang))
                if let ich = cloud.ich {
                    LabeledContent("Angemeldet als", value: ich.name)
                    LabeledContent("Cloud-Nummer", value: ich.cloudNummer.isEmpty ? "noch keine" : ich.cloudNummer)
                    LabeledContent("Stimme", value: ich.stimme.replacingOccurrences(of: "Polly.", with: ""))
                    if !ich.telefonieBereit {
                        Label("Telefonie ist auf dem Server noch nicht fertig eingerichtet.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("1 · Verbindung")
            } footer: {
                Text("Server und Zugangsschlüssel bekommst du von der Verwaltung (Weboberfläche › Profil › App-Zugang). Der Schlüssel wird im iOS-Schlüsselbund gespeichert.")
            }

            if cloud.ich != nil {
                Section {
                    TextField("Meine Handynummer", text: $mobilnummer).keyboardType(.phonePad)
                        .onSubmit(speichereEinstellungen)
                    Stepper("Umleiten nach \(klingelSekunden) Sekunden", value: $klingelSekunden, in: 5...30, step: 5)
                    if let ziel = cloud.ich?.cloudNummer, !ziel.isEmpty {
                        ForEach(Rufumleitung.einrichten(nummer: ziel, sekunden: klingelSekunden)) { c in codeZeile(c) }
                        codeZeile(Rufumleitung.pruefen)
                    } else {
                        Text("Die Verwaltung muss dir zuerst eine Cloud-Nummer zuweisen.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("2 · Rufumleitung einrichten")
                } footer: {
                    Text("Code kopieren, in der Telefon-App auf der Tastatur einfügen und anrufen. iOS erlaubt Apps aus Sicherheitsgründen nicht, solche Codes selbst zu wählen. Umleitungen können je nach Tarif Kosten verursachen.")
                }

                Section {
                    Toggle("Cloud-Anrufbeantworter nutzen", isOn: Binding(
                        get: { model.konfig.cloudAktiv },
                        set: { aktiv in
                            speichereEinstellungen()
                            model.konfig.cloud?.aktiv = aktiv
                            if aktiv { Task { await model.cloud.uebertragen(model.konfig, erzwingen: true) } }
                        }
                    ))
                    if let t = cloud.letzteUebertragung {
                        LabeledContent("Zuletzt übertragen", value: t.formatted(date: .omitted, time: .shortened))
                    }
                    if let f = cloud.syncFehler {
                        Label(f, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                } header: {
                    Text("3 · Aktivieren")
                } footer: {
                    Text("Status, Kalender, Vertretungen, Texte und dein Aussprache-Wörterbuch werden automatisch übertragen.")
                }

                Section {
                    Button("So klingt es gerade (Text)") {
                        aktion { vorschau = try await model.cloud.vorschau(model.konfig).text }
                    }
                    Button("Als bekannter Kunde (Beispiel)") {
                        aktion { vorschau = try await model.cloud.vorschau(model.konfig, alsAnrufer: "+49401234567").text }
                    }
                    if let vorschau { Text(vorschau).font(.callout).foregroundStyle(.secondary) }
                    Button("Probeanruf auf mein Handy") {
                        aktion {
                            try await model.cloud.probeanruf(model.konfig)
                            meldung = "Du wirst gleich angerufen und hörst deine Ansage mit der Cloud-Stimme."
                        }
                    }
                    .disabled(mobilnummer.isEmpty)
                } header: {
                    Text("4 · Testen")
                } footer: {
                    Text("Die Cloud-Stimme ist eine andere als die iPhone-Stimme. Höre schwierige Namen per Probeanruf einmal gegen. Korrekturen in Lautschrift oder IPA wirken in beiden.")
                }

                Section {
                    Button("Verbindung trennen", role: .destructive) {
                        model.cloud.trennen()
                        model.konfig.cloud?.aktiv = false
                        token = ""
                    }
                }
            }
        }
        .navigationTitle("Cloud-Anrufbeantworter")
        .onAppear {
            let c = model.konfig.cloud ?? CloudEinstellung()
            server = c.serverURL
            mobilnummer = c.mobilnummer
            klingelSekunden = c.klingelSekunden
            if model.cloud.hatZugang, !server.isEmpty { Task { await model.cloud.aktualisieren(model.konfig) } }
        }
        .onDisappear(perform: speichereEinstellungen)
        .alert("Hinweis", isPresented: Binding(get: { meldung != nil }, set: { if !$0 { meldung = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(meldung ?? "") }
        .alert("Fehler", isPresented: Binding(get: { fehler != nil }, set: { if !$0 { fehler = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(fehler ?? "") }
    }

    private func codeZeile(_ c: Rufumleitung.Code) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.titel).font(.subheadline)
                Text(c.code).font(.body.monospaced()).textSelection(.enabled)
                Text(c.erklaerung).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = c.code
                kopiert = c.code
            } label: {
                Image(systemName: kopiert == c.code ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }

    private func speichereEinstellungen() {
        var c = model.konfig.cloud ?? CloudEinstellung()
        c.serverURL = server.trimmingCharacters(in: .whitespaces)
        c.mobilnummer = mobilnummer.trimmingCharacters(in: .whitespaces)
        c.klingelSekunden = klingelSekunden
        if model.konfig.cloud != c { model.konfig.cloud = c }
    }

    private func verbinden() {
        speichereEinstellungen()
        aktion {
            let neuerToken = token.isEmpty ? (Schluesselbund.lesen() ?? "") : token
            let ich = try await model.cloud.verbinden(server: server, token: neuerToken)
            token = ""
            if mobilnummer.isEmpty, !ich.mobilnummer.isEmpty { mobilnummer = ich.mobilnummer }
            speichereEinstellungen()
            meldung = "Verbunden als \(ich.name)."
        }
    }

    private func aktion(_ f: @escaping () async throws -> Void) {
        arbeitet = true
        Task {
            defer { arbeitet = false }
            do { try await f() } catch { fehler = error.localizedDescription }
        }
    }
}

/// Nachrichten vom Cloud-Anrufbeantworter.
struct NachrichtenView: View {
    @Environment(AppModel.self) private var model
    @State private var fehler: String?
    @State private var player: AVAudioPlayer?
    @State private var spielt: String?

    var body: some View {
        let liste = model.cloud.nachrichten
        List {
            if liste.isEmpty {
                ContentUnavailableView("Keine Nachrichten", systemImage: "tray", description: Text("Nachrichten vom Cloud-Anrufbeantworter erscheinen hier."))
            }
            ForEach(liste) { n in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(n.anrufer).font(.headline).strikethrough(n.erledigt)
                        if n.prioritaet == "hoch" {
                            Text("wichtig").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.red.opacity(0.15), in: Capsule()).foregroundStyle(.red)
                        }
                        Spacer()
                        if let d = n.datum { Text(d.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let o = n.kontakt?.organisation, !o.isEmpty, o != n.anrufer {
                        Text(o).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !n.transkript.isEmpty {
                        Text("„\(n.transkript)“")
                    } else if n.ohneNachricht == true {
                        Text("Hat keine Nachricht hinterlassen").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        if n.hatAufnahme {
                            Button { abspielen(n) } label: {
                                Label(spielt == n.id ? "Stopp" : "Anhören (\(n.dauerSekunden) s)", systemImage: spielt == n.id ? "stop.fill" : "play.fill")
                            }
                        }
                        if let nr = n.nummer, let url = URL(string: "tel:\(nr)") {
                            Link(destination: url) { Label("Zurückrufen", systemImage: "phone.fill") }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
                .padding(.vertical, 4)
                .swipeActions {
                    Button(n.erledigt ? "Offen" : "Erledigt") {
                        Task {
                            do { try await model.cloud.setzeErledigt(n, !n.erledigt, model.konfig) } catch { fehler = error.localizedDescription }
                        }
                    }
                    .tint(n.erledigt ? .orange : .green)
                }
            }
        }
        .navigationTitle("Nachrichten")
        .refreshable { await laden() }
        .task { await laden() }
        .alert("Fehler", isPresented: Binding(get: { fehler != nil }, set: { if !$0 { fehler = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(fehler ?? "") }
    }

    private func laden() async {
        do { try await model.cloud.ladeNachrichten(model.konfig) } catch { fehler = error.localizedDescription }
    }

    private func abspielen(_ n: CloudNachricht) {
        if spielt == n.id {
            player?.stop()
            spielt = nil
            return
        }
        Task {
            do {
                let daten = try await model.cloud.ladeAufnahme(n, model.konfig)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(data: daten)
                player?.play()
                spielt = n.id
            } catch {
                fehler = error.localizedDescription
            }
        }
    }
}
