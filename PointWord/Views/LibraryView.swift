import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \SavedWord.createdAt, order: .reverse) private var savedWords: [SavedWord]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appLanguage") private var languageRaw = AppLanguage.deviceDefault.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @State private var showLanguagePicker = false
    // The saved word whose detail sheet is up. Non-nil → the detail slides up from
    // the bottom (a .sheet), replacing the old push-navigation. Driving it off the
    // item (not a Bool) means the sheet always renders the tapped word.
    @State private var detailItem: SavedWord? = nil

    #if DEBUG
    // DEBUG-only: opens the reunion design gallery as a real in-app sheet, and a
    // button to seed fake saved words so the collection/足迹 pages render populated
    // on a real device. Stripped entirely from release builds.
    @State private var showReunionGallery = false
    #endif

    // Which view of the collection is showing: the flat photo album (default) or
    // the 足迹 timeline that groups saves by place + month.
    private enum Mode: Hashable { case album, footprint }
    @State private var mode: Mode = .album
    // Drives the sliding highlight pill between the two bottom tabs.
    @Namespace private var tabPill

    // Fixed 3-per-row album — kept simple, no density switching.
    private let columns = 3
    private let spacing: CGFloat = 10

    var body: some View {
        NavigationStack {
            Group {
                if savedWords.isEmpty {
                    emptyState
                } else {
                    switch mode {
                    case .album:     grid
                    case .footprint: FootprintList(words: savedWords, language: language) { detailItem = $0 }
                    }
                }
            }
            // The content swaps INSTANTLY on tab change — no cross-fade between the
            // album grid and the footprint list (they're structurally different, so
            // an animated swap reads as a jump/flicker). Only the bottom pill slides.
            .animation(nil, value: mode)
            .navigationTitle(mode == .footprint ? language.footprintTitle : language.myWordsTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        // Lucide chevron-left (was the SF Symbol chevron.left). All
                        // header chrome icons — back, globe, close — are the SAME
                        // Lucide set: stroke-width 2, drawn at 28×28, so their line
                        // weight and size read identically. An SF Symbol here used a
                        // different stroke model and never matched.
                        Image("IconChevronLeft")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLanguagePicker = true
                    } label: {
                        // Lucide globe asset, 28×28 — matches the back chevron so
                        // both header glyphs read as one set.
                        Image("IconGlobe")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                }
                #if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    // DEBUG hammer: opens the reunion design gallery on-device.
                    Button {
                        showReunionGallery = true
                    } label: {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                #endif
            }
            // Album / 足迹 switch moved OUT of the nav bar to a floating tab bar
            // pinned at the BOTTOM — modeled on the Photos app 图库/精选集 bar
            // (icon + label, selected pill highlight) rather than a segmented
            // control, which never reads as native. safeAreaInset keeps it above
            // the home indicator and reserves room so the last grid row is never
            // hidden behind it. Only meaningful once something is saved.
            .safeAreaInset(edge: .bottom) {
                if !savedWords.isEmpty {
                    bottomTabBar
                }
            }
            .sheet(isPresented: $showLanguagePicker) {
                languagePicker
            }
            #if DEBUG
            .sheet(isPresented: $showReunionGallery) {
                ReunionDebugSheet(onSeed: {
                    ReunionSampleData.seed(into: context)
                    showReunionGallery = false
                })
            }
            #endif
            // Detail slides up from the bottom instead of pushing in. Full-height
            // so the letterboxed page + floating card have the same room they had
            // as a pushed screen. The visible drag indicator is the native cue that
            // this panel dismisses by dragging down — the standard iOS sheet feel.
            // Inside, a paged TabView lets the user swipe left/right through the
            // whole saved list without leaving the sheet, starting on the word they
            // tapped.
            .sheet(item: $detailItem) { item in
                WordDetailPager(words: savedWords, current: item, language: language)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
            }
        }
    }

    // MARK: - Bottom tab bar

    // Photos-app-style floating tab bar: two icon+label items inside a single
    // frosted capsule, the selected one wearing a lighter highlight pill. This
    // is what reads as "native iOS" (图库/精选集), not a segmented control.
    private var bottomTabBar: some View {
        HStack(spacing: 4) {
            tabButton(.album, label: language.albumTab, systemImage: "square.grid.2x2")
            tabButton(.footprint, label: language.footprintTab, systemImage: "map")
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.bottom, 6)
    }

    private func tabButton(_ target: Mode, label: String, systemImage: String) -> some View {
        let selected = mode == target
        return Button {
            guard mode != target else { return }
            // Slide the highlight pill smoothly; the CONTENT swap itself is NOT
            // animated (see .animation(nil) on the content Group) so two structurally
            // different views (album grid ↔ footprint list) don't cross-fade/jump.
            withAnimation(.snappy(duration: 0.28)) { mode = target }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: 84, height: 46)
            .background {
                if selected {
                    // matchedGeometryEffect makes the single pill glide between the
                    // two tabs instead of one popping out while the other pops in.
                    Capsule()
                        .fill(.white.opacity(0.14))
                        .matchedGeometryEffect(id: "tabHighlight", in: tabPill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Album grid

    private var grid: some View {
        ScrollView {
            // Count subtitle under the large title. Font matched to the footprint
            // group's place row (.headline) so the two tabs' secondary lines share
            // the same size and line height.
            HStack {
                Text(countText)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                spacing: spacing
            ) {
                ForEach(savedWords) { item in
                    Button {
                        detailItem = item
                    } label: {
                        WordAlbumCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            context.delete(item)
                            try? context.save()   // persist now so other @Query views (camera badge) update live
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var countText: String {
        language.collectionCount(savedWords.count)
    }

    // MARK: - Language picker

    private var languagePicker: some View {
        NavigationStack {
            List {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        languageRaw = lang.rawValue
                        showLanguagePicker = false
                    } label: {
                        HStack {
                            Text(lang.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if lang == language {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                }
            }
            .navigationTitle(language.languageTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(language.emptyTitle)
                .font(.title3.bold())
            Text(language.emptySubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Album card

// A single saved word rendered like a Photos tile: the captured page as the
// background, with the word + first meaning laid over the top on a dark scrim.
private struct WordAlbumCard: View {
    let item: SavedWord

    var body: some View {
        // A clear square drives the size from the grid cell WIDTH (aspectRatio
        // .fit, never .fill — .fill grows to the larger side and stretched the
        // tile into a tall column). Everything else rides in overlays that fill
        // this square and get clipped, so the image can't push the layout around.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { background }
            .overlay {
                // Dark gradient behind the text for legibility over any page.
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.05)],
                    startPoint: .top, endPoint: .center
                )
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.word.cleanedWord)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let first = item.meanings.first, !first.isEmpty {
                        // Default to showing just the first meaning, as requested.
                        Text(first)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var background: some View {
        if let data = item.snapshot, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            // No snapshot (e.g. older saves) — fall back to a neutral gradient.
            LinearGradient(
                colors: [Color(white: 0.3), Color(white: 0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Word detail pager

// Hosts the swipeable detail. A paged TabView lets the user flick left/right
// through the entire saved list without popping back to the grid; it opens on
// the tapped word. The close button lives HERE (not inside each page) so it
// stays pinned while the pages slide underneath.
//
// Internal (not private) so the camera screen's word-reunion "去回忆" can present
// the very same pager — the request was to reuse the collection interaction, not
// clone it. It's self-contained: hand it the word list + the one to open.
struct WordDetailPager: View {
    let words: [SavedWord]
    let current: SavedWord
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    // Which page is showing, tracked by the word's stable SwiftData id so the
    // binding survives list reordering (e.g. a word saved/removed elsewhere).
    @State private var selection: PersistentIdentifier

    init(words: [SavedWord], current: SavedWord, language: AppLanguage) {
        self.words = words
        self.current = current
        self.language = language
        _selection = State(initialValue: current.persistentModelID)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(words) { item in
                WordDetailView(item: item, language: language)
                    .tag(item.persistentModelID)
            }
        }
        // Horizontal paging with no index dots — the swipe itself is the cue, and
        // dots over a photo would clutter the clean look.
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Close button, top-left. Pinned at the pager level so it holds still while
        // pages slide. Same glassCapsule chrome + 28×28 glyph as the library header.
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image("IconClose")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundColor(.white)
                    .padding(9)
                    .glassCapsule(interactive: true)
                    .environment(\.colorScheme, .dark)
            }
            .padding(.top, 12)
            .padding(.leading, 16)
        }
    }
}

// MARK: - Word detail

// Tapping an album tile opens this. It rebuilds the recognition result from the
// saved fields and renders the exact same WordCardView (loaded state) the user
// saw at capture time — plus the captured page snapshot and a full timestamp.
private struct WordDetailView: View {
    let item: SavedWord
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    private var explanation: WordExplanation {
        WordExplanation(
            word: item.word,
            phonetic: item.phonetic,
            partOfSpeech: item.partOfSpeech,
            meanings: item.meanings,
            contextPhrase: item.contextPhrase,
            contextMeaning: item.contextMeaning
        )
    }

    // "地点位置 + 场所类型" caption shown before the timestamp: GPS city and AI
    // venue joined by "·", or just whichever one exists. nil when the row has
    // neither (old saves) — we then show only the time, no empty chip.
    private var placeLabel: String? {
        let city = item.placeCity
        let venue = item.venue
        switch (city.isEmpty, venue.isEmpty) {
        case (false, false): return "\(city) · \(venue)"
        case (false, true):  return city
        case (true, false):  return venue
        case (true, true):   return nil
        }
    }

    var body: some View {
        // Mirror the camera result layout: the captured page fills the
        // background and the word card floats over it, docked to the bottom —
        // no scrolling. The image keeps its real aspect ratio (never cropped),
        // so it letterboxes rather than filling edge to edge.
        ZStack(alignment: .bottom) {
            Group {
                if let data = item.snapshot, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    LinearGradient(
                        colors: [Color(white: 0.25), Color(white: 0.1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            // Bleed to the bottom/sides only. Leaving the TOP safe area alone keeps
            // the sheet's rounded corners + drag handle visible instead of a hard
            // black rectangle covering them — that flat full-bleed black was what
            // broke the native sheet look.
            .ignoresSafeArea(edges: [.bottom, .horizontal])

            // Floating bottom block: the word card, then the save time centered
            // just BELOW it. The timestamp reads as a quiet caption tucked under
            // the card — clear of the photo seam, centered in the gutter.
            VStack(spacing: 10) {
                WordCardView(
                    state: .loaded(explanation),
                    language: language,
                    onRemoved: { dismiss() }
                )

                // Caption row under the card: place (地点 + 场所) then the save time,
                // both tucked into one frosted chip. The place segment is dropped
                // for old saves that have neither city nor venue.
                HStack(spacing: 8) {
                    if let place = placeLabel {
                        HStack(spacing: 4) {
                            Text(item.placeEmoji)
                            Text(place)
                                .lineLimit(1)
                        }
                        Text("·")
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Text(Self.stamp.string(from: item.createdAt))
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassCapsule()
                .environment(\.colorScheme, .dark)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

// MARK: - Footprint timeline

// One "place + month" bucket of saves — e.g. 🗼 东京 · 2024年6月 · 6 个词. Newest
// save in the bucket drives its sort position (time-desc overall).
private struct FootprintGroup: Identifiable {
    let id: String            // the SavedWord.footprintKey
    let emoji: String
    let place: String         // city, or venue, or "" → caller shows 未知地点
    let month: Date           // any save's date; formatted to the month heading
    let words: [SavedWord]    // members, newest first
    var newest: Date { words.first?.createdAt ?? month }
}

// The 足迹 tab: a vertical list of place+month groups (newest first) with a header
// count and a footer summary. Tapping any word opens the SAME swipeable detail the
// album uses (handed back up via onSelect). Grouping is pure/derived — no new
// storage — so it always reflects the current saves.
private struct FootprintList: View {
    let words: [SavedWord]
    let language: AppLanguage
    var onSelect: (SavedWord) -> Void

    // Build the buckets once per render from the (already time-desc) word list.
    private var groups: [FootprintGroup] {
        let cal = Calendar.current
        var buckets: [String: [SavedWord]] = [:]
        var order: [String] = []
        for w in words {
            let key = w.footprintKey(calendar: cal)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(w)
        }
        // `words` is sorted newest-first, so each bucket's first element is its
        // newest save and `order` already reflects first-appearance = newest group.
        return order.map { key in
            let members = buckets[key] ?? []
            let head = members.first
            return FootprintGroup(
                id: key,
                emoji: head?.placeEmoji ?? "📍",
                place: head?.placeName ?? "",
                month: head?.createdAt ?? .now,
                words: members
            )
        }
        .sorted { $0.newest > $1.newest }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                ForEach(groups) { group in
                    FootprintGroupView(group: group, language: language, onSelect: onSelect)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

// A single footprint group: a header row (emoji + place + month + count) over the
// group's words. Default is a horizontal strip showing 3 tiles at a time that the
// user can swipe through; tapping the count chip expands it into a full vertical
// grid (and back). Reuses the album tile so a word looks identical in both tabs.
private struct FootprintGroupView: View {
    let group: FootprintGroup
    let language: AppLanguage
    var onSelect: (SavedWord) -> Void

    // Expanded = full vertical grid; collapsed = swipeable 3-up horizontal strip.
    @State private var expanded = false

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    // Only groups with more than one screenful (3) can expand / need swiping.
    private var canExpand: Bool { group.words.count > 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if expanded {
                // Everything, as a vertical 3-col grid.
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(group.words) { tile($0) }
                }
            } else {
                // Horizontal strip: 3 tiles fill the width, swipe for the rest.
                // containerRelativeFrame sizes each tile to 1/3 of the scroll width
                // (no UIScreen read); viewAligned snaps to tile boundaries.
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(group.words) { item in
                            tile(item)
                                .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 10)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    // Header: 🗼 东京   2024年6月            6 个词 ⌄
    private var header: some View {
        HStack(spacing: 8) {
            Text(group.emoji)
                .font(.title3)
            Text(group.place.isEmpty ? language.unknownPlace : group.place)
                .font(.headline)
                .foregroundColor(.primary)
            Text(language.monthLabel(group.month))
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            if canExpand {
                // Count doubles as the expand/collapse toggle when there's overflow.
                Button {
                    withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(language.footprintGroupCount(group.words.count))
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(language.footprintGroupCount(group.words.count))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: SavedWord) -> some View {
        Button {
            onSelect(item)
        } label: {
            // Reuse the collection card verbatim so a word looks identical in both
            // tabs — same English + first Chinese meaning overlay, same sizing.
            WordAlbumCard(item: item)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Word photo group ("去回忆" destination)

// Every encounter photo of ONE word, laid out as a 3-per-row album (newest
// first) with the word's card pinned on top — "我什么时候、在哪里遇见了这个词".
// Tapping a photo opens that sighting full-screen (swipeable across the group),
// each with its own place/time caption. Presented as a bottom sheet so it feels
// like the rest of the collection. Internal so the camera's reunion banner can
// present it directly.
struct WordPhotoGroupView: View {
    let word: SavedWord
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    @State private var openedPhoto: WordPhotoItem? = nil

    private let columns = 3
    private let spacing: CGFloat = 10

    private var items: [WordPhotoItem] { word.photoItems }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Word header — the same card the collection uses (compact).
                    WordCardView(
                        state: .loaded(WordExplanation(
                            word: word.word,
                            phonetic: word.phonetic,
                            partOfSpeech: word.partOfSpeech,
                            meanings: word.meanings,
                            contextPhrase: word.contextPhrase,
                            contextMeaning: word.contextMeaning
                        )),
                        language: language,
                        compact: true
                    )
                    .padding(.horizontal, 16)

                    HStack {
                        Text(language.photoGroupCount(items.count))
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                        spacing: spacing
                    ) {
                        ForEach(items) { photo in
                            Button {
                                openedPhoto = photo
                            } label: {
                                WordPhotoTile(photo: photo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle(word.word.cleanedWord)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image("IconClose")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                }
            }
        }
        // Full-screen swipeable per-photo detail, opening on the tapped shot.
        .fullScreenCover(item: $openedPhoto) { photo in
            WordPhotoPager(items: items, current: photo, word: word, language: language)
        }
    }
}

// One encounter photo as an album tile — the shot with its place/venue emoji
// pinned in the corner, matching the collection tile's shape.
private struct WordPhotoTile: View {
    let photo: WordPhotoItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let data = photo.image, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(photo.placeEmoji)
                    .font(.system(size: 15))
                    .padding(6)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// Swipeable full-screen viewer over a word's encounter photos — the same left/
// right paging feel the collection detail uses, but paging PHOTOS of one word.
// Each page mirrors the ordinary WordDetailView: the sighting's photo behind a
// floating word card (word / phonetic / meanings / 语境解释), capped with a
// caption chip carrying THIS photo's scene + place + time. So opening any shot
// from the group reads exactly like opening the word from the collection — just
// scoped to that one encounter.
private struct WordPhotoPager: View {
    let items: [WordPhotoItem]
    let current: WordPhotoItem
    let word: SavedWord
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String

    init(items: [WordPhotoItem], current: WordPhotoItem, word: SavedWord, language: AppLanguage) {
        self.items = items
        self.current = current
        self.word = word
        self.language = language
        _selection = State(initialValue: current.id)
    }

    // The word's explanation, rebuilt from the saved fields — identical to what
    // WordDetailView renders, so the card here matches the ordinary detail page.
    private var explanation: WordExplanation {
        WordExplanation(
            word: word.word,
            phonetic: word.phonetic,
            partOfSpeech: word.partOfSpeech,
            meanings: word.meanings,
            contextPhrase: word.contextPhrase,
            contextMeaning: word.contextMeaning
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(items) { photo in
                    photoPage(photo).tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))

            Button { dismiss() } label: {
                Image("IconClose")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundColor(.white)
                    .padding(9)
                    .glassCapsule(interactive: true)
                    .environment(\.colorScheme, .dark)
            }
            .padding(.top, 12)
            .padding(.leading, 16)
        }
    }

    private func photoPage(_ photo: WordPhotoItem) -> some View {
        // Same stack as WordDetailView: the sighting's page letterboxed behind a
        // floating word card, with the caption tucked just under it.
        ZStack(alignment: .bottom) {
            Group {
                if let data = photo.image, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().aspectRatio(contentMode: .fit)
                } else {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                // Full word card — word / phonetic / meanings / 语境解释 — the same
                // one the collection detail floats. Removing the word from here
                // dismisses the whole viewer, matching WordDetailView's onRemoved.
                WordCardView(
                    state: .loaded(explanation),
                    language: language,
                    onRemoved: { dismiss() }
                )

                // Caption chip for THIS sighting: scene (if any) + place + time. The
                // scene is what makes it "当前场景" — it belongs to the photo, not the
                // word, so each page can read differently ("地铁里的读物" vs "咖啡馆").
                captionChip(for: photo)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }

    // "场景 · Emoji 地点 · 时间" — segments dropped when absent so an old photo with
    // neither scene nor place still shows a clean time-only chip.
    @ViewBuilder
    private func captionChip(for photo: WordPhotoItem) -> some View {
        HStack(spacing: 8) {
            if !photo.scene.isEmpty {
                Text(photo.scene).lineLimit(1)
                Text("·").foregroundColor(.white.opacity(0.5))
            }
            if let place = photo.placeLabel {
                HStack(spacing: 4) {
                    Text(photo.placeEmoji)
                    Text(place).lineLimit(1)
                }
                Text("·").foregroundColor(.white.opacity(0.5))
            }
            Text(Self.stamp.string(from: photo.createdAt))
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
