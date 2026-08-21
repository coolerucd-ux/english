import Foundation

// Region-aware backend routing.
//
// The app never holds the DashScope API key. It talks to a thin HTTP proxy that
// injects the key server-side. We run (or plan to run) two proxies so users hit
// a nearby endpoint instead of crossing borders:
//
//   • China   → Aliyun Function Compute (Hangzhou)   — fast inside the mainland
//   • Overseas → Cloudflare Worker (global edge)      — fast everywhere else
//
// Routing is decided by the DEVICE REGION (Settings › General › Language & Region),
// not the in-app language. A Chinese speaker living abroad still gets the nearby
// overseas edge; a French visitor in China still routes overseas. Region is a
// stable per-device setting, so this is the reliable signal.
enum AppRegion {
    case china
    case overseas

    static var current: AppRegion {
        if Locale.current.region?.identifier == "CN" { return .china }
        return .overseas
    }

    // The proxy this region should talk to.
    var apiProxyURL: String {
        switch self {
        case .china:
            return "https://pointword-api-tjsevsqlrr.cn-hangzhou.fcapp.run"
        case .overseas:
            // TODO: deploy the Cloudflare Worker, then paste its URL here, e.g.
            //   https://pointword.<your-subdomain>.workers.dev
            // Until then we fall back to the China endpoint so overseas users are
            // never fully broken — just slower.
            return "https://pointword-api-tjsevsqlrr.cn-hangzhou.fcapp.run"
        }
    }
}

enum Config {
    // Resolved once per launch from the device region. Everything (AIService,
    // the network probe) reads this single value, so switching endpoints is one
    // edit in AppRegion above.
    static let apiProxyURL = AppRegion.current.apiProxyURL

    // Optional shared secret. Leave empty unless you set APP_SHARED_SECRET on the
    // proxy; if set, it must match the function's env var exactly.
    static let appSharedSecret = ""
}
