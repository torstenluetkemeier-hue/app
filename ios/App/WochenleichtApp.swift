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
                Task { await environment.model?.syncNow() }
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
        auth = AuthService(api: .fromInfoPlist())
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
            model = AppModel(user: user, auth: auth, catalog: catalog)
            model?.refreshForNewDay()
        }
    }

    func deleteAccount() async throws {
        try await auth.deleteAccount()
        model?.deleteLocalData()
        updateModel()
    }

    func logout() async {
        await auth.logout()
        updateModel()
    }
}
