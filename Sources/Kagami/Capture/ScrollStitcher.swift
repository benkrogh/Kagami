import AppKit
import Vision

// MARK: - Scroll Stitcher
//
// Owns all of the scrolling-capture image work and runs it entirely on its own
// serial background queue, so a high-frame-rate capture stream never backs up on
// the main thread. The main thread only ever receives finished strip images for
// the live preview and the final composed result.
//
// Overlap detection uses Vision's translational image registration
// (`VNTranslationalImageRegistrationRequest`) on a downscaled copy of each frame.
// Vision does true 2D feature alignment, so unlike a hand-rolled 1D/grid matcher it
// works on real text/image content (no aliasing, no signal-washout). It is wrapped
// in an `autoreleasepool` per frame: Vision allocates autoreleased Objective-C
// objects ("VNImageSignature"), and on a long-lived GCD queue that pool never
// drains on its own — left unchecked it eventually fails to allocate (the
// `cvml.ImageRegistration Code=4710` error). Draining per frame keeps it healthy.
//
// Each frame is matched against the immediately-preceding frame, so the per-frame
// shift stays small and accurate. We accumulate the fractional pixel remainder so
// repeated rounding can't drift the seam over a long capture, cap implausibly large
// shifts (fast fling / mis-registration) as skips, and coalesce frames so work can
// never back up.

final class ScrollStitcher {
    struct Counts { var frames = 0, none = 0, unmatched = 0, matched = 0, strips = 0 }

    /// Called on the main thread for the base frame and every appended strip:
    /// (segmentID, image, totalComposedPoints, frameCount).
    private let onSegmentMain: (Int, NSImage, CGFloat, Int) -> Void

    private let queue = DispatchQueue(label: "com.kagami.scrollstitcher")
    private let regionSize: NSSize          // points
    private let maxComposedPts: CGFloat

    // Queue-owned state.
    private var active = true
    private var baseImage: NSImage?
    private var strips: [NSImage] = []
    private var refSmall: CGImage?          // downscaled previous frame (for registration)
    private var carry: CGFloat = 0          // unspent sub-pixel scroll remainder
    private var composedPts: CGFloat = 0
    private var nextID = 0
    private var counts = Counts()
    private var rejectStreak = 0            // consecutive untrusted registrations

    // Frame coalescing.
    private var pending: CGImage?
    private var processing = false

    // Tuning.
    private let regTargetWidth = 360        // downscale width for registration (small = fast + low memory)
    private let minMovePx: CGFloat = 1.0    // below this we treat the frame as static
    // A per-frame downward shift larger than this fraction of the frame has too
    // little overlap to trust — skip it (resync) rather than stitch a bogus strip.
    private let maxTrustFraction = 0.45
    // How many consecutive untrusted registrations we tolerate while holding the
    // last good reference (so a one-off mis-registration is recovered by the next
    // frame instead of dropping content) before forcing a resync.
    private let maxRejectStreak = 5

    init(regionSize: NSSize,
         maxComposedPts: CGFloat = 60_000,
         onSegment: @escaping (Int, NSImage, CGFloat, Int) -> Void) {
        self.regionSize = regionSize
        self.maxComposedPts = maxComposedPts
        self.onSegmentMain = onSegment
    }

    // MARK: - Public API (thread-safe)

    /// Coalescing enqueue: keeps only the most recent frame so registration work
    /// can never back up behind a burst of stream frames.
    func enqueue(_ cg: CGImage) {
        queue.async {
            self.pending = cg
            if !self.processing {
                self.processing = true
                self.drain()
            }
        }
    }

    private func drain() {
        guard active, let cg = pending else { processing = false; return }
        pending = nil
        process(cg)
        if pending != nil {
            queue.async { self.drain() }
        } else {
            processing = false
        }
    }

    /// Stops accepting frames and composes the final tall image. `completion` runs
    /// on the main thread.
    func finish(completion: @escaping (NSImage?, Counts) -> Void) {
        queue.async {
            self.active = false
            let base = self.baseImage
            let captured = self.strips
            let c = self.counts
            let result: NSImage?
            if let base {
                result = captured.isEmpty ? base : (self.compose(base: base, strips: captured) ?? base)
            } else {
                result = nil
            }
            DispatchQueue.main.async { completion(result, c) }
        }
    }

    func cancel() {
        queue.async {
            self.active = false
            self.pending = nil
            self.baseImage = nil
            self.strips = []
            self.refSmall = nil
        }
    }

    // MARK: - Per-frame processing (serial queue)

