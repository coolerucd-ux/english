import Foundation
import Vision
import CoreVideo
import CoreGraphics

// Three detection paths, run in priority order each frame:
//   1. Colored mark (HSV saturation) — any colored pen/highlighter, fast & reliable.
//   2. Underline strip scan (pixel density below OCR baselines) — black/pencil underlines.
//   3. Circle contour detection (VNDetectContoursRequest + word-inside check) — black/pencil circles.
//
// Coordinate mapping — camera delivers landscape BGRA frames (W=1280, H=720),
// but OCR / hand-pose / contour requests all run with orientation .right, so
// Vision coords are UPRIGHT-PORTRAIT normalized (bottom-left origin). The .right
// rotation (landscape rotated 90° clockwise to stand upright) makes the mapping:
//     lx = (1 - vision_y) * W        ly = (1 - vision_x) * H
//   Inverse: vision_x = 1 - ly / H,  vision_y = 1 - lx / W
// (An earlier version dropped the "1 -" on both axes — a 180° flip — so every
//  underline strip was sampled at the point-reflected spot on the page, landing
//  on unrelated body text and mis-marking words all over the frame.)
class ColorMarkService {

    private let contourRequest: VNDetectContoursRequest = {
        let req = VNDetectContoursRequest()
        req.detectsDarkOnLight = true
        req.maximumImageDimension = 512
        return req
    }()

    private var frameIndex = 0

    // Circle detection is heavy, so it only runs every 3rd frame. But the mark
    // stabilizer upstream requires the WHOLE set of marks to keep an identical
    // position signature for 0.4s before it publishes. If circles appeared only
    // on every 3rd frame, the set composition would flip every frame
    // (underline-only ↔ underline+circle), resetting that timer forever — so a
    // circle could never stabilize into a card. We cache the last circle result
    // and replay it on the in-between frames, keeping the set stable. Max
    // staleness is ~2 frames (~70ms), refreshed whenever the path actually runs.
    private var cachedCircles: [ColorMark] = []

    // Returns all marks found on the page this frame (multiple underlines / circles).
    func detectAll(in pixelBuffer: CVPixelBuffer, words: [DetectedWord]) -> [ColorMark] {
        frameIndex += 1

        var marks: [ColorMark] = []

        // Path 1: colored marks (highlighter / colored pen)
        if let colored = detectColoredMark(in: pixelBuffer, words: words) {
            marks.append(colored)
        }

        // Path 2: black/pencil underlines — collect every underlined line
        marks.append(contentsOf: detectBlackUnderlines(in: pixelBuffer, words: words))

        // Path 3: circle contours are heavier; run every 3 frames, but replay the
        // cached result on the in-between frames so the mark set stays stable
        // enough to satisfy the 0.4s stabilizer (see cachedCircles above).
        if frameIndex % 3 == 0 {
            cachedCircles = detectBlackCircles(in: pixelBuffer, words: words)
        }
        marks.append(contentsOf: cachedCircles)

        // De-duplicate marks that cover the same words
        var seen = Set<String>()
        var unique: [ColorMark] = []
        for m in marks {
            let key = m.words.map { $0.text }.joined(separator: "|")
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(m)
        }
        return unique
    }

    // Backward-compatible single-mark entry (highest priority mark).
    func detect(in pixelBuffer: CVPixelBuffer, words: [DetectedWord]) -> ColorMark? {
        detectAll(in: pixelBuffer, words: words).first
    }

    // MARK: - Path 1: Colored pen (HSV saturation ≥ 0.35)

    private func detectColoredMark(in pixelBuffer: CVPixelBuffer, words: [DetectedWord]) -> ColorMark? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let W = CVPixelBufferGetWidth(pixelBuffer)
        let H = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let buf = base.assumingMemoryBound(to: UInt8.self)

        let step = 8
        var minLX = W, maxLX = 0, minLY = H, maxLY = 0, count = 0

        for ly in stride(from: 0, to: H, by: step) {
            for lx in stride(from: 0, to: W, by: step) {
                let off = ly * bpr + lx * 4
                let b = Float(buf[off]) / 255
                let g = Float(buf[off+1]) / 255
                let r = Float(buf[off+2]) / 255
                guard isHighSaturation(r: r, g: g, b: b) else { continue }
                if lx < minLX { minLX = lx }; if lx > maxLX { maxLX = lx }
                if ly < minLY { minLY = ly }; if ly > maxLY { maxLY = ly }
                count += 1
            }
        }

        guard count >= 50 else { return nil }

        let lW = maxLX - minLX, lH = maxLY - minLY

