import Foundation
import SwiftData

// One encounter photo for a saved word. When the user meets a word again on a
// later day (the reunion path), another WordPhoto is appended — so a single
// SavedWord accumulates the whole set of "where / when I met this word" shots:
// its photo group. Each photo keeps its OWN place/scene so the group reads as a
// little travel log. Deleted with its owning word (cascade).
@Model
final class WordPhoto {
    // Stable id for display lists (WordPhotoItem) — survives store reordering.
    var id: String = UUID().uuidString
    @Attribute(.externalStorage) var image: Data?
    var createdAt: Date = Date.now
    // This sighting's place/scene — mirrors the SavedWord fields but captured per
    // photo, so every encounter keeps its own city/venue/scene. All optional;
    // filled by the same async VL + GPS enrichment the first save uses.
    var placeCity: String = ""
    var placeCountry: String = ""
    var venue: String = ""
    var venueEmoji: String = ""
    var scene: String = ""
    // Inverse of SavedWord.photos.
    var word: SavedWord?

    init(image: Data?,
         createdAt: Date = .now,
         placeCity: String = "",
         placeCountry: String = "",
         venue: String = "",
         venueEmoji: String = "",
         scene: String = "") {
        self.id = UUID().uuidString
        self.image = image
        self.createdAt = createdAt
        self.placeCity = placeCity
        self.placeCountry = placeCountry
        self.venue = venue
        self.venueEmoji = venueEmoji
        self.scene = scene
    }
}

// A flattened, display-ready encounter photo. It unifies real WordPhoto rows with
// the LEGACY single snapshot (words saved before photo-grouping existed), so the
// grid never has to special-case migrated data — it always gets at least the
// original capture.
struct WordPhotoItem: Identifiable {
    let id: String
    let image: Data?
    let createdAt: Date
    let placeCity: String
    let venue: String
    let venueEmoji: String
    let scene: String

    // Leading icon for a caption — the stored venue emoji, else one derived from
    // the venue code (covers rows saved without an emoji), else a neutral pin.
    var placeEmoji: String {
        if !venueEmoji.isEmpty { return venueEmoji }
        return VenueCatalog.emoji(for: venue)
    }

    // NOTE: the display "城市 · 场所" label is built by AppLanguage.placeLabel(city:
    // venue:) at the call site, NOT here — the venue must be localized to the
    // CURRENT language (it's stored as a language-neutral code), which needs the
    // active AppLanguage this model type doesn't carry.
}
