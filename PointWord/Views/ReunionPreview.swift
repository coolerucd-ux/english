#if DEBUG
import SwiftUI
import SwiftData
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// REUNION — FAKE-DATA PREVIEW DOMAIN  (DEBUG ONLY, never shipped)
//
// A self-contained sandbox for LOOKING AT the "单词重逢" design without having to
// actually save a word yesterday and re-point at it today. It fabricates a few
// SavedWords — each with a drawn book-page photo, a scene caption, a seen-count
// and a last-seen date — then renders exactly what CameraView.cardBlock shows:
// the reunion banner capping the normal explanation card.
//
// Wrapped in `#if DEBUG` so it is stripped from release builds entirely. Open this
// file in Xcode's canvas (Preview) to browse the variants.
// ─────────────────────────────────────────────────────────────────────────────
enum ReunionSampleData {

    // A drawn "photographed book page" — a warm paper gradient with faint text
    // lines — so previews need no bundled image and no camera. Returns JPEG data,
    // matching SavedWord.snapshot.
    static func pagePhoto(tint: Color = Color(red: 0.86, green: 0.82, blue: 0.74),
                          size: CGSize = CGSize(width: 900, height: 900)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            // Paper gradient.
            let top = UIColor(tint).cgColor
            let bottom = UIColor(tint).withAlphaComponent(0.7).cgColor
            let space = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(grad,
                                      start: .zero,
                                      end: CGPoint(x: 0, y: size.height),
                                      options: [])
            }
            // Faint horizontal "text" lines.
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.10).cgColor)
            cg.setLineWidth(6)
            let margin: CGFloat = 90
            var y: CGFloat = 200
            var i = 0
            while y < size.height - margin {
                let inset = (i % 4 == 3) ? size.width * 0.35 : margin   // ragged paragraph ends
                cg.move(to: CGPoint(x: margin, y: y))
                cg.addLine(to: CGPoint(x: size.width - inset, y: y))
                cg.strokePath()
                y += 74
                i += 1
            }
        }
        return img.jpegData(compressionQuality: 0.9) ?? Data()
    }

    // Build one fake saved word with reunion/footprint fields populated.
    static func word(_ term: String,
                     phonetic: String,
                     pos: String,
                     meanings: [String],
                     scene: String,
                     seenCount: Int,
                     daysAgoLastSeen: Int,
                     daysAgoCreated: Int,
                     city: String = "",
                     venue: String = "",
                     emoji: String = "",
                     tint: Color) -> SavedWord {
        let created = Calendar.current.date(byAdding: .day, value: -daysAgoCreated, to: .now) ?? .now
        let w = SavedWord(
            word: term,
            phonetic: phonetic,
            partOfSpeech: pos,
            meanings: meanings,
            scene: scene,
            snapshot: pagePhoto(tint: tint),
            createdAt: created
        )
        w.seenCount = seenCount
        w.lastSeenAt = Calendar.current.date(byAdding: .day, value: -daysAgoLastSeen, to: .now) ?? created
        w.placeCity = city
        w.venue = venue
        w.venueEmoji = emoji
        return w
    }

    // A spread of variants covering the banner's moving parts: recent vs. months
    // ago, with/without a scene caption, small vs. large counts.
    static var words: [SavedWord] {
        [
            word("Welcome", phonetic: "/ˈwelkəm/", pos: "v.",
                 meanings: ["欢迎；迎接；对接"],
                 scene: "纽约的菜单", seenCount: 4, daysAgoLastSeen: 118, daysAgoCreated: 140,
                 city: "纽约", venue: "餐厅", emoji: "🍽️",
                 tint: Color(red: 0.85, green: 0.80, blue: 0.70)),
            word("evolution", phonetic: "/ˌiːvəˈluːʃən/", pos: "n.",
                 meanings: ["进化；演变；发展"],
                 scene: "图书馆的书", seenCount: 2, daysAgoLastSeen: 3, daysAgoCreated: 20,
                 city: "杭州市", venue: "图书馆", emoji: "📖",
                 tint: Color(red: 0.82, green: 0.83, blue: 0.78)),
            word("delicate", phonetic: "/ˈdelɪkət/", pos: "adj.",
                 meanings: ["精致的；微妙的；易碎的"],
                 scene: "", seenCount: 7, daysAgoLastSeen: 1, daysAgoCreated: 65,
                 venue: "地铁", emoji: "🚇",
                 tint: Color(red: 0.80, green: 0.78, blue: 0.82)),
            word("horizon", phonetic: "/həˈraɪzn/", pos: "n.",
                 meanings: ["地平线；眼界；范围"],
                 scene: "街头的广告牌", seenCount: 3, daysAgoLastSeen: 400, daysAgoCreated: 430,
                 city: "东京", venue: "广告牌", emoji: "🪧",
                 tint: Color(red: 0.84, green: 0.79, blue: 0.71)),
        ]
    }

    // The banner snapshot for a given word — mirrors what CameraView captures at
    // trigger time (ordinal = seenCount + 1, "上次见到" = the stored lastSeen).
    static func banner(for w: SavedWord) -> ReunionBanner {
        ReunionBanner(count: w.seenCount + 1, lastSeen: w.effectiveLastSeen, scene: w.scene)
    }

    // Insert the fake words into a REAL SwiftData context so the collection and
    // 足迹 pages render populated on-device. Skips words already present (unique
    // constraint on `word`) so tapping "灌入示例数据" twice is harmless. Each word
    // gets a few encounter photos so the "去回忆" photo group has a real grid.
    @MainActor
    static func seed(into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<SavedWord>()))?
            .map { $0.word.lowercased() } ?? []
        let have = Set(existing)
        for w in words where !have.contains(w.word.lowercased()) {
            context.insert(w)
            attachPhotos(to: w, into: context)
        }
        try? context.save()
    }

    // Give a fake word a handful of encounter photos at different tints/places so
    // its photo group shows more than one shot.
    @MainActor
    static func attachPhotos(to w: SavedWord, into context: ModelContext) {
        let variants: [(tint: Color, city: String, venue: String, emoji: String, daysAgo: Int)] = [
            (Color(red: 0.85, green: 0.80, blue: 0.70), w.placeCity, w.venue, w.venueEmoji, 0),
            (Color(red: 0.80, green: 0.83, blue: 0.86), "上海市", "咖啡馆", "☕️", 30),
            (Color(red: 0.86, green: 0.82, blue: 0.74), "东京", "书店", "📚", 90),
        ]
        for v in variants {
            let created = Calendar.current.date(byAdding: .day, value: -v.daysAgo, to: .now) ?? .now
            let p = WordPhoto(image: pagePhoto(tint: v.tint),
                              createdAt: created,
                              placeCity: v.city,
                              venue: v.venue,
                              venueEmoji: v.emoji,
                              scene: w.scene)
            p.word = w
            context.insert(p)
        }
    }
}

