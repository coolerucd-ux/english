import SwiftUI

// First-launch flow: pick native language, then go straight to the scanner.
// Camera + network permission prompts are triggered on the scanner itself
// (see CameraView), not on a separate explainer screen.
struct OnboardingView: View {
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.deviceDefault.rawValue
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            languageStep
        }
    }

    // MARK: - Pick native language

    private var languageStep: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 80)

            Text("What's your native language?")
                .font(.title2.bold())
                .padding(.bottom, 28)

            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        languageRaw = lang.rawValue
                    } label: {
                        HStack {
                            Text(lang.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            ZStack {
                                Circle()
                                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.4)
                                    .frame(width: 20, height: 20)
                                if lang == language {
                                    Circle().fill(Color.primary).frame(width: 12, height: 12)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(
                            Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            Button {
                // Straight to the scanner; it asks for camera/network there.
                hasOnboarded = true
            } label: {
                Text(language.continueButton)
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .glassProminentCapsule(tint: .white)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }
}
