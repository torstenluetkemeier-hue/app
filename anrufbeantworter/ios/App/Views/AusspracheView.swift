import SwiftUI
import AnrufbeantworterCore

/// Übersicht: Welche Namen kommen in der Ansage vor, welche sind angehört, welche korrigiert?
struct AusspracheView: View {
    @Environment(AppModel.self) private var model
    @State private var neuerTestname = ""

    var body: some View {
        let kandidaten = NamensPruefung.kandidaten(model.konfig, stimmeID: model.aktiveStimmeID)
        let offen = kandidaten.filter { $0.status == .ungeprueft || $0.status == .stimmeGeaendert }
        List {
            Section {
                Button {
                    model.pruefAuftrag = (offen.isEmpty ? kandidaten : offen)
                        .sorted { $0.risiko.stufe > $1.risiko.stufe }
                        .map(\.name)
                } label: {
                    Label(offen.isEmpty ? "Alle Namen noch einmal anhören" : "\(offen.count) ungeprüfte Namen nacheinander anhören",
                          systemImage: "ear")
                }
                .disabled(kandidaten.isEmpty)
            } footer: {
                Text("Jeder Name wird im Satz vorgesprochen. Du entscheidest per Gehör: passt, oder korrigieren. Korrekturen sind freiwillig.")
            }

            Section("Namen in deiner Ansage") {
                ForEach(kandidaten.filter { $0.herkunft != "Testname" }) { k in
                    NavigationLink { NamensDetailView(name: k.name, kontextSatz: k.kontextSatz) } label: { KandidatZeile(kandidat: k) }
                }
            }

            Section {
                ForEach(kandidaten.filter { $0.herkunft == "Testname" }) { k in
                    NavigationLink { NamensDetailView(name: k.name, kontextSatz: k.kontextSatz) } label: { KandidatZeile(kandidat: k) }
                }
                .onDelete { idx in
                    let namen = kandidaten.filter { $0.herkunft == "Testname" }
                    let weg = Set(idx.map { namen[$0].name })
                    model.konfig.testnamen.removeAll { weg.contains($0) }
                }
                HStack {
                    TextField("Name hinzufügen", text: $neuerTestname)
                        .onSubmit(testnameHinzufuegen)
                    Button("Hinzufügen", action: testnameHinzufuegen)
                        .disabled(neuerTestname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Menu {
                    Button("Schwierige Beispielnamen laden") {
                        for n in NamensPruefung.beispielNamen where !model.konfig.testnamen.contains(n) {
                            model.konfig.testnamen.append(n)
                        }
                    }
                } label: {
                    Label("Stimme mit schwierigen Namen testen", systemImage: "testtube.2")
                }
            } header: {
                Text("Weitere Namen testen")
            } footer: {
                Text("Z. B. wichtige Kunden oder Kollegen. Die Beispielnamen zeigen schnell, wie gut eine Stimme mit polnischen, türkischen, vietnamesischen oder französischen Namen umgeht.")
            }

            Section {
                if model.konfig.lexikon.isEmpty {
                    Text("Noch keine Einträge").foregroundStyle(.secondary)
                }
                ForEach(model.konfig.lexikon.sorted { $0.schreibweise.localizedCompare($1.schreibweise) == .orderedAscending }) { e in
                    NavigationLink { NamensDetailView(name: e.schreibweise, kontextSatz: "Guten Tag, ich verbinde Sie mit \(e.schreibweise).") } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.schreibweise)
                            if e.hatKorrektur {
                                Text("gesprochen: " + (e.ipa.isEmpty ? e.lautschrift : "/\(e.ipa)/")).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("angehört, passt").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    let sortiert = model.konfig.lexikon.sorted { $0.schreibweise.localizedCompare($1.schreibweise) == .orderedAscending }
                    let ids = Set(idx.map { sortiert[$0].id })
                    model.konfig.lexikon.removeAll { ids.contains($0.id) }
                }
            } header: {
                Text("Aussprache-Wörterbuch")
            } footer: {
                Text("Gilt überall in der Ansage, ganzwortig und unabhängig von Groß-/Kleinschreibung.")
            }
        }
        .navigationTitle("Aussprache")
    }

    private func testnameHinzufuegen() {
        let n = neuerTestname.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !model.konfig.testnamen.contains(n) else { return }
        model.konfig.testnamen.append(n)
        neuerTestname = ""
    }
}

struct KandidatZeile: View {
    let kandidat: NamensKandidat

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(kandidat.name)
                Text("\(kandidat.herkunft) · \(statusText)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if kandidat.status != .ok && kandidat.status != .korrigiert && kandidat.risiko.stufe > .gering {
                RisikoBadge(stufe: kandidat.risiko.stufe)
            }
        }
    }

