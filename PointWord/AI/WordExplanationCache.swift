import Foundation

// Disk-backed LRU cache for model word explanations.
//
// WHY: every finger-point fires streamLookup, and the model bills per call. The
// in-session dictionary on AIService already de-dupes "same word + same sentence +
// same language" within one run — but it lived only in memory, so every cold
// launch threw it away and the SAME word in the SAME sentence got re-queried. This
// persists that map to disk, so a word you've already seen is free forever (until
// evicted), not just until you quit.
//
// It lives in Caches/: regenerable model output, safe for iOS to purge under real
// storage pressure — worst case we just pay for that lookup again. Bounded to
// `capacity` newest-accessed entries so it can't grow without limit.
final class WordExplanationCache {
    // One stored record: the explanation plus when it was last read, for LRU.
    private struct Entry: Codable {
        let explanation: WordExplanation
        var accessedAt: Date
    }

    private let capacity: Int
    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    // Whole-file writes are coalesced onto this queue and debounced, so a burst of
    // lookups doesn't rewrite the file once per word.
    private let ioQueue = DispatchQueue(label: "WordExplanationCache.io", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init(capacity: Int = 3000, filename: String = "word-explanations.json") {
        self.capacity = capacity
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = base.appendingPathComponent(filename)
        // Load OFF the main thread. AIService is created during app launch; reading
        // and decoding a multi-thousand-entry JSON synchronously here would add a
        // few– to–tens of ms to first frame. Instead we start empty (a lookup during
        // the load window just reads as a miss — correct, no side effects) and merge
        // the disk map in on a background queue.
        load()
    }

    // Look up a cached explanation, refreshing its LRU timestamp on a hit.
    func value(for key: String) -> WordExplanation? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        entry.accessedAt = Date()
        entries[key] = entry
        return entry.explanation
    }

    // Store an explanation, evict the least-recently-used over capacity, and
    // schedule a debounced write. Only final (complete) results should be stored.
    func set(_ explanation: WordExplanation, for key: String) {
        lock.lock()
        entries[key] = Entry(explanation: explanation, accessedAt: Date())
        if entries.count > capacity {
            // Drop the oldest-accessed down to capacity. Cheap: runs rarely and only
            // once the map is already large.
            let overflow = entries.count - capacity
            let victims = entries.sorted { $0.value.accessedAt < $1.value.accessedAt }
                .prefix(overflow)
                .map(\.key)
            for k in victims { entries.removeValue(forKey: k) }
        }
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        ioQueue.async { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: self.fileURL),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
            self.lock.lock()
            // Non-destructive merge: anything written during the load window (a
            // lookup that already fetched and stored) WINS over the disk copy, so we
            // never clobber a fresher in-memory entry with a stale persisted one.
            self.entries.merge(decoded) { current, _ in current }
            self.lock.unlock()
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        // 2s debounce: absorbs a reading session's burst into one write.
        ioQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func saveNow() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
