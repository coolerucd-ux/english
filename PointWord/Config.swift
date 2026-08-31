import Foundation

// Region-aware backend routing — DIRECT to DashScope (Aliyun Tongyi).
//
// The app now calls DashScope's OpenAI-compatible endpoint DIRECTLY; the Aliyun
// Function Compute proxy was removed to cut cost. Trade-offs accepted for this:
//   • The API key ships INSIDE the app (see dashScopeAPIKey). An app binary can
//     be reverse-engineered, so treat this key as semi-public: set a hard
//     SPENDING CAP / daily quota on it in the DashScope console so a leak can't
//     run up an unbounded bill. There is no server, so PER-USER limits are not
//     possible here — only account-level caps.
//
// DashScope has two OpenAI-compatible hosts; we pick the nearer one by DEVICE
// REGION (Settings › General › Language & Region), not the in-app language, so a
// Chinese speaker abroad still hits the fast nearby host and vice-versa.
enum AppRegion {
    case china
    case overseas

    static var current: AppRegion {
        if Locale.current.region?.identifier == "CN" { return .china }
        return .overseas
    }

    // DashScope OpenAI-compatible chat/completions endpoint for this region.
    var apiURL: String {
        switch self {
        case .china:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .overseas:
            // Singapore host — lower latency for users outside the mainland.
            return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
        }
    }
}

enum Config {
    // Resolved once per launch from the device region.
    static let apiURL = AppRegion.current.apiURL

    // DashScope API key. PASTE YOUR KEY HERE (starts with "sk-").
    // ⚠️ This ships in the app binary — set a daily quota / spend cap on this key
    // in the DashScope console (Model Studio) so a leak can't run up the bill.
    static let dashScopeAPIKey = "sk-PASTE-YOUR-KEY-HERE"

    // The model the proxy used to lock server-side. qwen-plus balances quality and
    // cost; switch to qwen-turbo for cheaper/faster or qwen-max for best quality.
    static let model = "qwen-plus"
}
