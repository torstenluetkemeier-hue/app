import Charts
import SwiftUI
import UIKit
import UserNotifications
import WochenleichtCore

struct MoreView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Fortschritt") {
                NavigationLink { WeightView() } label: { Label("Gewicht", systemImage: "scalemass") }
                NavigationLink { WaterHistoryView() } label: { Label("Wasser-Verlauf", systemImage: "drop") }
            }
            Section("Planung") {
                NavigationLink { RecipeBrowserView() } label: { Label("Rezepte nach Kalorien", systemImage: "book") }
                NavigationLink { ProfileEditView() } label: { Label("Profil & Kalorienlimit", systemImage: "person.crop.circle") }
                NavigationLink { StoresView() } label: { Label("Supermärkte", systemImage: "storefront") }
            }
            Section("Einstellungen") {
                NavigationLink { ReminderSettingsView() } label: { Label("Erinnerungen", systemImage: "bell.badge") }
                NavigationLink { AccountView() } label: { Label("Konto", systemImage: "person.badge.key") }
            }
            Section {
                switch model.syncState {
                case .idle:
                    Label("Synchronisiert", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
                case .syncing:
                    Label("Synchronisiere …", systemImage: "arrow.triangle.2.circlepath.icloud").foregroundStyle(.secondary)
                case let .failed(message):
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        Label("Sync fehlgeschlagen: \(message) – erneut versuchen", systemImage: "exclamationmark.icloud")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Wochenleicht ersetzt keine ärztliche oder ernährungstherapeutische Beratung. Kalorienangaben sind Richtwerte.")
            }
        }
        .navigationTitle("Mehr")
    }
}

struct ProfileEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var profile = UserProfile()
    @State private var replan = false
    @State private var loaded = false

    var body: some View {
        ProfileForm(profile: $profile)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Toggle("Noch nicht eingekaufte Tage komplett neu planen", isOn: $replan)
                        .font(.footnote)
                    Button {
                        model.updateProfile(profile, replan: replan)
                        dismiss()
                    } label: {
                        Text("Übernehmen").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Profil")
            .onAppear {
                guard !loaded, let current = model.data.profile else { return }
                profile = current
                loaded = true
            }
    }
}

struct WeightView: View {
    @Environment(AppModel.self) private var model
    @State private var newWeight: Double = 0

    var body: some View {
        List {
            if let profile = model.data.profile {
                Section {
                    LabeledContent("Aktuell", value: Format.kilograms(profile.currentWeightKg))
                    LabeledContent("Ziel", value: Format.kilograms(profile.targetWeightKg))
                    if let first = model.data.weights.first {
                        let diff = profile.currentWeightKg - first.kilograms
                        LabeledContent("Seit Start", value: (diff > 0 ? "+" : "") + Format.kilograms(diff))
                    }
                }
            }
            if model.data.weights.count >= 2 {
                Section("Verlauf") {
                    Chart(model.data.weights) { entry in
                        LineMark(x: .value("Datum", entry.day.date()), y: .value("kg", entry.kilograms))
                        PointMark(x: .value("Datum", entry.day.date()), y: .value("kg", entry.kilograms))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 220)
                }
            }
            Section("Heute wiegen") {
                Stepper(Format.kilograms(newWeight), value: $newWeight, in: 30...300, step: 0.1)
                Button("Gewicht eintragen") { model.logWeight((newWeight * 10).rounded() / 10) }
            }
            Section("Einträge") {
                ForEach(model.data.weights.reversed()) { entry in
                    LabeledContent(entry.day.shortTitle, value: Format.kilograms(entry.kilograms))
                }
            }
        }
        .navigationTitle("Gewicht")
        .onAppear { newWeight = model.data.profile?.currentWeightKg ?? 80 }
    }
}

struct WaterHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.data.water.dailyTotals(endingOn: model.today, days: 14)
        List {
            Section("Letzte 14 Tage") {
                Chart {
                    ForEach(totals) { item in
                        BarMark(x: .value("Tag", item.day.date(), unit: .day), y: .value("Liter", Double(item.milliliters) / 1000))
                            .foregroundStyle(item.milliliters >= model.waterGoal ? Color.blue : Color.blue.opacity(0.4))
                    }
                    RuleMark(y: .value("Ziel", Double(model.waterGoal) / 1000))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Ziel \(Format.liters(model.waterGoal))").font(.caption2).foregroundStyle(.red)
                        }
                }
                .frame(height: 220)
                let reached = totals.filter { $0.milliliters >= model.waterGoal }.count
                LabeledContent("Ziel erreicht", value: "\(reached) von 14 Tagen")
                LabeledContent("Serie", value: "\(model.data.water.streak(goal: model.waterGoal, today: model.today)) Tage")
            }
            Section {
                Stepper(value: Binding(get: { model.waterGoal }, set: { model.setWaterGoal($0) }),
                        in: WaterLog.minimumDailyGoalMl...6000, step: 250) {
                    LabeledContent("Tagesziel", value: Format.liters(model.waterGoal))
                }
            } footer: {
                Text("Das Ziel kann nicht unter 3 Liter gesetzt werden.")
            }
            Section("Heute") {
                ForEach(model.data.water.entries(on: model.today).reversed()) { entry in
                    LabeledContent(entry.date.formatted(date: .omitted, time: .shortened), value: "\(entry.milliliters) ml")
                        .swipeActions {
                            Button("Löschen", role: .destructive) { model.removeWater(entry.id) }
                        }
                }
            }
        }
        .navigationTitle("Wasser")
    }
}

