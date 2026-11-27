import SwiftUI
import AnrufbeantworterCore

/// Status sofort setzen und Abwesenheiten/Termine vorplanen.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var entwurf: Status?
    @State private var neuerEintrag = false

    var body: some View {
        let aktiv = AnsageEngine.aktiverStatus(model.konfig)
        List {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(Modus.allCases) { m in
                        Button {
                            if m == .standard {
                                model.konfig.status = nil
                                entwurf = nil
                            } else {
                                entwurf = model.konfig.status?.modus == m ? model.konfig.status : vorschlag(m)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: m.symbol).font(.title3)
                                Text(m == .standard ? "Standard" : m.label).font(.caption.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background((entwurf?.modus ?? aktiv.status.modus) == m ? farbe(m).opacity(0.18) : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(farbe(m))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: {
                Text("Jetzt")
            } footer: {
                Text("„Standard“ hebt einen sofort gesetzten Status auf. Ein gesetzter Status gilt bis zum gewählten Ende und hat Vorrang vor dem Kalender.")
            }

            if let e = entwurf {
                Section("\(e.modus.label) einstellen") {
                    StatusEditor(status: Binding(get: { entwurf ?? e }, set: { entwurf = $0 }), vertretungen: model.konfig.vertretungen)
                    Button("Übernehmen") {
                        model.konfig.status = entwurf
                        entwurf = nil
                    }
                    .bold()
                }
            }

            Section {
                if model.konfig.kalender.isEmpty {
                    Text("Keine geplanten Einträge").foregroundStyle(.secondary)
                }
                ForEach(model.konfig.kalender.sorted { $0.von < $1.von }) { e in
                    KalenderZeile(eintrag: e, aktiv: aktiv.kalenderEintragID == e.id)
                }
                .onDelete { idx in
                    let sortiert = model.konfig.kalender.sorted { $0.von < $1.von }
                    let ids = idx.map { sortiert[$0].id }
                    model.konfig.kalender.removeAll { ids.contains($0.id) }
                }
                Button { neuerEintrag = true } label: { Label("Eintrag planen", systemImage: "plus") }
            } header: {
                Text("Geplant")
            } footer: {
                Text("Zu Beginn und Ende jedes Eintrags erinnert dich die App, die passende Ansage einzuspielen.")
            }
        }
        .navigationTitle("Status")
        .sheet(isPresented: $neuerEintrag) {
            KalenderEditor { model.konfig.kalender.append($0) }
        }
    }

    private func vorschlag(_ m: Modus) -> Status {
        let kal = Zeit.kalender
        switch m {
        case .termin:
            let naechsteStunde = kal.date(byAdding: .hour, value: 1, to: Date())!
            let gerundet = kal.date(bySetting: .minute, value: 0, of: naechsteStunde) ?? naechsteStunde
            return Status(modus: .termin, terminArt: .onlinePraesentation, bis: gerundet)
        case .urlaub, .krank, .abwesend:
            return Status(modus: m, bis: Date())
        case .standard:
            return Status(modus: .standard)
        }
    }
}

struct KalenderZeile: View {
    let eintrag: KalenderEintrag
    let aktiv: Bool

    var body: some View {
        let s = eintrag.status
        let f = Date.FormatStyle().locale(Locale(identifier: "de_DE"))
        let von = s.modus.istGanztaegig ? eintrag.von.formatted(f.day().month()) : eintrag.von.formatted(f.day().month().hour().minute())
        let bis = s.bis.map { s.modus.istGanztaegig ? $0.formatted(f.day().month().year()) : $0.formatted(f.hour().minute()) } ?? "offen"
        HStack {
            Image(systemName: s.modus.symbol).foregroundStyle(farbe(s.modus)).frame(width: 28)
            VStack(alignment: .leading) {
                Text(eintrag.titel.isEmpty ? beschreibung(s) : eintrag.titel)
                Text("\(von) – \(bis)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if aktiv { Text("aktiv").font(.caption.bold()).foregroundStyle(farbe(s.modus)) }
        }
    }

    private func beschreibung(_ s: Status) -> String {
        switch s.modus {
        case .termin: s.terminArt == .sonstiges && !s.freitext.isEmpty ? s.freitext : s.terminArt.label
        case .abwesend: s.abwesendArt == .sonstiges && !s.freitext.isEmpty ? s.freitext : s.abwesendArt.label
        default: s.modus.label
        }
    }
}

/// Bearbeitet Art, Ende und Vertretung eines Status.
struct StatusEditor: View {
    @Binding var status: Status
    let vertretungen: [Vertretung]

    var body: some View {
        if status.modus == .termin {
            Picker("Art", selection: $status.terminArt) {
                ForEach(TerminArt.allCases) { Text($0.label).tag($0) }
            }
        }
        if status.modus == .abwesend {
            Picker("Grund", selection: $status.abwesendArt) {
                ForEach(AbwesendArt.allCases) { Text($0.label).tag($0) }
            }
        }
        if (status.modus == .termin && status.terminArt == .sonstiges) || (status.modus == .abwesend && status.abwesendArt == .sonstiges) {
            TextField("Für die Ansage, z. B. „in einem Workshop“", text: $status.freitext)
        }
        Toggle("Ende angeben", isOn: Binding(
            get: { status.bis != nil },
            set: { status.bis = $0 ? (status.bis ?? Date()) : nil }
        ))
        if let bis = status.bis {
            DatePicker(status.modus.istGanztaegig ? "Bis einschließlich" : "Voraussichtlich bis",
                       selection: Binding(get: { bis }, set: { status.bis = $0 }),
                       displayedComponents: status.modus.istGanztaegig ? [.date] : [.date, .hourAndMinute])
                .environment(\.locale, Locale(identifier: "de_DE"))
        }
        Picker("Vertretung nennen", selection: $status.vertretung) {
            Text("Automatisch").tag(VertretungsWahl.automatisch)
            Text("Keine").tag(VertretungsWahl.keine)
            ForEach(vertretungen) { v in Text(v.name).tag(VertretungsWahl.person(v.id)) }
        }
    }
}

struct KalenderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let speichern: (KalenderEintrag) -> Void
    @State private var eintrag = KalenderEintrag(von: Date(), status: Status(modus: .urlaub, bis: Date()))

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Art", selection: $eintrag.status.modus) {
                        ForEach(Modus.allCases.filter { $0 != .standard }) { Text($0.label).tag($0) }
                    }
                    TextField("Titel (nur für dich)", text: $eintrag.titel)
                    DatePicker(eintrag.status.modus.istGanztaegig ? "Ab" : "Beginn", selection: $eintrag.von,
                               displayedComponents: eintrag.status.modus.istGanztaegig ? [.date] : [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "de_DE"))
                }
                Section {
                    StatusEditor(status: $eintrag.status, vertretungen: model.konfig.vertretungen)
                }
                Section("Vorschau") {
                    let vorschau = AnsageEngine.erstelle(model.konfig, status: AktiverStatus(status: eintrag.status, quelle: .kalender), jetzt: eintrag.von)
                    Text(vorschau.text).font(.callout)
                    Button("Anhören") {
                        model.sprecher.sprich(abschnitte: vorschau.abschnitte.map(\.text), einstellung: model.konfig.stimme, lexikon: model.konfig.lexikon)
                    }
                }
            }
            .navigationTitle("Eintrag planen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if let bis = eintrag.status.bis, bis < eintrag.von { eintrag.status.bis = eintrag.von }
                        speichern(eintrag)
                        dismiss()
                    }
                }
            }
        }
    }
}
