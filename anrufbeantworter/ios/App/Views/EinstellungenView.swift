import SwiftUI
import AVFoundation
import AnrufbeantworterCore

struct EinstellungenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Ich") {
                NavigationLink { ProfilView() } label: {
                    LabeledContent("Profil", value: model.konfig.profil.name)
                }
                NavigationLink { VertretungenView() } label: {
                    LabeledContent("Vertretungen", value: "\(model.konfig.vertretungen.count)")
                }
            }
            Section {
                NavigationLink { StimmeView() } label: {
                    LabeledContent("Stimme", value: Sprecher.stimme(model.konfig.stimme.stimmeID)?.name ?? "–")
                }
                NavigationLink { TexteView() } label: {
                    LabeledContent("Ansagetexte", value: model.konfig.texte.abweichungenVomStandard == 0 ? "Firmenstandard" : "\(model.konfig.texte.abweichungenVomStandard) angepasst")
                }
            } header: {
                Text("Klang")
            } footer: {
                Text("Für einen einheitlichen Auftritt sind Texte und Sprechweise auf den zollsoft-Standard voreingestellt.")
            }
            Section {
                Toggle("Bei neuen Namen nach Aussprache fragen", isOn: $model.konfig.nachAusspracheFragen)
            } footer: {
                Text("Fragt nach, wenn ein neuer Name in die Ansage kommt. Du kannst die Frage jederzeit überspringen.")
            }
            Section {
                NavigationLink { CloudView() } label: {
                    LabeledContent("Cloud-Anrufbeantworter", value: model.konfig.cloudAktiv ? "aktiv" : "aus")
                }
                NavigationLink("Ansage in die Mailbox bringen") { MailboxAnleitungView() }
            } header: {
                Text("Wie die Ansage zum Anrufer kommt")
            }
        }
        .navigationTitle("Einstellungen")
    }
}

struct ProfilView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Person") {
                TextField("Vorname", text: $model.konfig.profil.vorname)
                TextField("Nachname", text: $model.konfig.profil.nachname)
                TextField("Funktion (wird angesagt)", text: $model.konfig.profil.funktion)
            }
            Section {
                TextField("Firma", text: $model.konfig.profil.firma)
                TextField("Produkt", text: $model.konfig.profil.produkt)
            } header: {
                Text("Unternehmen")
            } footer: {
                Text("„… bei zollsoft, Ihrem Team für tomedo.“")
            }
        }
        .navigationTitle("Profil")
        .onDisappear { model.pruefeNeueNamen() }
    }
}

struct VertretungenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach($model.konfig.vertretungen) { $v in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $v.name)
                        TextField("Telefon", text: $v.telefon).keyboardType(.phonePad).foregroundStyle(.secondary)
                    }
                }
                .onDelete { model.konfig.vertretungen.remove(atOffsets: $0) }
                Button {
                    model.konfig.vertretungen.append(Vertretung(name: "", telefon: ""))
                } label: {
                    Label("Vertretung hinzufügen", systemImage: "plus")
                }
            }
            Section {
                Picker("Standard-Vertretung", selection: $model.konfig.standardVertretungID) {
                    Text("Keine").tag(UUID?.none)
                    ForEach(model.konfig.vertretungen) { Text($0.name.isEmpty ? "(ohne Namen)" : $0.name).tag(Optional($0.id)) }
                }
                ForEach([Modus.termin, .abwesend, .urlaub, .krank]) { m in
                    Toggle("Bei „\(m.label)“ nennen", isOn: Binding(
                        get: { model.konfig.vertretungNennenIn.contains(m) },
                        set: { if $0 { model.konfig.vertretungNennenIn.insert(m) } else { model.konfig.vertretungNennenIn.remove(m) } }
                    ))
                }
            } footer: {
                Text("Die Telefonnummer wird Ziffer für Ziffer langsam angesagt.")
            }
        }
        .navigationTitle("Vertretungen")
        .onDisappear {
            model.konfig.vertretungen.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            model.pruefeNeueNamen()
        }
    }
}

struct StimmeView: View {
    @Environment(AppModel.self) private var model
    @State private var stimmen: [AVSpeechSynthesisVoice] = Sprecher.deutscheStimmen()
    @State private var personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

