import Foundation
import Vision
import CoreVideo
import CoreGraphics

// Three detection paths, run in priority order each frame:
//   1. Colored mark (HSV saturation) — any colored pen/highlighter, fast & reliable.
//   2. Underline strip scan (pixel density below OCR baselines) — black/pencil underlines.
//   3. Circle contour detection (VNDetectContoursRequest + word-inside check) — black/pencil circles.
//
// Coordinate mapping — camera delivers landscape BGRA frames (W=1280, H=720):
//   Vision portrait normalized (bottom-left origin) ↔ landscape pixel:
//     vision_x = landscape_y / H   (landscape vertical → portrait horizontal)
//     vision_y = landscape_x / W   (landscape horizontal → portrait vertical)
//   Inverse: lx = vision_y * W,  ly = vision_x * H
class ColorMarkService {

    private let contourRequest: VNDetectContoursRequest = {
        let req = VNDetectContoursRequest()
        req.detectsDarkOnLight = true
        req.maximumImageDimension = 512
        return req
    }()

    private var frameIndex = 0

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

        // Path 3: circle contours are heavier; run every 5 frames
        if frameIndex % 5 == 0 {
            marks.append(contentsOf: detectBlackCircles(in: pixelBuffer, words: words))
        }

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

        let vBox = CGRect(
            x: CGFloat(minLY) / CGFloat(H),
            y: CGFloat(minLX) / CGFloat(W),
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

    // MARK: - Path 2: Black pen / pencil underline (adaptive local-contrast scan)
    //
    // A hand-drawn underline is a dark stripe that is markedly DARKER THAN THE
    // LOCAL PAGE BACKGROUND right around it — not merely dark in absolute terms.
    // The old code compared to a fixed luma threshold, so a dark-green cup or
    // any dim surface tripped it on every printed line (mass false positives).
    //
    // Here we, per text line:
    //   1. measure the local background luma just ABOVE the line (clean paper),
    //   2. scan the thin strip just BELOW the baseline,
    //   3. require that strip to be significantly darker than that background
    //      AND to form a horizontally continuous run (a real stroke, not noise).
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

        for lineWords in groupIntoTextLines(words) {
            guard lineWords.count >= 1 else { continue }

            let baseline = lineWords.min(by: { $0.boundingBox.minY < $1.boundingBox.minY })?.boundingBox.minY ?? 0
            let topVY    = lineWords.max(by: { $0.boundingBox.maxY < $1.boundingBox.maxY })?.boundingBox.maxY ?? 0
            let leftVX   = lineWords.min(by: { $0.boundingBox.minX < $1.boundingBox.minX })?.boundingBox.minX ?? 0
            let rightVX  = lineWords.max(by: { $0.boundingBox.maxX < $1.boundingBox.maxX })?.boundingBox.maxX ?? 1
            let spanVX   = rightVX - leftVX
            let lineH    = max(0.01, topVY - baseline)

            // Only lines wide enough to bother with (avoids single glyphs).
            guard spanVX >= 0.10 else { continue }

            // Vision x [leftVX,rightVX] → landscape ly range.
            let lyMin = max(0, Int(leftVX  * CGFloat(H)))
            let lyMax = min(H - 1, Int(rightVX * CGFloat(H)))
            guard lyMax > lyMin else { continue }

            // Underline strip: just below the baseline, thickness ∝ text height.
            let stripVY2 = baseline - 0.002
            let stripVY1 = baseline - min(0.03, lineH * 0.6)
            let sLxMin = max(0, Int(stripVY1 * CGFloat(W)))
            let sLxMax = min(W - 1, Int(stripVY2 * CGFloat(W)))
            guard sLxMax > sLxMin else { continue }

            // Local background reference: a clean band ABOVE the text (no glyphs).
            let bgVY1 = topVY + 0.004
            let bgVY2 = topVY + min(0.03, lineH * 0.6)
            let bLxMin = max(0, Int(bgVY1 * CGFloat(W)))
            let bLxMax = min(W - 1, Int(bgVY2 * CGFloat(W)))

            let step = 3

            // Mean background luma above the line.
            var bgSum: Float = 0, bgSumSq: Float = 0, bgN = 0
            if bLxMax > bLxMin {
                for ly in stride(from: lyMin, through: lyMax, by: step) {
                    for lx in stride(from: bLxMin, through: bLxMax, by: step) {
                        if let l = luma(lx, ly) { bgSum += l; bgSumSq += l * l; bgN += 1 }
                    }
                }
            }
            let bgLuma = bgN > 0 ? bgSum / Float(bgN) : 0.5
            let bgVar  = bgN > 0 ? max(0, bgSumSq / Float(bgN) - bgLuma * bgLuma) : 1
            let bgStd  = sqrt(bgVar)

            // Best-effort gate: finger-pointing is the reliable main path, so an
            // underline should stay SILENT whenever it can't be sure rather than
            // risk a false green box on patterned / dark paper.
            //
            //  • dark paper (< 0.28): not enough luma headroom to tell a stroke
            //    from the surface.
            //  • busy paper (std > 0.14): the local background is patterned, so
            //    "darker than average" is meaningless — a printed line or shadow
            //    would trip it.
            // Either way, bail out and let the finger path handle it.
            guard bgLuma >= 0.28, bgStd <= 0.14 else { continue }

            // A stroke pixel must be clearly darker than local paper: at least
            // 22% relative drop, floored so near-black paper can't game it.
            let darkCut = min(bgLuma * 0.78, bgLuma - 0.10)

            // Scan the strip column-by-column; a column "hit" if it contains a
            // dark pixel. A real underline hits a long continuous run of columns.
            var maxRun = 0, run = 0, hitCols = 0, totalCols = 0
            for ly in stride(from: lyMin, through: lyMax, by: step) {
                totalCols += 1
                var columnDark = false
                for lx in stride(from: sLxMin, through: sLxMax, by: 2) {
                    if let l = luma(lx, ly), l < darkCut { columnDark = true; break }
                }
                if columnDark {
                    hitCols += 1
                    run += 1
                    if run > maxRun { maxRun = run }
                } else {
                    run = 0
                }
            }

            guard totalCols > 0 else { continue }
            let coverage = Float(hitCols) / Float(totalCols)          // fraction underlined
            let continuity = Float(maxRun) / Float(totalCols)         // longest continuous run

            // Require both broad coverage AND a long continuous stroke — this is
            // what separates a drawn line from scattered dark texture/noise.
            if coverage > 0.55 && continuity > 0.45 {
                let box = CGRect(x: leftVX, y: stripVY1, width: spanVX, height: baseline - stripVY1)
                found.append(ColorMark(markType: .underline, boundingBox: box, words: lineWords))
            }
        }
        return found
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

                // Circle / oval ringing a word: aspect ~0.5–2.2, big enough to
                // enclose a word but BOUNDED — a hand-drawn ring is small. Without
                // an upper bound the rounded body of a cup / poster / card edge is
                // itself a big oval contour that swallows every word inside it
                // (the "whole page went green" false positive).
                guard aspect > 0.45 && aspect < 2.2 else { continue }
                guard w > 0.06 && h > 0.04 else { continue }
                guard w < 0.55 && h < 0.30 else { continue }   // reject giant panel contours

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

    // Groups words into text lines by clustering similar Vision-y midpoints.
    private func groupIntoTextLines(_ words: [DetectedWord]) -> [[DetectedWord]] {
        guard !words.isEmpty else { return [] }
        let sorted = words.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [[DetectedWord]] = []
        var current: [DetectedWord] = [sorted[0]]

        for word in sorted.dropFirst() {
            if abs(word.boundingBox.midY - current.last!.boundingBox.midY) < 0.04 {
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
