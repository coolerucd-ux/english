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
        case .zhHant: return "我收藏的"
        case .zhHans: return "我收藏的"
        case .ko:     return "내 즐겨찾기"
        case .ja:     return "お気に入り"
        case .fr:     return "Mes favoris"
        case .es:     return "Mis favoritos"
        case .pt:     return "Meus favoritos"
        case .it:     return "I miei preferiti"
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
}

