import Foundation

// The learner's native language — what AI explanations and the UI are shown in.
// The word being looked up is always English; only the explanation语言 changes.
enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans   // 中文（简体）
    case zhHant   // 中文（繁體）
    case ko       // 한국어
    case ja       // 日本語
    case fr       // Français
    case es       // Español
    case pt       // Português
    case it       // Italiano

    var id: String { rawValue }

    // Native name shown in the picker.
    var displayName: String {
        switch self {
        case .zhHant: return "中文（繁體）"
        case .zhHans: return "中文（简体）"
        case .ko:     return "한국어"
        case .ja:     return "日本語"
        case .fr:     return "Français"
        case .es:     return "Español"
        case .pt:     return "Português"
        case .it:     return "Italiano"
        }
    }

    // How we tell the model which language to answer in.
    var promptName: String {
        switch self {
        case .zhHant: return "Traditional Chinese (繁體中文)"
        case .zhHans: return "Simplified Chinese (简体中文)"
        case .ko:     return "Korean (한국어)"
        case .ja:     return "Japanese (日本語)"
        case .fr:     return "French (Français)"
        case .es:     return "Spanish (Español)"
        case .pt:     return "Portuguese (Português)"
        case .it:     return "Italian (Italiano)"
        }
    }

    // First-launch default: match the device's preferred language, else Simplified Chinese.
    static var deviceDefault: AppLanguage {
        for id in Locale.preferredLanguages {
            let l = id.lowercased()
            if l.contains("hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo") { return .zhHant }
            if l.hasPrefix("zh") { return .zhHans }
            if l.hasPrefix("ko") { return .ko }
            if l.hasPrefix("ja") { return .ja }
            if l.hasPrefix("fr") { return .fr }
            if l.hasPrefix("es") { return .es }
            if l.hasPrefix("pt") { return .pt }
            if l.hasPrefix("it") { return .it }
        }
        return .zhHans
    }

    // MARK: - Localized UI strings

    var scanTab: String {
        switch self {
        case .zhHant: return "掃描"
        case .zhHans: return "扫描"
        case .ko:     return "스캔"
        case .ja:     return "スキャン"
        case .fr:     return "Scanner"
        case .es:     return "Escanear"
        case .pt:     return "Digitalizar"
        case .it:     return "Scansiona"
        }
    }

    var myWordsTitle: String {
        switch self {
        case .zhHant: return "收藏"
        case .zhHans: return "收藏"
        case .ko:     return "내 즐겨찾기"
        case .ja:     return "お気に入り"
        case .fr:     return "Mes favoris"
        case .es:     return "Mis favoritos"
        case .pt:     return "Meus favoritos"
        case .it:     return "I miei preferiti"
        }
    }

    // Shown as the large title when the 足迹 tab is selected.
    var footprintTitle: String {
        switch self {
        case .zhHant: return "足跡"
        case .zhHans: return "足迹"
        case .ko:     return "발자취"
        case .ja:     return "足あと"
        case .fr:     return "Parcours"
        case .es:     return "Recorrido"
        case .pt:     return "Trajeto"
        case .it:     return "Percorso"
        }
    }

    var loadingWord: String {
        switch self {
        case .zhHant: return "查詢中…"
        case .zhHans: return "查询中…"
        case .ko:     return "검색 중…"
        case .ja:     return "検索中…"
        case .fr:     return "Recherche…"
        case .es:     return "Buscando…"
        case .pt:     return "Procurando…"
        case .it:     return "Ricerca…"
        }
    }

    var lookupFailed: String {
        switch self {
        case .zhHant: return "查詢失敗，請重試"
        case .zhHans: return "查询失败，请重试"
        case .ko:     return "검색 실패, 다시 시도하세요"
        case .ja:     return "検索に失敗しました。再試行してください"
        case .fr:     return "Échec, veuillez réessayer"
        case .es:     return "Error, inténtalo de nuevo"
        case .pt:     return "Falha, tente novamente"
        case .it:     return "Errore, riprova"
        }
    }

    // Small badge on a card whose meaning came from the bundled offline
    // dictionary (no-network fallback), not the online contextual AI.
    var offlineBadge: String {
        switch self {
        case .zhHant: return "離線釋義"
        case .zhHans: return "离线释义"
        case .ko:     return "오프라인 뜻"
        case .ja:     return "オフライン語義"
        case .fr:     return "Hors ligne"
        case .es:     return "Sin conexión"
        case .pt:     return "Offline"
        case .it:     return "Offline"
        }
    }

    var currentContext: String {
        switch self {
        case .zhHant: return "目前語境"
        case .zhHans: return "当前语境"
        case .ko:     return "현재 문맥"
        case .ja:     return "この文脈では"
        case .fr:     return "Dans ce contexte"
        case .es:     return "En este contexto"
        case .pt:     return "Neste contexto"
        case .it:     return "In questo contesto"
        }
    }

    var swipeHint: String {
        switch self {
        case .zhHant: return "左右滑動查看"
        case .zhHans: return "左右滑动查看"
        case .ko:     return "좌우로 밀어 보기"
        case .ja:     return "左右にスワイプ"
        case .fr:     return "Glissez pour voir"
        case .es:     return "Desliza para ver"
        case .pt:     return "Deslize para ver"
        case .it:     return "Scorri per vedere"
        }
    }

    var emptyTitle: String {
        switch self {
        case .zhHant: return "還沒有收藏單詞"
        case .zhHans: return "还没有收藏单词"
        case .ko:     return "저장된 단어가 없어요"
        case .ja:     return "まだ保存した単語がありません"
        case .fr:     return "Aucun mot enregistré"
        case .es:     return "Aún no hay palabras"
        case .pt:     return "Ainda não há palavras"
        case .it:     return "Nessuna parola salvata"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .zhHant: return "查詢後點收藏，就會出現在這裡"
        case .zhHans: return "查词后点收藏，就会出现在这里"
        case .ko:     return "검색 후 별표를 누르면 여기에 표시돼요"
        case .ja:     return "検索後にスターを押すとここに表示されます"
        case .fr:     return "Touchez l'étoile après une recherche"
        case .es:     return "Toca la estrella tras buscar"
        case .pt:     return "Toque na estrela após buscar"
        case .it:     return "Tocca la stella dopo la ricerca"
        }
    }

    var languageTitle: String {
        switch self {
        case .zhHant: return "解釋語言"
        case .zhHans: return "解释语言"
        case .ko:     return "설명 언어"
        case .ja:     return "説明の言語"
        case .fr:     return "Langue d'explication"
        case .es:     return "Idioma de explicación"
        case .pt:     return "Idioma da explicação"
        case .it:     return "Lingua di spiegazione"
        }
    }

    // MARK: - Onboarding strings

    // Shown on the very first launch, above the language list. English on purpose:
    // the user hasn't picked a language yet, and English is universal here.
    var onboardingTitle: String { "What's your native language?" }

    var continueButton: String {
        switch self {
        case .zhHant: return "繼續"
        case .zhHans: return "继续"
        case .ko:     return "계속"
        case .ja:     return "続ける"
        case .fr:     return "Continuer"
        case .es:     return "Continuar"
        case .pt:     return "Continuar"
        case .it:     return "Continua"
        }
    }

    var permissionTitle: String {
        switch self {
        case .zhHant: return "開啟相機與網路"
        case .zhHans: return "开启相机与网络"
        case .ko:     return "카메라와 네트워크 허용"
        case .ja:     return "カメラとネットワークを許可"
        case .fr:     return "Autoriser caméra et réseau"
        case .es:     return "Permitir cámara y red"
        case .pt:     return "Permitir câmera e rede"
        case .it:     return "Consenti fotocamera e rete"
        }
    }

    var permissionCamera: String {
        switch self {
        case .zhHant: return "相機：對準英文，即可識別單詞"
        case .zhHans: return "相机：对准英文，即可识别单词"
        case .ko:     return "카메라: 영어를 비추면 단어를 인식해요"
        case .ja:     return "カメラ：英語に向けると単語を認識します"
        case .fr:     return "Caméra : visez un texte anglais pour reconnaître les mots"
        case .es:     return "Cámara: apunta al inglés para reconocer palabras"
        case .pt:     return "Câmera: aponte para o inglês para reconhecer palavras"
        case .it:     return "Fotocamera: inquadra l'inglese per riconoscere le parole"
        }
    }

    var permissionNetwork: String {
        switch self {
        case .zhHant: return "網路：連接 AI 提供語境解釋"
        case .zhHans: return "网络：连接 AI 提供语境解释"
        case .ko:     return "네트워크: AI에 연결해 문맥 설명을 제공해요"
        case .ja:     return "ネットワーク：AIに接続して文脈の説明を提供します"
        case .fr:     return "Réseau : se connecte à l'IA pour les explications"
        case .es:     return "Red: se conecta a la IA para explicaciones"
        case .pt:     return "Rede: conecta-se à IA para explicações"
        case .it:     return "Rete: si connette all'IA per le spiegazioni"
        }
    }

    var allowButton: String {
        switch self {
        case .zhHant: return "允許並開始"
        case .zhHans: return "允许并开始"
        case .ko:     return "허용하고 시작"
        case .ja:     return "許可して開始"
        case .fr:     return "Autoriser et commencer"
        case .es:     return "Permitir y empezar"
        case .pt:     return "Permitir e começar"
        case .it:     return "Consenti e inizia"
        }
    }

    var moreResults: String {
        switch self {
        case .zhHant: return "更多結果"
        case .zhHans: return "更多结果"
        case .ko:     return "더 보기"
        case .ja:     return "他の結果"
        case .fr:     return "Plus de résultats"
        case .es:     return "Más resultados"
        case .pt:     return "Mais resultados"
        case .it:     return "Altri risultati"
        }
    }

    // Bottom hint shown while a word is being confirmed / recognized.
    var scanning: String {
        switch self {
        case .zhHant: return "正在辨識，請對準文字保持靜止…"
        case .zhHans: return "正在识别，请对准文字保持静止…"
        case .ko:     return "인식 중입니다. 글자를 향해 고정해 주세요…"
        case .ja:     return "認識中です。文字に向けて静止してください…"
        case .fr:     return "Reconnaissance… gardez le texte immobile"
        case .es:     return "Reconociendo… mantén el texto fijo"
        case .pt:     return "Reconhecendo… mantenha o texto imóvel"
        case .it:     return "Riconoscimento… tieni fermo il testo"
        }
    }

    // Idle guidance shown when the camera is live but nothing is being pointed
    // at yet — teaches the one core gesture (point at a word and hold) so the
    // screen never feels dead. Underline / circle recognition was removed, so the
    // copy no longer mentions it.
    var pointHint: String {
        switch self {
        case .zhHant: return "👆 用手指向想查的單字，停一下"
        case .zhHans: return "👆 用手指向想查的单词，停一下"
        case .ko:     return "👆 궁금한 단어를 손가락으로 가리키고 잠시 멈춰 보세요"
        case .ja:     return "👆 調べたい単語を指でさして、少し止めてください"
        case .fr:     return "👆 Pointez le mot voulu et maintenez un instant"
        case .es:     return "👆 Señala la palabra y mantén un instante"
        case .pt:     return "👆 Aponte para a palavra e segure um instante"
        case .it:     return "👆 Indica la parola e tieni fermo un istante"
        }
    }

    // Tap-to-retry label on a failed lookup card.
    var retry: String {
        switch self {
        case .zhHant: return "點擊重試"
        case .zhHans: return "点击重试"
        case .ko:     return "다시 시도"
        case .ja:     return "再試行"
        case .fr:     return "Réessayer"
        case .es:     return "Reintentar"
        case .pt:     return "Tentar de novo"
        case .it:     return "Riprova"
        }
    }

    // Bottom button on the locked result — return to live scanning.
    var rescan: String {
        switch self {
        case .zhHant: return "重新辨識"
        case .zhHans: return "重新识别"
        case .ko:     return "다시 인식"
        case .ja:     return "再認識"
        case .fr:     return "Rescanner"
        case .es:     return "Volver a escanear"
        case .pt:     return "Escanear de novo"
        case .it:     return "Scansiona di nuovo"
        }
    }

    // MARK: - Word reunion

    // The whole reunion banner as ONE natural sentence, e.g.
    // "👋 这是你第 4 次见它，最近是今年5月纽约的菜单". Folds the count, a friendly
    // calendar time (from reunionWhen), and the photo scene into a single line —
    // the banner is just this string + a chevron. When the scene caption is empty
    // (offline save / VL failure / old data) we drop it and only say when.
    func reunionLine(count: Int, when: String, scene: String) -> String {
        let s = scene.isEmpty
        switch self {
        case .zhHans: return s ? "👋 这是你第 \(count) 次见它，最近一次是\(when)"
                               : "👋 这是你第 \(count) 次见它，最近是\(when)\(scene)"
        case .zhHant: return s ? "👋 這是你第 \(count) 次見它，最近一次是\(when)"
                               : "👋 這是你第 \(count) 次見它，最近是\(when)\(scene)"
        case .ko:     return s ? "👋 \(count)번째 만남이에요 · \(when)"
                               : "👋 \(count)번째 만남이에요 · \(when) \(scene)"
        case .ja:     return s ? "👋 \(count) 回目の再会 · 前回は\(when)"
                               : "👋 \(count) 回目の再会 · 前回は\(when)\(scene)"
        case .fr:     return s ? "👋 \(count)ᵉ rencontre · vu \(when)"
                               : "👋 \(count)ᵉ rencontre · vu \(when), \(scene)"
        case .es:     return s ? "👋 \(count).ª vez · visto \(when)"
                               : "👋 \(count).ª vez · visto \(when), \(scene)"
        case .pt:     return s ? "👋 \(count).ª vez · visto \(when)"
                               : "👋 \(count).ª vez · visto \(when), \(scene)"
        case .it:     return s ? "👋 \(count)ª volta · visto \(when)"
                               : "👋 \(count)ª volta · visto \(when), \(scene)"
        }
    }

    // "when" piece for the reunion line — a friendly CALENDAR phrase (not "3天前"):
    // today / yesterday, else the month (this year) or year+month. The word being
    // saved on an earlier day is the trigger, so this is normally month-level.
    func reunionWhen(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            switch self {
            case .zhHans, .zhHant: return "今天"
            case .ko: return "오늘"; case .ja: return "今日"
            case .fr: return "aujourd'hui"; case .es: return "hoy"
            case .pt: return "hoje"; case .it: return "oggi"
            }
        }
        if cal.isDateInYesterday(date) {
            switch self {
            case .zhHans, .zhHant: return "昨天"
            case .ko: return "어제"; case .ja: return "昨日"
            case .fr: return "hier"; case .es: return "ayer"
            case .pt: return "ontem"; case .it: return "ieri"
            }
        }
        let sameYear = cal.isDate(date, equalTo: .now, toGranularity: .year)
        let df = DateFormatter()
        df.locale = Locale(identifier: localeIdentifier)
        df.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "yMMMM")
        let base = df.string(from: date)
        // zh reads more naturally with a "今年" lead-in for same-year months.
        if sameYear, self == .zhHans || self == .zhHant { return "今年" + base }
        return base
    }

    // Locale used to format the reunion calendar phrase above, so month/year names
    // follow the learner's chosen language, not the device locale.
    var localeIdentifier: String {
        switch self {
        case .zhHant: return "zh-Hant"
        case .zhHans: return "zh-Hans"
        case .ko:     return "ko"
        case .ja:     return "ja"
        case .fr:     return "fr"
        case .es:     return "es"
        case .pt:     return "pt"
        case .it:     return "it"
        }
    }

    // Formats the saved-word count for the top badge, localized (Plan A). Small
    // counts read exactly with a grouping separator (52089 → "52,089" / "52.089");
    // once they'd grow the always-visible pill, they collapse to the language's own
    // compact form (中文 "5.2万", en "52K") so the badge width stays stable and never
    // jitters as the tally climbs. Uses the learner's chosen language, not the
    // device locale, to match the rest of the UI.
    func badgeCount(_ n: Int) -> String {
        let locale = Locale(identifier: localeIdentifier)
        // Below 10k a plain grouped number is short enough and fully precise.
        if n < 10_000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = locale
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        // At/above 10k, use the OS compact notation ("5.2万", "52K", "52 mila") so a
        // six-plus-digit tally can't stretch the pill.
        return n.formatted(.number.notation(.compactName).locale(locale))
    }

    // MARK: - Footprints

    // Segmented tab labels on the collection screen: photo grid vs. footprint timeline.
    var albumTab: String {
        switch self {
        case .zhHant: return "收藏"
        case .zhHans: return "收藏"
        case .ko:     return "즐겨찾기"
        case .ja:     return "お気に入り"
        case .fr:     return "Favoris"
        case .es:     return "Favoritos"
        case .pt:     return "Favoritos"
        case .it:     return "Preferiti"
        }
    }

    var footprintTab: String {
        switch self {
        case .zhHant: return "足跡"
        case .zhHans: return "足迹"
        case .ko:     return "발자취"
        case .ja:     return "足あと"
        case .fr:     return "Parcours"
        case .es:     return "Recorrido"
        case .pt:     return "Trajeto"
        case .it:     return "Percorso"
        }
    }

    // Place label for saves with no city and no venue.
    var unknownPlace: String {
        switch self {
        case .zhHant: return "未知地點"
        case .zhHans: return "未知地点"
        case .ko:     return "알 수 없는 장소"
        case .ja:     return "場所不明"
        case .fr:     return "Lieu inconnu"
        case .es:     return "Lugar desconocido"
        case .pt:     return "Local desconhecido"
        case .it:     return "Luogo sconosciuto"
        }
    }

    // Localized venue name from a STORED venue value. The stored value is a
    // language-neutral code ("book") for new saves, or a legacy localized string
    // ("书本") for old ones — VenueCatalog folds both to the current language. Falls
    // back to the raw string for anything it can't map, and nil when empty. This is
    // what makes the footprint / detail place labels re-adapt on a language switch
    // instead of staying frozen in the capture-time language.
    func venueName(_ venue: String) -> String? {
        if let localized = VenueCatalog.name(venue, in: self) { return localized }
        let raw = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    // The "城市 · 场所" caption from stored fields, with the venue localized on the
    // fly. The city is shown in whatever language it was reverse-geocoded in at save
    // time (we don't keep coordinates to re-geocode). Returns nil when neither the
    // city nor a venue is known, so the caller shows a time-only chip.
    func placeLabel(city: String, venue: String) -> String? {
        let cityTrimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueName = self.venueName(venue) ?? ""
        switch (cityTrimmed.isEmpty, venueName.isEmpty) {
        case (false, false): return "\(cityTrimmed) · \(venueName)"
        case (false, true):  return cityTrimmed
        case (true, false):  return venueName
        case (true, true):   return nil
        }
    }

    // A group's month heading — "2024年6月" / "June 2024", localized.
    func monthLabel(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: localeIdentifier)
        df.setLocalizedDateFormatFromTemplate("yMMMM")
        return df.string(from: date)
    }

    // Warm subtitle under the collection title — "你已亲手遇见 47 个单词".
    func collectionCount(_ n: Int) -> String {
        switch self {
        case .zhHant: return "你已親手遇見 \(n) 個單字"
        case .zhHans: return "你已亲手遇见 \(n) 个单词"
        case .ko:     return "지금까지 단어 \(n)개를 만났어요"
        case .ja:     return "これまでに \(n) 語と出会いました"
        case .fr:     return n == 1 ? "Vous avez rencontré 1 mot" : "Vous avez rencontré \(n) mots"
        case .es:     return n == 1 ? "Has encontrado 1 palabra" : "Has encontrado \(n) palabras"
        case .pt:     return n == 1 ? "Você encontrou 1 palavra" : "Você encontrou \(n) palavras"
        case .it:     return n == 1 ? "Hai incontrato 1 parola" : "Hai incontrato \(n) parole"
        }
    }

    // A group's word-count chip — "6 个词" / "6 words".
    func footprintGroupCount(_ n: Int) -> String {
        switch self {
        case .zhHant: return "\(n) 個詞"
        case .zhHans: return "\(n) 个词"
        case .ko:     return "단어 \(n)개"
        case .ja:     return "\(n) 語"
        case .fr:     return n == 1 ? "1 mot" : "\(n) mots"
        case .es:     return n == 1 ? "1 palabra" : "\(n) palabras"
        case .pt:     return n == 1 ? "1 palavra" : "\(n) palavras"
        case .it:     return n == 1 ? "1 parola" : "\(n) parole"
        }
    }

    // Photo-group header — how many encounter shots of one word: "3 张照片".
    func photoGroupCount(_ n: Int) -> String {
        switch self {
        case .zhHant: return "\(n) 張照片"
        case .zhHans: return "\(n) 张照片"
        case .ko:     return "사진 \(n)장"
        case .ja:     return "写真 \(n) 枚"
        case .fr:     return n == 1 ? "1 photo" : "\(n) photos"
        case .es:     return n == 1 ? "1 foto" : "\(n) fotos"
        case .pt:     return n == 1 ? "1 foto" : "\(n) fotos"
        case .it:     return n == 1 ? "1 foto" : "\(n) foto"
        }
    }

    // Footer summary — "共 47 个词 · 3 个地点".
    func footprintSummary(words: Int, places: Int) -> String {
        switch self {
        case .zhHant: return "共 \(words) 個詞 · \(places) 個地點"
        case .zhHans: return "共 \(words) 个词 · \(places) 个地点"
        case .ko:     return "총 단어 \(words)개 · 장소 \(places)곳"
        case .ja:     return "計 \(words) 語 · \(places) か所"
        case .fr:     return "\(words) mots · \(places) lieux"
        case .es:     return "\(words) palabras · \(places) lugares"
        case .pt:     return "\(words) palavras · \(places) lugares"
        case .it:     return "\(words) parole · \(places) luoghi"
        }
    }

    // Empty-state line for the footprint tab before anything is grouped.
    var footprintEmpty: String {
        switch self {
        case .zhHant: return "開始收藏，走出你的英語足跡"
        case .zhHans: return "开始收藏，走出你的英语足迹"
        case .ko:     return "단어를 저장해 나만의 발자취를 남겨보세요"
        case .ja:     return "単語を保存して、英語の足あとを残そう"
        case .fr:     return "Enregistrez des mots pour tracer votre parcours"
        case .es:     return "Guarda palabras para trazar tu recorrido"
        case .pt:     return "Salve palavras para traçar seu trajeto"
        case .it:     return "Salva parole per tracciare il tuo percorso"
        }
    }

    // MARK: - Camera permission denied fallback

    var cameraDeniedTitle: String {
        switch self {
        case .zhHant: return "無法使用相機"
        case .zhHans: return "无法使用相机"
        case .ko:     return "카메라를 사용할 수 없어요"
        case .ja:     return "カメラを使用できません"
        case .fr:     return "Caméra indisponible"
        case .es:     return "Cámara no disponible"
        case .pt:     return "Câmera indisponível"
        case .it:     return "Fotocamera non disponibile"
        }
    }

    var cameraDeniedBody: String {
        switch self {
        case .zhHant: return "PointWord 需要相機才能識別單詞。請到「設定」開啟相機權限。"
        case .zhHans: return "PointWord 需要相机才能识别单词。请到「设置」开启相机权限。"
        case .ko:     return "PointWord는 단어 인식을 위해 카메라가 필요해요. 설정에서 카메라 권한을 켜 주세요."
        case .ja:     return "PointWord は単語認識のためにカメラが必要です。「設定」からカメラを許可してください。"
        case .fr:     return "PointWord a besoin de la caméra pour reconnaître les mots. Activez-la dans Réglages."
        case .es:     return "PointWord necesita la cámara para reconocer palabras. Actívala en Ajustes."
        case .pt:     return "O PointWord precisa da câmera para reconhecer palavras. Ative-a em Ajustes."
        case .it:     return "PointWord ha bisogno della fotocamera per riconoscere le parole. Attivala in Impostazioni."
        }
    }

    var openSettings: String {
        switch self {
        case .zhHant: return "前往設定"
        case .zhHans: return "前往设置"
        case .ko:     return "설정 열기"
        case .ja:     return "設定を開く"
        case .fr:     return "Ouvrir Réglages"
        case .es:     return "Abrir Ajustes"
        case .pt:     return "Abrir Ajustes"
        case .it:     return "Apri Impostazioni"
        }
    }

    // Label for the in-app privacy-policy link. Apple 5.1.1(i) requires the policy
    // to be reachable INSIDE the app (not only in App Store metadata) for any app
    // that collects data — PointWord uses camera + location, so we surface it in
    // the language sheet's footer.
    var privacyPolicy: String {
        switch self {
        case .zhHant: return "隱私政策"
        case .zhHans: return "隐私政策"
        case .ko:     return "개인정보 처리방침"
        case .ja:     return "プライバシーポリシー"
        case .fr:     return "Politique de confidentialité"
        case .es:     return "Política de privacidad"
        case .pt:     return "Política de Privacidade"
        case .it:     return "Informativa sulla privacy"
        }
    }

    // The hosted policy (GitHub Pages). One page holds all 8 languages as stacked
    // sections; the per-language anchor deep-links straight to the reader's own
    // section so they never land on a language they can't read. English is first,
    // then the eight supported languages in picker order.
    var privacyPolicyURL: URL {
        let anchor: String
        switch self {
        case .zhHans: anchor = "zh-hans"
        case .zhHant: anchor = "zh-hant"
        case .ko:     anchor = "ko"
        case .ja:     anchor = "ja"
        case .fr:     anchor = "fr"
        case .es:     anchor = "es"
        case .pt:     anchor = "pt"
        case .it:     anchor = "it"
        }
        return URL(string: "https://coolerucd-ux.github.io/english/privacy.html#\(anchor)")!
    }
}

