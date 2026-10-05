import SwiftUI
import WochenleichtCore

@main
struct WochenleichtApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private var environment: AppEnvironment { .shared }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.auth)
                .tint(.accentColor)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                environment.model?.refreshForNewDay()
            } else if phase == .background {
                AppDelegate.scheduleBackgroundRefresh()
            }
        }
    }
}

/// Hält Auth-Dienst und das Modell des angemeldeten Benutzers.
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let auth: AuthService
    let catalog: RecipeCatalog
    private(set) var model: AppModel?

    private init() {
        auth = AuthService()
        do {
            catalog = try RecipeCatalog.bundled()
        } catch {
            fatalError("Rezeptkatalog konnte nicht geladen werden: \(error)")
        }
        updateModel()
    }

    /// Erzeugt bzw. verwirft das Modell passend zum Anmeldestatus.
    func updateModel() {
        guard let user = auth.currentUser else {
            model = nil
            return
        }
        if model?.user != user {
            model = AppModel(user: user, catalog: catalog)
            model?.refreshForNewDay()
        }
    }

    func deleteAccount() {
        model?.deleteLocalData()
        auth.deleteAccount()
        updateModel()
    }

    func logout() {
        auth.logout()
        updateModel()
    }

    /// „Passwort vergessen“: lokales Konto und dessen Daten löschen.
    func resetAccount(email: String) -> Bool {
        guard let id = auth.resetAccount(email: email) else { return false }
        LocalStore(userId: id).delete()
        return true
    }
}