    private var statusText: String {
        switch kandidat.status {
        case .ungeprueft: "noch nicht angehört"
        case .ok: "angehört, passt"
        case .korrigiert: "korrigiert"
        case .stimmeGeaendert: "mit anderer Stimme geprüft"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch kandidat.status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .korrigiert: Image(systemName: "pencil.circle.fill").foregroundStyle(.blue)
        case .stimmeGeaendert: Image(systemName: "arrow.triangle.2.circlepath.circle").foregroundStyle(.orange)
        case .ungeprueft: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

struct RisikoBadge: View {
    let stufe: AusspracheRisiko.Stufe
    var body: some View {
        Text(stufe == .hoch ? "schwierig" : "prüfen")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((stufe == .hoch ? Color.orange : Color.yellow).opacity(0.2), in: Capsule())
            .foregroundStyle(stufe == .hoch ? .orange : .primary)
    }
}

struct NamensDetailView: View {
    let name: String
    let kontextSatz: String

    var body: some View {
        ScrollView {
            NamensPruefKarte(name: name, kontextSatz: kontextSatz, weiter: nil)
                .padding()
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Prüfablauf: Namen nacheinander anhören. Jeder Schritt kann übersprungen werden.
struct PruefAblaufView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let namen: [String]
    @State private var index = 0

    var body: some View {
        NavigationStack {
            Group {
                if index < namen.count {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ProgressView(value: Double(index), total: Double(namen.count))
                            Text("Name \(index + 1) von \(namen.count)").font(.caption).foregroundStyle(.secondary)
                            NamensPruefKarte(name: namen[index], kontextSatz: kontext(namen[index])) {
                                index += 1
                            }
                            .id(namen[index])
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("Fertig", systemImage: "checkmark.seal",
                                           description: Text("Alle Namen sind durchgesehen. Du kannst sie jederzeit unter „Aussprache“ erneut anhören."))
                }
            }
            .navigationTitle("Aussprache prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(index < namen.count ? "Später" : "Fertig") {
                        model.sprecher.stopp()
                        dismiss()
                    }
                }
            }
        }
    }

    private func kontext(_ name: String) -> String {
        NamensPruefung.kandidaten(model.konfig, stimmeID: nil).first { $0.name == name }?.kontextSatz
            ?? "Guten Tag, ich verbinde Sie mit \(name)."
    }
}

/// Kern der Aussprache-Prüfung: anhören → passt / korrigieren (Vorschläge, eigene Lautschrift, optional IPA).
struct NamensPruefKarte: View {
    @Environment(AppModel.self) private var model
    let name: String
    let kontextSatz: String
    /// Im Prüfablauf: zum nächsten Namen; in der Einzelansicht nil
    let weiter: (() -> Void)?

    @State private var korrigieren = false
    @State private var lautschrift = ""
    @State private var ipa = ""
    @State private var gespeichert = false

    private static let ipaZeichen = ["ˈ", "ː", "ʃ", "ʒ", "t͡ʃ", "d͡ʒ", "ç", "x", "ŋ", "ə", "ɐ", "ɛ", "ɪ", "ɔ", "ʊ", "ø", "œ", "y", "ʏ", "ɲ", "ɕ", "ʑ"]

    var body: some View {
        let eintrag = Aussprache.eintrag(fuer: name, in: model.konfig.lexikon)
        let risiko = AusspracheRisiko.bewerte(name)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.title2.bold())
                if risiko.stufe > .gering {
                    HStack { RisikoBadge(stufe: risiko.stufe); Text(risiko.stufe.label).font(.caption).foregroundStyle(.secondary) }
                    ForEach(risiko.gruende, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                }
                if let e = eintrag, e.hatKorrektur {
                    Label("Gespeichert: " + (e.ipa.isEmpty ? e.lautschrift : "/\(e.ipa)/"), systemImage: "pencil.circle")
                        .font(.callout).foregroundStyle(.blue)
                }
            }

            HStack {
                Button { model.sprich(kontextSatz) } label: { Label("Im Satz", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button { model.sprich(name) } label: { Label("Nur Name", systemImage: "play") }
                    .buttonStyle(.bordered)
                if eintrag?.hatKorrektur == true {
                    Button { model.sprich(name, probe: AusspracheEintrag(schreibweise: name, pruefung: .ok)) } label: {
                        Label("Ohne Korrektur", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !korrigieren {
                VStack(spacing: 10) {
                    Button {
                        if eintrag?.hatKorrektur != true { model.markiereRichtig(name) } else { model.speichereKorrektur(name, lautschrift: eintrag!.lautschrift, ipa: eintrag!.ipa) }
                        weiterOderBestaetigen()
                    } label: {
                        Label("Klingt richtig", systemImage: "hand.thumbsup.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    Button {
                        lautschrift = eintrag?.lautschrift ?? ""
                        ipa = eintrag?.ipa ?? ""
                        korrigieren = true
                    } label: {
                        Label("Klingt falsch – korrigieren", systemImage: "pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if let weiter {
                        Button("Überspringen", action: weiter).frame(maxWidth: .infinity).foregroundStyle(.secondary)
                    }
                }
                if gespeichert {
                    Label("Gespeichert", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                }
            } else {
                korrekturBereich(eintrag: eintrag)
            }
        }
    }

    @ViewBuilder
    private func korrekturBereich(eintrag: AusspracheEintrag?) -> some View {
        let vorschlaege = AusspracheRisiko.vorschlaege(name)
        VStack(alignment: .leading, spacing: 14) {
            if !vorschlaege.isEmpty {
                Text("Vorschläge zum Anhören").font(.headline)
                ForEach(vorschlaege, id: \.self) { v in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(v.lautschrift).font(.body.monospaced())
                            Text(v.beschreibung).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.sprich(kontextSatz, probe: probe(laut: v.lautschrift, ipa: "")) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                            .buttonStyle(.borderless)
                        Button("Wählen") { lautschrift = v.lautschrift; ipa = "" }
                            .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(lautschrift == v.lautschrift ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Eigene Lautschrift").font(.headline)
                Text("So schreiben, wie es klingen soll, z. B. „Woitschechowski“. Bindestriche trennen Silben.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Lautschrift", text: $lautschrift)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button { model.sprich(kontextSatz, probe: probe(laut: lautschrift, ipa: "")) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                        .disabled(lautschrift.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            DisclosureGroup("Für Profis: Internationale Lautschrift (IPA)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Genauer als Lautschrift, inklusive Betonung (ˈ). Hat Vorrang, wenn ausgefüllt. Beispiel: Wojciechowski → vɔjt͡ɕɛˈxɔfskʲi")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("IPA", text: $ipa)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button { model.sprich(kontextSatz, probe: probe(laut: lautschrift, ipa: ipa)) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                            .disabled(ipa.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.ipaZeichen, id: \.self) { z in
                                Button(z) { ipa += z }.buttonStyle(.bordered).font(.body.monospaced())
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }

            HStack {
                Button("Abbrechen") { korrigieren = false }
                    .buttonStyle(.bordered)
                Spacer()
                if eintrag != nil {
                    Button("Zurücksetzen", role: .destructive) {
                        model.entferneEintrag(name)
                        lautschrift = ""
                        ipa = ""
                        korrigieren = false
                    }
                }
                Button("Speichern") {
                    model.speichereKorrektur(name, lautschrift: lautschrift.trimmingCharacters(in: .whitespaces), ipa: ipa.trimmingCharacters(in: .whitespaces))
                    korrigieren = false
                    weiterOderBestaetigen()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func probe(laut: String, ipa: String) -> AusspracheEintrag {
        AusspracheEintrag(schreibweise: name, lautschrift: laut, ipa: ipa, pruefung: .korrigiert)
    }

    private func weiterOderBestaetigen() {
        model.sprecher.stopp()
        if let weiter { weiter() } else { gespeichert = true }
    }
}
