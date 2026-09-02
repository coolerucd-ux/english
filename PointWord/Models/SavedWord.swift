import Foundation
import SwiftData

// A word the user chose to save. Persisted with SwiftData.
@Model
final class SavedWord {
    @Attribute(.unique) var word: String
    var phonetic: String
    var partOfSpeech: String
    var meanings: [String]
    // 语境理解 — 保存时随单词一起存下，详情页复原识别时的上下文解释。
    // 默认空串，让 SwiftData 对旧数据做轻量迁移，老记录这两个字段为空。
    var contextPhrase: String = ""
    var contextMeaning: String = ""
    var createdAt: Date
    // JPEG of the camera frame at save time — used as the library card background.
    @Attribute(.externalStorage) var snapshot: Data?

    // ── Word-reunion fields ──────────────────────────────────────────────────
    // Powers the reunion banner ("第N次见到 · 3天前 · <场景>"). All have defaults
    // so SwiftData lightly migrates existing rows — the same trick contextPhrase
    // uses. Old saves start at seenCount 1, lastSeenAt == createdAt, empty scene.
    //
    // seenCount   — how many times this word has been surfaced (save = 1, then +1
    //               on each later-day reunion). "次数" in the banner.
    // lastSeenAt  — the most recent time it was seen. "最近一次见到的时间". Seeds
    //               from createdAt for old rows.
    // scene       — a short AI-written phrase describing WHERE/WHAT the save photo
    //               shows (e.g. "咖啡馆菜单" / "街头广告牌"). Stands in for the
    //               "地点位置 + 照片主题" the app can't get from GPS. May be empty.
    var seenCount: Int = 1
    var lastSeenAt: Date = Date.distantPast
    var scene: String = ""

    // ── Footprint fields ─────────────────────────────────────────────────────
    // Feed the 足迹 timeline, which groups saves by "place + month". All default
    // to empty so old rows migrate cleanly (they group under "未知地点").
    //
    // placeCity/placeCountry — reverse-geocoded from GPS at save time (free, best
    //     effort). Empty when location is denied/unavailable or for old saves.
    // venue                  — AI venue category from the photo ("图书馆"/"地铁"/
    //     "飞机上"…). Used as the group's place name when there's no GPS city, and
    //     as a subtitle otherwise.
    // venueEmoji             — one emoji for that venue, the group's leading icon.
    var placeCity: String = ""
    var placeCountry: String = ""
    var venue: String = ""
    var venueEmoji: String = ""

    // ── Encounter photo group ────────────────────────────────────────────────
    // Every time this word is met again on a later day, a WordPhoto is appended
    // here — so the word owns the full set of shots of where/when it was seen.
    // Cascade delete: removing the word removes its photos. Optional so old rows
    // migrate cleanly (nil → the legacy single `snapshot` stands in as one photo).
    @Relationship(deleteRule: .cascade, inverse: \WordPhoto.word)
    var photos: [WordPhoto]? = []

    init(word: String, phonetic: String, partOfSpeech: String, meanings: [String], contextPhrase: String = "", contextMeaning: String = "", scene: String = "", snapshot: Data? = nil, createdAt: Date = .now) {
        self.word = word
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.meanings = meanings
        self.contextPhrase = contextPhrase
        self.contextMeaning = contextMeaning
        self.scene = scene
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.seenCount = 1
        self.lastSeenAt = createdAt
    }

    convenience init(from exp: WordExplanation, scene: String = "", snapshot: Data? = nil) {
        self.init(
            word: exp.word,
            phonetic: exp.phonetic,
            partOfSpeech: exp.partOfSpeech,
            meanings: exp.meanings,
            contextPhrase: exp.contextPhrase,
            contextMeaning: exp.contextMeaning,
            scene: scene,
            snapshot: snapshot
        )
    }

    // Record another encounter: bump the count and stamp the time. Called when a
    // reunion actually fires (a word saved on an earlier day is pointed at again).
    func markSeenAgain() {
        seenCount += 1
        lastSeenAt = .now
    }

    // The most recent time this word was seen, safe for display. Rows migrated from
    // before lastSeenAt existed carry the .distantPast default; for those we fall
    // back to createdAt so the reunion banner never shows "decades ago".
    var effectiveLastSeen: Date {
        lastSeenAt == .distantPast ? createdAt : lastSeenAt
    }

    // ── Footprint grouping ────────────────────────────────────────────────────

    // The place label for the footprint group: the GPS city if we have one, else
    // the AI venue category, else "" so the caller shows "未知地点". This returns the
    // RAW venue (a language-neutral code for new saves); callers that show it to the
    // user localize via AppLanguage.venueName(_:). Kept for the footprintKey and
    // non-localized needs.
    var placeName: String {
        if !placeCity.isEmpty { return placeCity }
        if !venue.isEmpty { return venue }
        return ""
    }

    // The leading icon for the group — the stored venue emoji, else one derived
    // from the venue code (covers rows saved without an emoji), else a neutral pin.
    var placeEmoji: String {
        if !venueEmoji.isEmpty { return venueEmoji }
        return VenueCatalog.emoji(for: venue)
    }

    // Stable identity for a "place + month" bucket. Independent of display language
    // so the same spot/month always coalesces. Month is keyed by year-month.
    func footprintKey(calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month], from: createdAt)
        let ym = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
        // Group by CITY when known, otherwise by venue, otherwise a shared unknown
        // bucket — matches placeName's precedence so the label always fits the key.
        let placeKey = !placeCity.isEmpty ? "city:\(placeCity)"
                     : !venue.isEmpty     ? "venue:\(venue)"
                     : "unknown"
        return "\(ym)|\(placeKey)"
    }

    // ── Encounter photo group, display-ready ──────────────────────────────────

    // All photos of this word, newest first, as flat WordPhotoItems. Merges the
    // relationship rows with the LEGACY single `snapshot` (words saved before
    // photo-grouping): if there are no WordPhoto rows we synthesize one item from
    // `snapshot` + the word's own place fields, so the grid always shows at least
    // the original capture and migrated data needs no special handling.
    var photoItems: [WordPhotoItem] {
        let rows = photos ?? []
        if rows.isEmpty {
            guard snapshot != nil else { return [] }
            return [WordPhotoItem(
                id: "legacy-\(word)",
                image: snapshot,
                createdAt: createdAt,
                placeCity: placeCity,
                venue: venue,
                venueEmoji: venueEmoji,
                scene: scene
            )]
        }
        return rows
            .sorted { $0.createdAt > $1.createdAt }
            .map { p in
                WordPhotoItem(
                    id: p.id,
                    image: p.image,
                    createdAt: p.createdAt,
                    placeCity: p.placeCity,
                    venue: p.venue,
                    venueEmoji: p.venueEmoji,
                    scene: p.scene
                )
            }
    }

    // How many encounter photos this word has — drives the "N 张" count and
    // whether "去回忆" opens a grid (>1) or a single detail.
    var photoCount: Int {
        let rows = photos ?? []
        if rows.isEmpty { return snapshot == nil ? 0 : 1 }
        return rows.count
    }
}
