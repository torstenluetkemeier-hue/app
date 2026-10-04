import SwiftUI
import WochenleichtCore

/// Ersteinrichtung: Profil → Kalorienlimit, Wasserziel, Gewürzvorrat, Erinnerungen.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var profile = UserProfile()
    @State private var waterGoal = 3000
    @State private var reminders = ReminderSettings()
    @State private var staples: Set<String> = ["salz", "pfeffer", "olivenoel"]
    @State private var notificationsGranted: Bool?

    private let stepCount = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: Double(stepCount))
                    .padding()
                Group {
                    switch step {
                    case 0: ProfileForm(profile: $profile, showsIntro: true)
                    case 1: waterStep
                    case 2: staplesStep
                    default: remindersStep
                    }
                }
                .frame(maxHeight: .infinity)

                HStack {
                    if step > 0 {
                        Button("Zurück") { withAnimation { step -= 1 } }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button(step == stepCount - 1 ? "Plan erstellen" : "Weiter") {
                        if step == stepCount - 1 {
                            model.completeOnboarding(profile: profile, waterGoal: waterGoal, stapleIds: staples, reminders: reminders)
                        } else {
                            withAnimation { step += 1 }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle(["Dein Profil", "Wasser", "Dein Vorrat", "Erinnerungen"][step])
        }
    }

    private var waterStep: some View {
        Form {
            Section {
                Stepper(value: $waterGoal, in: WaterLog.minimumDailyGoalMl...6000, step: 250) {
                    LabeledContent("Tagesziel", value: Format.liters(waterGoal))
                }
            } footer: {
                Text("Mindestens 3 Liter pro Tag. Wasser sättigt, hilft beim Abnehmen und wird von Hunger oft nicht unterschieden.")
            }
            Section("Dein Tag") {
                TimeOfDayPicker(title: "Aufstehen", time: $reminders.wakeTime)
                TimeOfDayPicker(title: "Schlafengehen", time: $reminders.sleepTime)
            }
        }
    }

    private var staplesStep: some View {
        let staples = model.catalog.ingredients.values.filter(\.isStaple).sorted { $0.name < $1.name }
        return Form {
            Section {
                ForEach(staples) { ingredient in
                    Toggle(ingredient.name, isOn: Binding(
                        get: { self.staples.contains(ingredient.id) },
                        set: { isOn in
                            if isOn { self.staples.insert(ingredient.id) } else { self.staples.remove(ingredient.id) }
                        }
                    ))
                }
            } header: {
                Text("Was hast du schon zu Hause?")
            } footer: {
                Text("Gewürze, Öle und Saucen landen nur auf der Einkaufsliste, wenn sie fehlen. Wochenleicht merkt sich danach automatisch, was du nach jedem Einkauf vorrätig haben solltest.")
            }
        }
    }

    private var remindersStep: some View {
        Form {
            Section {
                Picker("Intensität", selection: $reminders.intensity) {
                    ForEach(ReminderIntensity.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(reminders.intensity.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Wie hartnäckig soll ich sein?")
            }
            Section {
                Button {
                    Task { notificationsGranted = await NotificationService.shared.requestAuthorization() }
                } label: {
                    Label("Benachrichtigungen erlauben", systemImage: "bell.badge")
                }
                if let notificationsGranted {
                    Label(notificationsGranted ? "Erlaubt – ich werde dich erinnern." : "Abgelehnt. Ohne Benachrichtigungen kann ich dich nicht erinnern – bitte in den Einstellungen aktivieren.",
                          systemImage: notificationsGranted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(notificationsGranted ? .green : .red)
                }
            } footer: {
                Text("Du bekommst Wasser-Erinnerungen, Mahlzeiten-Hinweise, einen Abend-Check, den wöchentlichen Wiegetag und eine Einkaufserinnerung.")
            }
        }
    }
}

struct TimeOfDayPicker: View {
    let title: String
    @Binding var time: TimeOfDay

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { DayKey(Date()).date(hour: time.hour, minute: time.minute) },
            set: { time = TimeOfDay($0) }
        ), displayedComponents: .hourAndMinute)
    }
}

/// Profilformular – auch in den Einstellungen verwendet.
struct ProfileForm: View {
    @Binding var profile: UserProfile
    var showsIntro = false

    private var limit: Int { CalorieCalculator.dailyLimit(profile) }

    var body: some View {
        Form {
            if showsIntro {
                Section {
                    Text("Aus deinen Angaben berechne ich deine tägliche Kalorienobergrenze – mit einem moderaten Defizit, das du langfristig durchhältst.")
                        .font(.subheadline)
                }
            }
            Section("Körper") {
                Picker("Geschlecht", selection: $profile.sex) {
                    ForEach(Sex.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Alter: \(profile.age) Jahre", value: $profile.age, in: 16...100)
                Stepper("Größe: \(Int(profile.heightCm)) cm", value: $profile.heightCm, in: 130...220, step: 1)
                Stepper("Gewicht: \(Format.kilograms(profile.currentWeightKg))", value: $profile.currentWeightKg, in: 40...250, step: 0.5)
                Stepper("Zielgewicht: \(Format.kilograms(profile.targetWeightKg))", value: $profile.targetWeightKg, in: 40...250, step: 0.5)
                LabeledContent("BMI", value: String(format: "%.1f", profile.bmi))
            }
            Section("Alltag & Tempo") {
                Picker("Aktivität", selection: $profile.activity) {
                    ForEach(ActivityLevel.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Abnahme pro Woche", selection: $profile.weeklyLossKg) {
                    Text("0,25 kg (sanft)").tag(0.25)
                    Text("0,5 kg (empfohlen)").tag(0.5)
                    Text("0,75 kg (ehrgeizig)").tag(0.75)
                }
                Toggle("Nachmittags-Snack einplanen", isOn: $profile.includeSnack)
            }
            Section {
                Toggle("Kalorienlimit selbst festlegen", isOn: Binding(
                    get: { profile.calorieLimitOverride != nil },
                    set: { profile.calorieLimitOverride = $0 ? limit : nil }
                ))
                if let override = profile.calorieLimitOverride {
                    Stepper("Limit: \(override) kcal", value: Binding(
                        get: { override },
                        set: { profile.calorieLimitOverride = $0 }
                    ), in: CalorieCalculator.minimumIntake(profile)...4000, step: 50)
                }
            } header: {
                Text("Kalorienobergrenze")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dein Tageslimit: \(limit) kcal").font(.headline).foregroundStyle(.primary)
                    Text("Grundumsatz \(Int(CalorieCalculator.basalMetabolicRate(profile))) kcal · Gesamtumsatz \(Int(CalorieCalculator.totalEnergyExpenditure(profile))) kcal")
                    if let weeks = CalorieCalculator.weeksToGoal(profile) {
                        Text("Zielgewicht in ca. \(weeks) Wochen.")
                    }
                    Text("Aus Sicherheitsgründen nie unter \(CalorieCalculator.minimumIntake(profile)) kcal. Bei Vorerkrankungen bitte ärztlich abklären.")
                }
            }
        }
    }
}