    private func process(_ cg: CGImage) {
        guard active else { return }
        // Drain Vision's autoreleased objects every frame (see type doc).
        autoreleasepool {
            counts.frames += 1
            guard let small = downscale(cg, targetWidth: regTargetWidth) else { return }

            if baseImage == nil {
                let base = NSImage(cgImage: cg, size: regionSize)
                baseImage = base
                composedPts = regionSize.height
                refSmall = small
                carry = 0
                emit(base)
                return
            }

            guard let ref = refSmall else { refSmall = small; return }

            let ty = registerVerticalShift(reference: ref, floating: small)
            let scaleBack = CGFloat(cg.height) / CGFloat(max(1, small.height))
            let shiftFull = (ty ?? 0) * scaleBack
            // Downward page scroll (new content at the bottom) registers as a
            // NEGATIVE ty in Vision's lower-left space, so downward distance is
            // -shiftFull. Upward / static give down <= 0 and are ignored.
            let down = -shiftFull

            // An untrusted registration (failed, or an implausibly large spike) is
            // NOT used to advance the reference: we hold the last good reference so
            // the next frame can match across the spike and recover the real scroll,
            // rather than dropping content and leaving a visible jump. After too many
            // in a row we give up and resync to avoid getting stuck.
            func reject() {
                counts.unmatched += 1
                carry = 0
                rejectStreak += 1
                if rejectStreak >= maxRejectStreak {
                    refSmall = small
                    rejectStreak = 0
                }
            }

            guard ty != nil else { reject(); return }
            if down >= CGFloat(cg.height) * maxTrustFraction { reject(); return }

            // Trusted reading from here on — advance the reference.
            rejectStreak = 0
            refSmall = small

            if down <= minMovePx {
                counts.none += 1
                return
            }

            counts.matched += 1
            let total = down + carry
            let px = Int(total.rounded(.down))
            carry = total - CGFloat(px)
            if px >= 1, let strip = bottomStripCopy(cg, px: px) {
                strips.append(strip)
                composedPts += strip.size.height
                emit(strip)
            }
            if composedPts >= maxComposedPts { active = false }
        }
    }

    private func emit(_ image: NSImage) {
        let id = nextID
        nextID += 1
        counts.strips = strips.count
        let total = composedPts
        let frameCount = 1 + strips.count
        DispatchQueue.main.async { self.onSegmentMain(id, image, total, frameCount) }
    }

    // MARK: - Vision registration

    private func registerVerticalShift(reference: CGImage, floating: CGImage) -> CGFloat? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating)
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return CGFloat(obs.alignmentTransform.ty)
    }

    /// Squash horizontally for speed/memory but PRESERVE full vertical resolution,
    /// so the registered shift is measured in real pixels (1px precision). Scaling
    /// height down would quantize the shift to N real px per unit and throw seams
    /// off by several pixels (visible ghosting).
    private func downscale(_ cg: CGImage, targetWidth: Int) -> CGImage? {
        let w = max(1, min(targetWidth, cg.width))
        let h = cg.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Strip extraction (memory-safe copy)

    private func bottomStripCopy(_ cg: CGImage, px: Int) -> NSImage? {
        let pxH = min(max(px, 1), cg.height)
        guard pxH > 0, cg.width > 0 else { return nil }
        let srcRect = CGRect(x: 0, y: cg.height - pxH, width: cg.width, height: pxH)
        guard let cropped = cg.cropping(to: srcRect) else { return nil }

        let ptH = CGFloat(pxH) * regionSize.height / CGFloat(cg.height)
        let pointSize = NSSize(width: regionSize.width, height: ptH)

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: nil, width: cg.width, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cg.width, height: pxH))
            if let copy = ctx.makeImage() {
                return NSImage(cgImage: copy, size: pointSize)
            }
        }
        return NSImage(cgImage: cropped, size: pointSize)
    }

    // MARK: - Final compose

    /// Stacks base + strips at NATIVE integer pixel rows (no scaling, no fractional
    /// offsets) in a single uniform color space. Drawing strips at fractional point
    /// positions — as a points-based compose does — resamples each one and leaves a
    /// faint line at every seam, which shows up as horizontal banding in smooth
    /// gradients. Integer-pixel stacking avoids that entirely.
    private func compose(base: NSImage, strips: [NSImage]) -> NSImage? {
        guard let baseCG = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return base }

        var layers: [CGImage] = [baseCG]
        for s in strips {
            if let c = s.cgImage(forProposedRect: nil, context: nil, hints: nil) { layers.append(c) }
        }

        let pxW = baseCG.width
        let pxH = layers.reduce(0) { $0 + $1.height }
        guard pxW > 0, pxH > 0 else { return base }

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }
        ctx.interpolationQuality = .none

        // CG origin is bottom-left; lay the base at the top, strips downward, each at
        // an exact integer pixel row so no resampling occurs.
        var topOffset = 0
        for layer in layers {
            let y = pxH - topOffset - layer.height
            ctx.draw(layer, in: CGRect(x: 0, y: y, width: pxW, height: layer.height))
            topOffset += layer.height
        }

        guard let outCG = ctx.makeImage() else { return base }
        let scaleY = CGFloat(baseCG.height) / max(1, base.size.height)
        let outPtH = CGFloat(pxH) / max(1, scaleY)
        return NSImage(cgImage: outCG, size: NSSize(width: base.size.width, height: outPtH))
    }
}
