import SwiftUI
import SwiftData

@main
struct PointWordApp: App {
    // First launch shows onboarding (language + permissions); afterwards, the app.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            // The app is dark chrome over a live camera feed. Lock it to a single
            // (dark) appearance so it never follows the system light/dark toggle —
            // otherwise the Liquid Glass badge renders light while the cards stay
            // dark charcoal, and the two don't match.
            .preferredColorScheme(.dark)
        }
        .modelContainer(for: SavedWord.self)
    }
}
