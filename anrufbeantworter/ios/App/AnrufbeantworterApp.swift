import SwiftUI
import AnrufbeantworterCore

@main
struct AnrufbeantworterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.accentColor)
        }
    }
}

enum Tab: Hashable { case ansage, status, aussprache, einstellungen }

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .ansage

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { AnsageView(tab: $tab) }
                .tabItem { Label("Ansage", systemImage: "waveform") }
                .tag(Tab.ansage)
            NavigationStack { StatusView() }
                .tabItem { Label("Status", systemImage: "calendar.badge.clock") }
                .tag(Tab.status)
            NavigationStack { AusspracheView() }
                .tabItem { Label("Aussprache", systemImage: "character.bubble") }
                .badge(model.offeneNamensHinweise.count)
                .tag(Tab.aussprache)
            NavigationStack { EinstellungenView() }
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(Tab.einstellungen)
        }
        .fullScreenCover(isPresented: Binding(get: { !model.konfig.onboardingErledigt }, set: { _ in })) {
            OnboardingView()
        }
        // Freiwillige Rückfrage bei neuen Namen – kein Zwang
        .alert("Aussprache anhören?", isPresented: Binding(
            get: { !model.ausspracheFrage.isEmpty },
            set: { if !$0 { model.ausspracheFrage = [] } }
        )) {
            Button("Jetzt anhören") {
                model.pruefAuftrag = model.ausspracheFrage
                tab = .aussprache
            }
            Button("Später", role: .cancel) {}
            Button("Nicht mehr fragen") { model.konfig.nachAusspracheFragen = false }
        } message: {
            Text("Neu in deiner Ansage: \(model.ausspracheFrage.joined(separator: ", ")). Möchtest du kurz prüfen, ob die Stimme den Namen richtig ausspricht?")
        }
        .sheet(item: Binding(
            get: { model.pruefAuftrag.map(PruefAuftrag.init) },
            set: { if $0 == nil { model.pruefAuftrag = nil } }
        )) { auftrag in
            PruefAblaufView(namen: auftrag.namen)
        }
    }
}

struct PruefAuftrag: Identifiable {
    let namen: [String]
    var id: String { namen.joined(separator: "|") }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var vorname = ""
    @State private var nachname = ""
    @State private var funktion = ""
    @State private var vertretungName = ""
    @State private var vertretungTelefon = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Dein Anrufbeantworter meldet sich einheitlich im zollsoft-Stil mit einer angenehmen Stimme. Erzähl ihm kurz, wer du bist.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Ich bin") {
                    TextField("Vorname", text: $vorname).textContentType(.givenName)
                    TextField("Nachname", text: $nachname).textContentType(.familyName)
                    TextField("Funktion (z. B. Kundenberater)", text: $funktion).textContentType(.jobTitle)
                }
                Section {
                    TextField("Name", text: $vertretungName)
                    TextField("Telefon", text: $vertretungTelefon).keyboardType(.phonePad)
                } header: {
                    Text("Meine Vertretung (optional)")
                } footer: {
                    Text("Wird bei Urlaub, Krankheit und Dienstreisen genannt. Weitere Vertretungen kannst du später anlegen.")
                }
            }
            .navigationTitle("Willkommen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Los geht’s") { fertig() }
                        .disabled(vorname.trimmingCharacters(in: .whitespaces).isEmpty || nachname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func fertig() {
        var k = model.konfig
        k.profil.vorname = vorname.trimmingCharacters(in: .whitespaces)
        k.profil.nachname = nachname.trimmingCharacters(in: .whitespaces)
        k.profil.funktion = funktion.trimmingCharacters(in: .whitespaces)
        if !vertretungName.trimmingCharacters(in: .whitespaces).isEmpty {
            let v = Vertretung(name: vertretungName.trimmingCharacters(in: .whitespaces), telefon: vertretungTelefon)
            k.vertretungen = [v]
            k.standardVertretungID = v.id
        }
        k.onboardingErledigt = true
        model.konfig = k
        model.pruefeNeueNamen()
        Task { await Erinnerungen.erlaubnisAnfragen() }
    }
}