// The reunion moment exactly as CameraView.cardBlock stacks it: tappable banner
// over the normal explanation card. One row per fake word. Reused both by the
// Xcode canvas (#Preview below) and by the in-app DEBUG entry so a real device
// shows the identical design.
struct ReunionDesignGallery: View {
    var body: some View {
        // Own in-memory store so the reunion words really exist as SavedWords —
        // that's what lets the banner's "去回忆" open the actual photo group.
        GalleryContent()
            .modelContainer(for: [SavedWord.self, WordPhoto.self], inMemory: true)
    }
}

// Inner view: seeds the fake words into the (in-memory) store, renders the
// reunion banner + card for each, and — tapping a banner — opens the SAME
// photo-group view the real "去回忆" uses.
private struct GalleryContent: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedWord.createdAt, order: .reverse) private var words: [SavedWord]
    // The word whose photo group is up (banner tap → open grid).
    @State private var recallItem: SavedWord? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                ForEach(words) { w in
                    VStack(spacing: 10) {
                        ReunionBannerView(banner: ReunionSampleData.banner(for: w),
                                          language: .zhHans) {
                            // Same behaviour as the real reunion banner: open the
                            // photo group for THIS word.
                            recallItem = w
                        }
                        WordCardView(
                            state: .loaded(WordExplanation(
                                word: w.word,
                                phonetic: w.phonetic,
                                partOfSpeech: w.partOfSpeech,
                                meanings: w.meanings
                            )),
                            language: .zhHans,
                            snapshot: w.snapshot
                        )
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 30)
        }
        .background(
            // Stand-in for the live camera behind the cards.
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .onAppear {
            // Populate the in-memory store once so @Query has words to render.
            if words.isEmpty { ReunionSampleData.seed(into: context) }
        }
        // The identical photo-group sheet the reunion banner opens — a 3-per-row
        // album of the word's encounter photos, tappable into a swipeable viewer.
        .sheet(item: $recallItem) { item in
            WordPhotoGroupView(word: item, language: .zhHans)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }
}

#Preview("单词重逢 · 卡片 + 横幅") {
    ReunionDesignGallery()
}

// In-app DEBUG sheet: a header with a "灌入示例数据" button (populates the real
// store so 收藏/足迹 render on-device) over the live reunion design gallery.
struct ReunionDebugSheet: View {
    var onSeed: () -> Void

    var body: some View {
        NavigationStack {
            ReunionDesignGallery()
                .navigationTitle("单词重逢 预览")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("灌入示例数据", action: onSeed)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// Just the banner sentence in isolation — quick to eyeball the copy at different
// counts / times / scenes.
#Preview("单词重逢 · 横幅文案") {
    VStack(spacing: 14) {
        ForEach(Array(ReunionSampleData.words.enumerated()), id: \.offset) { _, w in
            ReunionBannerView(banner: ReunionSampleData.banner(for: w), language: .zhHans) {}
        }
    }
    .padding(20)
    .frame(maxHeight: .infinity)
    .background(Color(white: 0.1).ignoresSafeArea())
    .preferredColorScheme(.dark)
}
#endif
