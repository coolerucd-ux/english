import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// WORD REUNION ("单词重逢")
//
// When the user points at a word they SAVED ON AN EARLIER DAY, we still show the
// normal explanation card (word / phonetic / meaning) — but capped with a small
// "we meet again" BANNER: how many times they've seen it, when they last saw it,
// and what the last photo showed. Tapping the banner ("去回忆") opens that word
// inside the collection list, reusing the library's swipe-through detail.
//
// Trigger (unchanged, deliberately minimal — per spec "全砍"):
//   • Trigger  = saved ✓  AND  last-saved date ≠ today ✓
//   • Skips    = saved TODAY (anti-spam), or a high-frequency word (whitelist)
//   • NO word-form normalization, NO scheduling.
// Everything the banner and card show already lives on the SavedWord, so the
// reunion needs no network and appears instantly.
// ─────────────────────────────────────────────────────────────────────────────
enum Reunion {
    // Function words so common a "reunion" would fire constantly and feel like
    // noise. Pointing at one of these never triggers the moment. ~50 words.
    static let highFrequency: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "of", "at", "by", "for",
        "with", "to", "from", "in", "on", "off", "out", "up", "down", "over",
        "is", "am", "are", "was", "were", "be", "been", "being", "do", "does",
        "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "them",
        "my", "your", "this", "that", "these", "those", "as", "so", "not", "no",
        "yes", "here", "there", "then", "than"
    ]

    // Is this reappearing word a reunion candidate? Pure decision, no side effects.
    static func shouldTrigger(word: SavedWord) -> Bool {
        if highFrequency.contains(word.word.lowercased()) { return false }
        // Saved today → skip, so a word just added doesn't immediately "reunite".
        if Calendar.current.isDateInToday(word.createdAt) { return false }
        return true
    }
}

// A snapshot of what the reunion banner shows, captured at trigger time BEFORE we
// bump the word's counters — otherwise "上次见到" would read as "just now". Value
// type so the view never reads mutated model state mid-animation.
struct ReunionBanner {
    let count: Int        // this encounter's ordinal — "第 N 次见到"
    let lastSeen: Date    // the PREVIOUS time it was seen (before this one)
    let scene: String     // AI caption of the last photo; may be empty
}

// MARK: - Reunion banner
//
// A single tappable strip that sits ABOVE the normal word card. It reads as one
// natural sentence — "👋 这是你第 4 次见它，最近是今年5月纽约的菜单" (count +
// friendly calendar time + photo scene) — with just a chevron on the right.
// Tapping anywhere opens the word in the collection list.
struct ReunionBannerView: View {
    let banner: ReunionBanner
    var language: AppLanguage = .zhHans
    var onRecall: () -> Void

    // The whole banner is ONE natural sentence — count + a friendly calendar time
    // + the photo scene — e.g. "👋 这是你第 4 次见它，最近是今年5月纽约的菜单".
    private var line: String {
        language.reunionLine(
            count: banner.count,
            when: language.reunionWhen(banner.lastSeen),
            scene: banner.scene
        )
    }

    var body: some View {
        Button(action: onRecall) {
            HStack(spacing: 10) {
                Text(line)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)   // let a long place/theme shrink before truncating

                Spacer(minLength: 8)

                // Just a chevron — the whole strip is the "去回忆" affordance now,
                // no separate label. Tapping anywhere opens the collection list.
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(Color.reunionAccent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .darkPanel(cornerRadius: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.reunionAccent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// Reunion accent — the app's green (#32f08c family), matching the finger dot / sweep.
extension Color {
    static let reunionAccent = Color(red: 0.196, green: 0.941, blue: 0.549)
}
