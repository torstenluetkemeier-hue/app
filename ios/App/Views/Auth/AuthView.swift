import SwiftUI

/// Registrierung bzw. Anmeldung per E-Mail und Passwort – Pflicht vor der Nutzung.
struct AuthView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case register = "Registrieren"
        case login = "Anmelden"
        var id: String { rawValue }
    }

    @Environment(AuthService.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmReset = false
    @State private var infoMessage: String?
    @State private var mode: Mode = .register
    @State private var email = ""
    @State private var password = ""
    @State private var passwordRepeat = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    enum Field { case email, password, repeatPassword }

    private var passwordProblems: [String] {
        var problems: [String] = []
        if password.count < 8 { problems.append("mindestens 8 Zeichen") }
        if password.rangeOfCharacter(from: .letters) == nil { problems.append("ein Buchstabe") }
        if password.rangeOfCharacter(from: .decimalDigits) == nil { problems.append("eine Ziffer") }
        return problems
    }

    private var isEmailValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.split(separator: "@").last?.contains(".") == true
    }

    private var canSubmit: Bool {
        guard isEmailValid, !isWorking else { return false }
        switch mode {
        case .login: return !password.isEmpty
        case .register: return passwordProblems.isEmpty && password == passwordRepeat
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "leaf.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        Text("Wochenleicht")
                            .font(.largeTitle.bold())
                        Text("Nachhaltig abnehmen – mit Wochenplan, Einkaufslisten und Wasser-Tracking.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    Picker("Modus", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("E-Mail", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                    SecureField("Passwort", text: $password)
                        .textContentType(mode == .register ? .newPassword : .password)
                        .focused($focused, equals: .password)
                        .submitLabel(mode == .register ? .next : .go)
                        .onSubmit {
                            if mode == .register { focused = .repeatPassword } else { submit() }
                        }
                    if mode == .register {
                        SecureField("Passwort wiederholen", text: $passwordRepeat)
                            .textContentType(.newPassword)
                            .focused($focused, equals: .repeatPassword)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    }
                } footer: {
                    if mode == .register {
                        VStack(alignment: .leading, spacing: 4) {
                            if !password.isEmpty && !passwordProblems.isEmpty {
                                Text("Passwort braucht: " + passwordProblems.joined(separator: ", "))
                                    .foregroundStyle(.orange)
                            }
                            if !passwordRepeat.isEmpty && password != passwordRepeat {
                                Text("Passwörter stimmen nicht überein.").foregroundStyle(.orange)
                            }
                            Text("Konto und Daten bleiben ausschließlich auf diesem Gerät. Das Passwort wird nur als sicherer Hash gespeichert. Du kannst dein Konto jederzeit in der App löschen.")
                        }
                    }
                }

                if let infoMessage {
                    Section {
                        Label(infoMessage, systemImage: "info.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView() } else { Text(mode.rawValue).bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                    if mode == .login {
                        Button("Passwort vergessen?") { confirmReset = true }
                            .frame(maxWidth: .infinity)
                            .disabled(!isEmailValid)
                    }
                }
            }
            .onChange(of: mode) { _, _ in
                errorMessage = nil
                infoMessage = nil
            }
            .confirmationDialog("Konto zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Konto und Daten löschen", role: .destructive) {
                    if environment.resetAccount(email: email) {
                        password = ""
                        passwordRepeat = ""
                        mode = .register
                        infoMessage = "Konto gelöscht. Du kannst dich mit derselben E-Mail neu registrieren."
                    } else {
                        errorMessage = "Für diese E-Mail gibt es auf diesem Gerät kein Konto."
                    }
                }
            } message: {
                Text("Da alle Daten nur auf diesem Gerät liegen, kann das Passwort nicht per E-Mail wiederhergestellt werden. Du kannst das Konto für \(email) löschen und dich neu registrieren – Wochenplan, Vorrat und Verlauf gehen dabei verloren.")
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        errorMessage = nil
        let email = email.trimmingCharacters(in: .whitespaces)
        Task {
            defer { isWorking = false }
            do {
                switch mode {
                case .register: try await auth.register(email: email, password: password)
                case .login: try await auth.login(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