    var body: some View {
        @Bindable var model = model
        let aktiv = Sprecher.stimme(model.konfig.stimme.stimmeID)
        Form {
            Section {
                Button {
                    model.sprich("Guten Tag! Sie sind verbunden mit dem Anschluss von \(model.konfig.profil.name) bei \(model.konfig.profil.firma), Ihrem Team für \(model.konfig.profil.produkt).")
                } label: {
                    Label("Probe anhören", systemImage: "play.fill")
                }
            }
            Section {
                ForEach(stimmen, id: \.identifier) { v in
                    Button {
                        model.konfig.stimme.stimmeID = v.identifier
                        model.sprich("Guten Tag, hier ist \(v.name).")
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(v.name).foregroundStyle(.primary)
                                Text("\(Sprecher.qualitaetsLabel(v)) · \(v.language)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if v.identifier == aktiv?.identifier { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            } header: {
                Text("Deutsche Stimmen")
            } footer: {
                Text("Angenehmer klingen die Stimmen in **Premium**- oder **Erweitert**-Qualität. Laden: iOS-Einstellungen › Bedienungshilfen › Gesprochene Inhalte › Stimmen › Deutsch. Danach hier zurückkehren.")
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Tempo")
                    Slider(value: $model.konfig.stimme.tempo, in: 0.35...0.6) { Text("Tempo") } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                }
                VStack(alignment: .leading) {
                    Text("Tonhöhe")
                    Slider(value: $model.konfig.stimme.tonhoehe, in: 0.8...1.2)
                }
                Stepper("Pause zwischen Sätzen: \(model.konfig.stimme.pauseMs) ms", value: $model.konfig.stimme.pauseMs, in: 0...1500, step: 50)
                Button("Firmenstandard wiederherstellen") {
                    let id = model.konfig.stimme.stimmeID
                    model.konfig.stimme = .firmenStandard
                    model.konfig.stimme.stimmeID = id
                }
                .disabled(model.konfig.stimme.tempo == StimmenEinstellung.firmenStandard.tempo
                          && model.konfig.stimme.tonhoehe == StimmenEinstellung.firmenStandard.tonhoehe
                          && model.konfig.stimme.pauseMs == StimmenEinstellung.firmenStandard.pauseMs)
            } header: {
                Text("Sprechweise")
            }
            Section {
                if personalVoiceStatus == .authorized {
                    Text("Freigegeben. Deine eigene Stimme erscheint oben in der Liste (falls in Deutsch angelegt).")
                } else {
                    Button("Eigene Stimme verwenden (Personal Voice)") {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                            Task { @MainActor in
                                personalVoiceStatus = status
                                stimmen = Sprecher.deutscheStimmen()
                            }
                        }
                    }
                }
            } header: {
                Text("Eigene Stimme")
            } footer: {
                Text("Mit iOS „Personal Voice“ kann die Ansage in deiner eigenen Stimme gesprochen werden. Einrichten unter Einstellungen › Bedienungshilfen › Personal Voice. Für einen einheitlichen Auftritt empfehlen wir die Firmenstimme.")
            }
        }
        .navigationTitle("Stimme")
        .onAppear { stimmen = Sprecher.deutscheStimmen() }
    }
}

struct TexteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Platzhalter: " + AnsageTexte.platzhalter.map { "{{\($0)}}" }.joined(separator: " "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            } footer: {
                Text("{{#bis}}…{{/bis}} erscheint nur, wenn ein Ende angegeben ist.")
            }
            ForEach(AnsageTexte.felder.indices, id: \.self) { i in
                let feld = AnsageTexte.felder[i]
                let abweichend = model.konfig.texte[keyPath: feld.keyPath] != AnsageTexte.firmenStandard[keyPath: feld.keyPath]
                Section {
                    TextEditor(text: Binding(
                        get: { model.konfig.texte[keyPath: feld.keyPath] },
                        set: { model.konfig.texte[keyPath: feld.keyPath] = $0 }
                    ))
                    .frame(minHeight: 70)
                    if abweichend {
                        Button("Firmenstandard wiederherstellen") {
                            model.konfig.texte[keyPath: feld.keyPath] = AnsageTexte.firmenStandard[keyPath: feld.keyPath]
                        }
                        .font(.callout)
                    }
                } header: {
                    HStack {
                        Text(feld.titel)
                        if abweichend { Text("· angepasst").foregroundStyle(.orange) }
                    }
                }
            }
        }
        .navigationTitle("Ansagetexte")
    }
}
