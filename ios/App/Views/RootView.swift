import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AuthService.self) private var auth

    var body: some View {
        Group {
            if let model = environment.model {
                if model.needsOnboarding {
                    OnboardingView()
                } else {
                    MainTabView()
                }
            } else {
                AuthView()
            }
        }
        .environment(environment.model)
        .animation(.default, value: auth.state)
        .onChange(of: auth.state) { _, _ in
            environment.updateModel()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("Heute", systemImage: "sun.max") }
            NavigationStack { WeekPlanView() }
                .tabItem { Label("Woche", systemImage: "calendar") }
            NavigationStack { ShoppingView() }
                .tabItem { Label("Einkauf", systemImage: "cart") }
            NavigationStack { PantryView() }
                .tabItem { Label("Vorrat", systemImage: "cabinet") }
            NavigationStack { MoreView() }
                .tabItem { Label("Mehr", systemImage: "ellipsis.circle") }
        }
    }
}