struct ReminderSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = ReminderSettings()
    @State private var loaded = false
    @State private var permission: UNAuthorizationStatusLabel = .unknown

    enum UNAuthorizationStatusLabel { case unknown, allowed, denied, notAsked }

    var body: some View {
        Form {
            Section {
                switch permission {
                case .denied:
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Label("Benachrichtigungen sind deaktiviert – in den Einstellungen erlauben", systemImage: "bell.slash.fill")
                            .foregroundStyle(.red)
                    }
                case .notAsked:
                    Button("Benachrichtigungen erlauben") {
                        Task {
                            _ = await NotificationService.shared.requestAuthorization()
                            await refreshPermission()
                            model.scheduleReminders()
                        }
                    }
                default:
                    EmptyView()
                }
                Toggle("Erinnerungen aktiv", isOn: $settings.isEnabled)
                Picker("Intensität", selection: $settings.intensity) {
                    ForEach(ReminderIntensity.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text(settings.intensity.explanation)
            }

            Section("Wasser") {
                TimeOfDayPicker(title: "Aufstehen", time: $settings.wakeTime)
                TimeOfDayPicker(title: "Schlafengehen", time: $settings.sleepTime)
                Picker("Intervall", selection: $settings.waterIntervalMinutes) {
                    Text("30 Min.").tag(30)
                    Text("45 Min.").tag(45)
                    Text("60 Min.").tag(60)
                    Text("90 Min.").tag(90)
                }
            }

            Section("Mahlzeiten") {
                TimeOfDayPicker(title: MealType.breakfast.displayName, time: $settings.breakfastTime)
                TimeOfDayPicker(title: MealType.lunch.displayName, time: $settings.lunchTime)
                TimeOfDayPicker(title: MealType.snack.displayName, time: $settings.snackTime)
                TimeOfDayPicker(title: MealType.dinner.displayName, time: $settings.dinnerTime)
                TimeOfDayPicker(title: "Abend-Check", time: $settings.eveningCheckTime)
            }

            Section("Wiegen & Einkaufen") {
                Picker("Wiegetag", selection: $settings.weighInWeekday) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(Calendar(identifier: .gregorian).weekdaySymbolsGerman[weekday - 1]).tag(weekday)
                    }
                }
                TimeOfDayPicker(title: "Wiegen um", time: $settings.weighInTime)
                TimeOfDayPicker(title: "Einkaufserinnerung", time: $settings.shoppingReminderTime)
                Toggle("Erinnern, wenn ich an einem meiner Supermärkte bin", isOn: $settings.supermarketProximityAlerts)
            }

            Section {
                Button("Test-Benachrichtigung in 5 Sekunden") {
                    Task { await NotificationService.shared.sendTestNotification() }
                }
            }
        }
        .navigationTitle("Erinnerungen")
        .onAppear {
            if !loaded {
                settings = model.data.reminders
                loaded = true
            }
        }
        .task { await refreshPermission() }
        .onChange(of: settings) { _, new in
            if loaded { model.updateReminders(new) }
        }
    }

    private func refreshPermission() async {
        switch await NotificationService.shared.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: permission = .allowed
        case .denied: permission = .denied
        case .notDetermined: permission = .notAsked
        @unknown default: permission = .unknown
        }
    }
}

private extension Calendar {
    var weekdaySymbolsGerman: [String] {
        var calendar = self
        calendar.locale = Locale(identifier: "de_DE")
        return calendar.weekdaySymbols
    }
}

struct AccountView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppModel.self) private var model
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Angemeldet als") {
                Text(model.user.email)
            }
            Section {
                SecureField("Aktuelles Passwort", text: $currentPassword)
                    .textContentType(.password)
                SecureField("Neues Passwort (mind. 8 Zeichen, Buchstabe + Ziffer)", text: $newPassword)
                    .textContentType(.newPassword)
                Button("Passwort ändern") {
                    run {
                        try await environment.auth.changePassword(current: currentPassword, new: newPassword)
                        currentPassword = ""
                        newPassword = ""
                        message = "Passwort geändert. Andere Geräte wurden abgemeldet."
                    }
                }
                .disabled(currentPassword.isEmpty || newPassword.count < 8 || isWorking)
            } header: {
                Text("Passwort")
            } footer: {
                if let message { Text(message) }
            }
            Section {
                Button("Abmelden") {
                    Task { await environment.logout() }
                }
                Button("Konto und alle Daten löschen", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle("Konto")
        .disabled(isWorking)
        .confirmationDialog("Konto endgültig löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Konto löschen", role: .destructive) {
                run { try await environment.deleteAccount() }
            }
        } message: {
            Text("Alle Pläne, Vorräte, Wasser- und Gewichtsdaten werden auf dem Server und diesem Gerät gelöscht. Das kann nicht rückgängig gemacht werden.")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
