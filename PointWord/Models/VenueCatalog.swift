import Foundation

// Venue is a LANGUAGE-NEUTRAL code, not a display string.
//
// The vision model used to name the venue directly in the user's current UI
// language ("书本", "도서관"), which froze it: switching the app language later
// still showed the old language, because the stored string never changed. Now the
// model returns a stable English code ("book", "library") and the UI localizes it
// on the fly via localizedVenue(_:) — so the label always follows the CURRENT
// language, and the footprint grouping key (which uses the code) stays stable
// across languages too.
//
// This catalog is the single source of truth for the code set: its emoji, its
// localized names, and a normalizer that also maps LEGACY stored strings (the old
// Chinese venues from before this change) back to a code, so data saved earlier
// still localizes instead of being stuck.
enum VenueCatalog {
    // The closed set the model must choose from, matching the old category list.
    static let codes = [
        "library", "subway", "bus", "airplane", "cafe", "restaurant", "book",
        "magazine", "billboard", "supermarket", "street", "office", "school", "museum"
    ]

    // One emoji per venue — the group's leading icon. Derived from the code so it's
    // deterministic and language-neutral (no longer relies on the model returning
    // an emoji). Unknown / empty → a neutral pin.
    static func emoji(for raw: String) -> String {
        switch normalize(raw) {
        case "library":     return "📚"
        case "subway":      return "🚇"
        case "bus":         return "🚌"
        case "airplane":    return "✈️"
        case "cafe":        return "☕"
        case "restaurant":  return "🍽️"
        case "book":        return "📖"
        case "magazine":    return "📰"
        case "billboard":   return "🪧"
        case "supermarket": return "🛒"
        case "street":      return "🏙️"
        case "office":      return "🏢"
        case "school":      return "🏫"
        case "museum":      return "🏛️"
        default:            return "📍"
        }
    }

    // Fold whatever we have — a fresh code from the model, or a legacy localized
    // string saved before this change — down to a canonical code. Returns nil when
    // it's empty or unrecognized (caller then shows the raw string / a pin).
    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return nil }
        if codes.contains(s) { return s }               // already a code

        switch s {
        // English synonyms the model might return off-list.
        case "metro", "underground":            return "subway"
        case "coffee", "coffee shop", "coffeehouse": return "cafe"
        case "plane", "flight":                 return "airplane"
        case "shop", "store", "market", "grocery": return "supermarket"
        case "road", "sidewalk", "outdoor":     return "street"
        case "newspaper":                       return "magazine"
        case "ad", "poster", "sign":            return "billboard"
        case "workplace":                       return "office"
        case "university", "campus", "classroom": return "school"
        case "gallery":                         return "museum"

        // Legacy stored venues (Simplified + Traditional Chinese) from before the
        // code switch, so already-saved rows localize instead of staying stuck.
        case "图书馆", "圖書館":                  return "library"
        case "地铁", "地鐵":                     return "subway"
        case "公交", "公車", "公交车", "公車站", "巴士": return "bus"
        case "飞机上", "飛機上", "飞机", "飛機":   return "airplane"
        case "咖啡馆", "咖啡館", "咖啡厅", "咖啡廳": return "cafe"
        case "餐厅", "餐廳":                     return "restaurant"
        case "书本", "書本", "书", "書", "书籍", "書籍": return "book"
        case "杂志", "雜誌":                     return "magazine"
        case "广告牌", "廣告牌", "海报", "海報":   return "billboard"
        case "超市", "超级市场", "超級市場":       return "supermarket"
        case "街道", "街上", "马路", "馬路":       return "street"
        case "办公室", "辦公室":                  return "office"
        case "学校", "學校":                     return "school"
        case "博物馆", "博物館":                  return "museum"
        default:                                return nil
        }
    }

    // The venue's display name in a given language, or nil when the code is unknown
    // (caller falls back to the raw stored string).
    static func name(_ raw: String, in language: AppLanguage) -> String? {
        guard let code = normalize(raw) else { return nil }
        switch code {
        case "library":     return t(language, "图书馆", "圖書館", "도서관", "図書館", "Bibliothèque", "Biblioteca", "Biblioteca", "Biblioteca")
        case "subway":      return t(language, "地铁", "地鐵", "지하철", "地下鉄", "Métro", "Metro", "Metrô", "Metropolitana")
        case "bus":         return t(language, "公交", "公車", "버스", "バス", "Bus", "Autobús", "Ônibus", "Autobus")
        case "airplane":    return t(language, "飞机上", "飛機上", "비행기", "機内", "Avion", "Avión", "Avião", "Aereo")
        case "cafe":        return t(language, "咖啡馆", "咖啡館", "카페", "カフェ", "Café", "Café", "Café", "Caffè")
        case "restaurant":  return t(language, "餐厅", "餐廳", "레스토랑", "レストラン", "Restaurant", "Restaurante", "Restaurante", "Ristorante")
        case "book":        return t(language, "书本", "書本", "책", "本", "Livre", "Libro", "Livro", "Libro")
        case "magazine":    return t(language, "杂志", "雜誌", "잡지", "雑誌", "Magazine", "Revista", "Revista", "Rivista")
        case "billboard":   return t(language, "广告牌", "廣告牌", "광고판", "看板", "Panneau", "Cartel", "Outdoor", "Cartellone")
        case "supermarket": return t(language, "超市", "超市", "마트", "スーパー", "Supermarché", "Supermercado", "Supermercado", "Supermercato")
        case "street":      return t(language, "街道", "街道", "거리", "街角", "Rue", "Calle", "Rua", "Strada")
        case "office":      return t(language, "办公室", "辦公室", "사무실", "オフィス", "Bureau", "Oficina", "Escritório", "Ufficio")
        case "school":      return t(language, "学校", "學校", "학교", "学校", "École", "Escuela", "Escola", "Scuola")
        case "museum":      return t(language, "博物馆", "博物館", "박물관", "博物館", "Musée", "Museo", "Museu", "Museo")
        default:            return nil
        }
    }

    // Positional lookup matching AppLanguage's case order:
    // zhHans, zhHant, ko, ja, fr, es, pt, it.
    private static func t(_ language: AppLanguage,
                          _ zhHans: String, _ zhHant: String, _ ko: String, _ ja: String,
                          _ fr: String, _ es: String, _ pt: String, _ it: String) -> String {
        switch language {
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        case .ko:     return ko
        case .ja:     return ja
        case .fr:     return fr
        case .es:     return es
        case .pt:     return pt
        case .it:     return it
        }
    }
}
