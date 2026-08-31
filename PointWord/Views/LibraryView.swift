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

    // Fixed 3-per-row album — kept simple, no density switching.
    private let columns = 3
    private let spacing: CGFloat = 10

    var body: some View {
        NavigationStack {
            Group {
                if savedWords.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle(language.myWordsTitle)
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
            }
            .sheet(isPresented: $showLanguagePicker) {
                languagePicker
            }
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

    // MARK: - Album grid

    private var grid: some View {
        ScrollView {
            // Count subtitle under the large title, matching the mockup.
            HStack {
                Text(countText)
                    .font(.title3.weight(.medium))
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
        switch language {
        case .zhHant: return "\(savedWords.count) 個"
        case .zhHans: return "\(savedWords.count) 个"
        case .ko:     return "\(savedWords.count)개"
        case .ja:     return "\(savedWords.count) 個"
        default:      return "\(savedWords.count)"
        }
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
                    Text(item.word)
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
private struct WordDetailPager: View {
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

                Text(Self.stamp.string(from: item.createdAt))
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
