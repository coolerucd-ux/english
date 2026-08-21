import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \SavedWord.createdAt, order: .reverse) private var savedWords: [SavedWord]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appLanguage") private var languageRaw = AppLanguage.deviceDefault.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @State private var showLanguagePicker = false

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
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLanguagePicker = true
                    } label: {
                        // Lucide globe asset, sized to match the back chevron so
                        // both header glyphs read as one set.
                        Image("IconGlobe")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .sheet(isPresented: $showLanguagePicker) {
                languagePicker
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
                    NavigationLink {
                        WordDetailView(item: item, language: language)
                    } label: {
                        WordAlbumCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            context.delete(item)
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
            .overlay(alignment: .bottomLeading) {
                // Second-precision timestamp of when the word was saved.
                Text(Self.stamp.string(from: item.createdAt))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    // Shared formatter — building DateFormatter per cell is wasteful in a grid.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

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
        ScrollView {
            VStack(spacing: 16) {
                // The camera frame frozen at recognition, if we kept one.
                if let data = item.snapshot, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                // Same card the recognition result used. Tapping the ♥ here
                // un-saves the word — we then pop back to the library.
                WordCardView(
                    state: .loaded(explanation),
                    language: language,
                    onRemoved: { dismiss() }
                )

                // Full save time, to the second.
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(Self.stamp.string(from: item.createdAt))
                        .font(.system(.subheadline, design: .monospaced))
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .navigationTitle(item.word)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