        // A real highlighter stroke is a COMPACT, DENSELY colored blob sitting on
        // a word or a short line. The old code took the bounding box of EVERY
        // saturated pixel in the frame, so a colored book cover / warm lighting /
        // a logo made that box span the whole page — and every word inside it got
        // swept into one giant "phrase" (the "all words translated together" bug
        // that also pre-empted finger pointing). Two guards kill it:
        //   1. size — the blob must not cover most of the frame.
        //   2. density — the blob's own bounding box must be mostly filled with
        //      color. Scattered colored text/logos give a large but SPARSE box.
        guard Float(lW) / Float(W) < 0.85, Float(lH) / Float(H) < 0.85 else { return nil }

        let boxCells = max(1, (lW / step + 1) * (lH / step + 1))
        guard Float(count) / Float(boxCells) >= 0.35 else { return nil }

        // Landscape-pixel blob → Vision box. Inverse of the .right mapping:
        //   vx = 1 - ly/H,  vy = 1 - lx/W.
        let vBox = CGRect(
            x: 1 - CGFloat(maxLY) / CGFloat(H),
            y: 1 - CGFloat(maxLX) / CGFloat(W),
            width: CGFloat(maxLY - minLY) / CGFloat(H),
            height: CGFloat(maxLX - minLX) / CGFloat(W)
        )
        return buildMark(visionBox: vBox, landscapeW: lW, landscapeH: lH, words: words)
    }

    private func isHighSaturation(r: Float, g: Float, b: Float) -> Bool {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let s = maxC > 0 ? (maxC - minC) / maxC : 0
        return s > 0.35 && maxC > 0.15 && maxC < 0.97
    }

    // MARK: - Path 2: Black pen / pencil underline (per-WORD strip scan)
    //
    // A hand-drawn underline is a dark stripe under one or a few adjacent words —
    // NOT the whole text line. The previous version scanned a line end-to-end and
    // returned every word on it, so underlining a single word swept the entire
    // sentence (and, on a tilted page whose words mis-cluster into one big "line",
    // half the page) into one scrambled phrase. It also demanded ≥55% coverage of
    // the whole line, so underlining just one word fell below threshold and read
    // as nothing.
    //
    // Now we test EACH word on its own: is the thin strip just below THAT word
    // markedly darker than the clean paper just above it? Then we keep only the
    // run of adjacent underlined words and emit that as the mark. Underline one
    // word → one word; underline a short phrase → those words; never the line.
    private func detectBlackUnderlines(in pixelBuffer: CVPixelBuffer, words: [DetectedWord]) -> [ColorMark] {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return [] }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let W = CVPixelBufferGetWidth(pixelBuffer)
        let H = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let buf = base.assumingMemoryBound(to: UInt8.self)

        // Luma at a landscape pixel (clamped), or nil if out of bounds.
        func luma(_ lx: Int, _ ly: Int) -> Float? {
            guard lx >= 0, lx < W, ly >= 0, ly < H else { return nil }
            let off = ly * bpr + lx * 4
            let b = Float(buf[off]) / 255
            let g = Float(buf[off + 1]) / 255
            let r = Float(buf[off + 2]) / 255
            return 0.299 * r + 0.587 * g + 0.114 * b
        }

        var found: [ColorMark] = []

        // One page-wide tilt estimate drives BOTH line grouping and the rotated
        // sampling basis below, so a slanted sheet is read along its true text
        // direction instead of an axis-aligned strip that drifts off the line.
        let slope = pageTextSlope(words)

        for lineWords in groupIntoTextLines(words, slope: slope) {
            guard !lineWords.isEmpty else { continue }

            // Left-to-right so an adjacent underlined run reads in order.
            let ordered = lineWords.sorted { $0.boundingBox.minX < $1.boundingBox.minX }

            // Decide, per word, whether it is underlined.
            let underlined = ordered.map { isWordUnderlined($0, slope: slope, W: W, H: H, luma: luma) }

            // Extract every maximal run of consecutive underlined words and emit
            // each as its own mark. A single underlined word yields a 1-word mark.
            var i = 0
            while i < ordered.count {
                guard underlined[i] else { i += 1; continue }
                var j = i
                while j + 1 < ordered.count && underlined[j + 1] { j += 1 }

                let segment = Array(ordered[i...j])
                // Cap the run so a stray dark row under a whole line can't sweep it
                // all in — a real underline marks a word or short phrase.
                if segment.count <= 6 {
                    let minX = segment.map { $0.boundingBox.minX }.min() ?? 0
                    let maxX = segment.map { $0.boundingBox.maxX }.max() ?? 1
                    let baseY = segment.map { $0.boundingBox.minY }.min() ?? 0
                    let box = CGRect(x: minX, y: max(0, baseY - 0.02),
                                     width: maxX - minX, height: 0.02)
                    found.append(ColorMark(markType: .underline, boundingBox: box, words: segment))
                }
                i = j + 1
            }
        }
        return found
    }

    // True when the thin strip just below a single word is clearly darker than the
    // clean paper just above it, along a continuous run FOLLOWING THE TEXT LINE.
    //
    // Tilt handling: rather than scan an axis-aligned pixel strip (which drifts off
    // a rotated word and clips neighbouring glyphs — every failing screenshot was a
    // steeply angled sheet), we build the sampling grid in VISION space along two
    // basis vectors derived from the page's text slope:
    //   • u = along the text line (unit, +x-ish)         → columns
    //   • n = the page-down normal (perpendicular to u)   → the below/above offset
    // Each (col, offset) sample point is a Vision-space CGPoint, mapped to a
    // landscape pixel through the module's .right convention (lx=(1-vy)·W,
    // ly=(1-vx)·H). slope = d(vision_y)/d(vision_x) of the text baseline; slope 0
    // reproduces the old axis-aligned behaviour exactly (zero-tilt regression-safe).
    private func isWordUnderlined(
        _ word: DetectedWord, slope: CGFloat, W: Int, H: Int,
        luma: (Int, Int) -> Float?
    ) -> Bool {
        let bb = word.boundingBox
        let wordW = max(0.001, bb.width)
        let wordH = max(0.01, bb.height)

        // Text-line direction u and the page-DOWN normal n, in Vision space.
        //   u = (1, slope) — NOT normalized: marching u·(wordW·t) spans exactly the
        //       word's x-width while rising with the baseline, so t∈[0,1] walks the
        //       whole word along its true (tilted) baseline.
        //   n = unit perpendicular pointing toward smaller y (below the text), so a
        //       positive offset along n steps under the word; a negative one steps
        //       above it. slope 0 → u=(1,0), n=(0,-1): the old axis-aligned behaviour.
        let uLen = sqrt(1 + slope * slope)
        let u = CGVector(dx: 1, dy: slope)
        let n = CGVector(dx: slope / uLen, dy: -1 / uLen)

        // March along the word from its left to right edge. Two anchor rows follow
        // the tilt: the BOTTOM edge (baseline) for the underline strip and the
        // clean-paper check below it, and the TOP edge for the background band
        // above the glyphs. Both walk along u so they stay on the rotated word.
        let bottomAnchor = CGPoint(x: bb.minX, y: bb.minY)
        let topAnchor    = CGPoint(x: bb.minX, y: bb.maxY)
        let cols = max(4, Int(wordW / 0.004))          // ~one sample per 0.4% width

        // Map a Vision point to a landscape pixel (.right convention).
        func lumaAt(_ p: CGPoint) -> Float? {
            let lx = Int((1 - p.y) * CGFloat(W))
            let ly = Int((1 - p.x) * CGFloat(H))
            return luma(lx, ly)
        }

        // Offsets (along n, i.e. downward) for the three bands we test, expressed
        // as Vision-space distances. These mirror the old strip geometry.
        let stripNear: CGFloat = 0.002
        let stripFar  = min(0.028, wordH * 0.55)
        let bgNear: CGFloat = 0.004                    // just ABOVE the word top (−n)
        let bgFar   = min(0.028, wordH * 0.55)
        let belowNear = stripFar + 0.004               // clean-paper check further down
        let belowFar  = stripFar + min(0.024, wordH * 0.5)

        // A Vision-space step for offset sampling that stays fine on screen.
        let offStep: CGFloat = 0.0035

        // 1. Clean background band ABOVE the word top (no glyphs) → local paper
        //    level. Anchored at the top edge, stepping in −n (upward).
        var bgSum: Float = 0, bgSumSq: Float = 0, bgN = 0
        var off = bgNear
        while off <= bgFar {
            for c in stride(from: 0, through: cols, by: 1) {
                let t = CGFloat(c) / CGFloat(cols)
                let base = CGPoint(x: topAnchor.x + u.dx * wordW * t,
                                   y: topAnchor.y + u.dy * wordW * t)
                let p = CGPoint(x: base.x - n.dx * off, y: base.y - n.dy * off)
                if let l = lumaAt(p) { bgSum += l; bgSumSq += l * l; bgN += 1 }
            }
            off += offStep
        }
        let bgLuma = bgN > 0 ? bgSum / Float(bgN) : 0.5
        let bgVar  = bgN > 0 ? max(0, bgSumSq / Float(bgN) - bgLuma * bgLuma) : 1
        let bgStd  = sqrt(bgVar)

        // Bail on paper that's too dark or too busy to judge reliably (floor kept
        // generous so a dim/bluish photo of white paper still qualifies).
        guard bgLuma >= 0.22, bgStd <= 0.18 else { return false }

        // A stroke pixel is modestly darker than local paper (faint pencil counts;
        // continuity below rejects noise).
        let darkCut = min(bgLuma * 0.82, bgLuma - 0.07)

        // 2. Underline strip just below the baseline. Scan column-by-column ALONG
        //    the line; a column is "dark" if any sample within the strip depth is
        //    below darkCut. Require broad coverage AND a long continuous run.
        var maxRun = 0, run = 0, hitCols = 0, totalCols = 0
        for c in stride(from: 0, through: cols, by: 1) {
            totalCols += 1
            let t = CGFloat(c) / CGFloat(cols)
            let base = CGPoint(x: bottomAnchor.x + u.dx * wordW * t,
                               y: bottomAnchor.y + u.dy * wordW * t)
            var columnDark = false
            var d = stripNear
            while d <= stripFar {
                let p = CGPoint(x: base.x + n.dx * d, y: base.y + n.dy * d)
                if let l = lumaAt(p), l < darkCut { columnDark = true; break }
                d += offStep
            }
            if columnDark {
                hitCols += 1
                run += 1
                if run > maxRun { maxRun = run }
            } else {
                run = 0
            }
        }

        guard totalCols > 0 else { return false }
        let coverage = Float(hitCols) / Float(totalCols)
        let continuity = Float(maxRun) / Float(totalCols)
        // Real underline: dark under MOST of the word AND a long unbroken run.
        // Precision over recall: better to miss than mismark.
        guard coverage > 0.7 && continuity > 0.72 else { return false }

        // 3. Reject SHADOW EDGES masquerading as underlines. A drawn line is THIN:
        //    paper returns to full brightness just below it. A shadow boundary keeps
        //    getting darker below — a region, not a line. Sample a band further down
        //    (still along n): for a real underline it's clean paper near bgLuma.
        var belowSum: Float = 0, belowN = 0
        var bd = belowNear
        while bd <= belowFar {
            for c in stride(from: 0, through: cols, by: 1) {
                let t = CGFloat(c) / CGFloat(cols)
                let base = CGPoint(x: bottomAnchor.x + u.dx * wordW * t,
                                   y: bottomAnchor.y + u.dy * wordW * t)
                let p = CGPoint(x: base.x + n.dx * bd, y: base.y + n.dy * bd)
                if let l = lumaAt(p) { belowSum += l; belowN += 1 }
            }
            bd += offStep
        }
        if belowN > 0 {
            let belowLuma = belowSum / Float(belowN)
            // Paper below the line must recover toward background brightness.
            guard belowLuma >= bgLuma * 0.72 else { return false }
        }

        return true
    }

    // MARK: - Path 3: Black pen / pencil circle (contour + word-inside verification)
    //
    // Finds roughly circular or oval contours.
    // Validates by checking that OCR words exist inside the contour's bounding box.
    // This positional check eliminates false positives from printed borders and shapes.

    private func detectBlackCircles(in pixelBuffer: CVPixelBuffer, words: [DetectedWord]) -> [ColorMark] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        guard (try? handler.perform([contourRequest])) != nil,
              let results = contourRequest.results else { return [] }

        var found: [ColorMark] = []

        for observation in results {
            for contour in observation.topLevelContours {
                let box = contour.normalizedPath.boundingBox
                let w = box.width, h = box.height
                guard w > 0, h > 0 else { continue }
                let aspect = w / h

                // Circle / oval ringing a word. A ring around a SINGLE word is
                // wide and flat in portrait space (the word is far wider than
                // tall), so its aspect runs high — the old ceiling of 2.2 threw
                // those away, which is why circling one word read as nothing.
                // Allow flat ovals but keep it BOUNDED — a hand-drawn ring is
                // small. Without an upper size bound the rounded body of a cup /
                // poster / card edge is itself a big oval contour that swallows
                // every word inside it (the "whole page went green" false positive).
                guard aspect > 0.4 && aspect < 4.5 else { continue }
                guard w > 0.05 && h > 0.025 else { continue }
                guard w < 0.6 && h < 0.32 else { continue }   // reject giant panel contours

                // Words whose center sits inside the ring.
                let wordsInside = words.filter {
                    box.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY))
                }
                guard !wordsInside.isEmpty else { continue }

                // A real ring circles a word or a short phrase — not a whole
                // paragraph. More than 3 words, or words spanning >1 text line,
                // means we grabbed a printed shape, not a mark. Bail out.
                guard wordsInside.count <= 3 else { continue }
                let ys = wordsInside.map { $0.boundingBox.midY }
                if let lo = ys.min(), let hi = ys.max(), hi - lo > 0.05 { continue }

                found.append(ColorMark(markType: .circle, boundingBox: box, words: wordsInside))
            }
        }
        return found
    }

    // MARK: - Helpers

    // Estimate the page's text tilt as a single slope = d(vision_y)/d(vision_x).
    // A flat page is ~0; a sheet rotated CCW in view gives a positive slope, CW a
    // negative one. We fit it robustly from the word boxes: pair each word with its
    // nearest same-row neighbour to the right and take the MEDIAN of their
    // centre-to-centre slopes. Median (not mean) shrugs off the odd cross-line pair
    // and OCR outliers, and pairing only near-horizontal neighbours keeps vertical
    // jumps between lines out of the estimate. Clamped to a sane hand-held range.
    private func pageTextSlope(_ words: [DetectedWord]) -> CGFloat {
        guard words.count >= 3 else { return 0 }

        var slopes: [CGFloat] = []
        for w in words {
            let c = CGPoint(x: w.boundingBox.midX, y: w.boundingBox.midY)
            // Nearest neighbour to the RIGHT on roughly the same row.
            var best: DetectedWord?
            var bestDX = CGFloat.greatestFiniteMagnitude
            for o in words where o.text != w.text || o.boundingBox != w.boundingBox {
                let oc = CGPoint(x: o.boundingBox.midX, y: o.boundingBox.midY)
                let dx = oc.x - c.x
                guard dx > 0.001 else { continue }                 // to the right
                guard abs(oc.y - c.y) < w.boundingBox.height * 1.2 else { continue } // same row-ish
                if dx < bestDX { bestDX = dx; best = o }
            }
            if let b = best {
                let bc = CGPoint(x: b.boundingBox.midX, y: b.boundingBox.midY)
                let dx = bc.x - c.x
                if dx > 0.001 { slopes.append((bc.y - c.y) / dx) }
            }
        }
        guard !slopes.isEmpty else { return 0 }
        slopes.sort()
        let median = slopes[slopes.count / 2]
        // Clamp: beyond ~30° the strip model breaks down anyway, and a wild fit
        // would do more harm than an axis-aligned scan. tan(30°) ≈ 0.58.
        return min(max(median, -0.58), 0.58)
    }

    // Groups words into text lines. On a TILTED page a word's raw midY drifts
    // across the frame as x grows, so same-line words no longer share a midY and
    // the old flat clustering split one line into several (which mis-scoped
    // underline runs). We cluster on the DE-SKEWED y instead: y' = midY − slope·midX
    // removes the tilt, so all words on one physical line collapse to one y' band.
    private func groupIntoTextLines(_ words: [DetectedWord], slope: CGFloat) -> [[DetectedWord]] {
        guard !words.isEmpty else { return [] }
        func deskewedY(_ w: DetectedWord) -> CGFloat {
            w.boundingBox.midY - slope * w.boundingBox.midX
        }
        let sorted = words.sorted { deskewedY($0) > deskewedY($1) }
        var lines: [[DetectedWord]] = []
        var current: [DetectedWord] = [sorted[0]]

        for word in sorted.dropFirst() {
            if abs(deskewedY(word) - deskewedY(current.last!)) < 0.04 {
                current.append(word)
            } else {
                lines.append(current)
                current = [word]
            }
        }
        lines.append(current)
        return lines
    }

    private func buildMark(visionBox: CGRect, landscapeW: Int, landscapeH: Int, words: [DetectedWord]) -> ColorMark? {
        let expanded = visionBox.insetBy(dx: -0.025, dy: -0.025)
        let matched = words.filter { expanded.intersects($0.boundingBox) }
        guard !matched.isEmpty else { return nil }

        // A highlighter marks a word or a short phrase — never a paragraph. If the
        // blob "covers" more than 4 words, or words spanning more than one text
        // line, it isn't a stroke (it's colored background swallowing the page),
        // so refuse it and let finger-pointing stay in charge.
        guard matched.count <= 4 else { return nil }
        let ys = matched.map { $0.boundingBox.midY }
        if let lo = ys.min(), let hi = ys.max(), hi - lo > 0.05 { return nil }

        let aspect = landscapeH > 0 ? Float(landscapeW) / Float(landscapeH) : 999
        let markType: ColorMark.MarkType = aspect > 2.5 ? .underline : .circle
        return ColorMark(markType: markType, boundingBox: visionBox, words: matched)
    }
}
