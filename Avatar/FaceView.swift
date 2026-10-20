import SwiftUI

/// The talking face: a portrait image with an animated mouth, blinking eyelids and moving
/// eyebrows drawn over it. While the mouth is closed the portrait's own smile shows; as it
/// opens, a mouthless skin patch fades in and the animated mouth is drawn on top.
struct FaceView: View {
    var mouth: MouthShape
    var portrait: Portrait = .man
    /// How far the eyebrows are raised (1, or higher for "?" and "!") or lowered (negative) by
    /// stressed words; 0 at rest.
    var brows = 0.0
    /// The mood being shown (see `Mood`).
    var expression = FaceExpression.neutral
    /// Disable to render a still frame (no blinking).
    var isAnimated = true
    /// Fixes the eyelids at a given openness (0 closed ... 1 open), e.g. for previews.
    var eyeOpenness: Double?
    /// The presence shown between speeches (see `Presence`), its eased pose, and the last nod with
    /// how far the head dips for it.
    var presence: Presence.State?
    var pose = PresencePose.neutral
    var nodStarted: Date?
    var nodDepth = FaceView.nodDepth
    /// Listening to words as they come in: the eyes blink less often.
    var isAttentive = false

    /// Driven by `blink()`; the face is only redrawn while a blink or a nod is under way or the
    /// mouth or eyebrows change, not every display frame.
    @State private var blinkOpenness = 1.0
    /// While a nod is under way (see `nod()`).
    @State private var nodding = false

    /// How long a nod takes, and how far the forehead dips unless told otherwise.
    static let nodDuration = 0.35
    static let nodDepth = 3.2

    var body: some View {
        let eyeOpen = eyeOpenness ?? blinkOpenness
        let mouth = mouth
        let portrait = portrait
        let brows = brows
        let expression = expression
        let pose = pose
        let nodStarted = nodStarted
        let nodDepth = nodDepth
        let face = { (date: Date) in
            FaceCanvas(portrait: portrait, mouth: mouth, brows: brows, expression: expression, pose: pose,
                       nod: nodStarted.map { Self.nodOffset(after: date.timeIntervalSince($0), depth: nodDepth) } ?? 0,
                       eyeOpen: eyeOpen)
                .equatable()
        }

        Group {
            if nodding {
                // Redrawn every frame only for the 350 ms of a nod; otherwise only when something changes.
                TimelineView(.animation) { face($0.date) }
            } else {
                face(.now)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .aspectRatio(portrait.size, contentMode: .fit)
        .accessibilityLabel("Animated talking face")
        .task(id: isAnimated ? presence == .thinking ? 2 : isAttentive ? 3 : 1 : 0) {
            if isAnimated { await blink(thinking: presence == .thinking, attentive: isAttentive) }
        }
        .task(id: nodStarted) { await nod() }
    }

    /// Keeps `nodding` set for the length of the nod that started at `nodStarted`.
    private func nod() async {
        let remaining = nodStarted.map { Self.nodDuration - Date().timeIntervalSince($0) } ?? 0
        guard isAnimated, remaining > 0 else {
            nodding = false
            return
        }
        nodding = true
        try? await Task.sleep(for: .seconds(remaining))
        nodding = false
    }

    /// How far down the head is `elapsed` seconds into a nod `depth` pixels deep: down and back up, once.
    static func nodOffset(after elapsed: Double, depth: Double = nodDepth) -> Double {
        guard elapsed >= 0, elapsed < nodDuration else { return 0 }
        return depth * sin(.pi * elapsed / nodDuration)
    }

    /// Blinks every 2.5–5.5 s (randomised so it doesn't look mechanical): the lids close and
    /// open over about 180 ms, in 18 ms steps. While thinking, less often (5–9 s) and slower;
    /// while attentive to words coming in, a little less often (4–7 s).
    private func blink(thinking: Bool, attentive: Bool = false) async {
        let steps = 10
        let interval = thinking ? 5.0...9.0 : attentive ? 4.0...7.0 : 2.5...5.5
        let step = thinking ? 28 : 18
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: interval)))
            for index in 1...steps {
                guard !Task.isCancelled else { return }
                blinkOpenness = abs(Double(index) - Double(steps) / 2) / (Double(steps) / 2)
                try? await Task.sleep(for: .milliseconds(step))
            }
        }
    }
}

/// One still frame of the face. Equatable, so that SwiftUI redraws it only when something in it
/// changes.
private struct FaceCanvas: View, Equatable {
    var portrait: Portrait
    var mouth: MouthShape
    var brows: Double
    var expression: FaceExpression
    var pose: PresencePose
    var nod: Double
    var eyeOpen: Double

    static func == (a: Self, b: Self) -> Bool {
        a.portrait.id == b.portrait.id && a.mouth == b.mouth && a.brows == b.brows && a.expression == b.expression
            && a.pose == b.pose && a.nod == b.nod && a.eyeOpen == b.eyeOpen
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / portrait.size.width, size.height / portrait.size.height)
            context.translateBy(x: (size.width - portrait.size.width * scale) / 2,
                                y: (size.height - portrait.size.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let bounds = CGRect(origin: .zero, size: portrait.size)
            context.clip(to: Path(bounds))
            portrait.drawNodding(in: &context, nod: nod)
            // The features drawn over the portrait move with the face where they are.
            var browLayer = portrait.following(nod: nod, atY: portrait.brows[0].line, context)
            portrait.drawBrows(in: &browLayer, lift: expression.brows + brows + pose.brows,
                               tilt: expression.tilt, asymmetry: pose.browAsymmetry)
            var mouthLayer = portrait.following(nod: nod, atY: portrait.mouthCenter.y, context)
            portrait.drawMouth(in: &mouthLayer, shape: mouth, frown: expression.frown)
            var eyeLayer = portrait.following(nod: nod, atY: portrait.eyelidsRect.midY, context)
            portrait.lowerLids(in: &eyeLayer, by: pose.lids)
            portrait.drawEyelids(in: &eyeLayer, openness: eyeOpen)
        }
    }
}

/// A portrait image, its voice, and where its features are (in image pixels).
struct Portrait: Identifiable {
    /// Name of the system voice that speaks for this portrait.
    let voiceName: String
    let size: CGSize
    let image: Image
    /// The skin around the mouth with the lips painted out (feathered edges).
    let mouthPatch: Image
    let mouthPatchRect: CGRect
    /// Skin across both eyes (each row blended between the skin at the eye's corners),
    /// revealed under the closing eyelids.
    let eyelids: Image
    let eyelidsRect: CGRect
    let eyes: [CGRect]
    let brows: [BrowRegion]
    /// How many pixels the brows rise at a lift of 1.
    let browLift: Double
    let mouthCenter: CGPoint
    /// Where the chin is, and where the neck meets the collar (the shoulders below never move).
    let chinY: Double
    let neckY: Double
    /// Converts `MouthShape` design units to image pixels.
    let mouthScale: Double
    let lip: Color

    var id: String { voiceName }

    /// The face's name, for its window's title: "Man" or "Woman".
    var faceName: String { voiceName == "Samantha" ? "Woman" : "Man" }

    init(voiceName: String, imageName: String, size: CGSize, mouthPatchRect: CGRect, eyelidsRect: CGRect,
         eyes: [CGRect], brows: [BrowRegion], browLift: Double, mouthCenter: CGPoint, chinY: Double,
         neckY: Double, mouthScale: Double, lip: Color) {
        func load(_ name: String) -> Image { Image(nsImage: NSImage(named: name) ?? NSImage()) }
        self.voiceName = voiceName
        self.size = size
        image = load(imageName)
        mouthPatch = load(imageName + "MouthPatch")
        eyelids = load(imageName + "Eyelids")
        self.mouthPatchRect = mouthPatchRect
        self.eyelidsRect = eyelidsRect
        self.eyes = eyes
        self.brows = brows
        self.browLift = browLift
        self.mouthCenter = mouthCenter
        self.chinY = chinY
        self.neckY = neckY
        self.mouthScale = mouthScale
        self.lip = lip
    }

    static let man = Portrait(
        voiceName: "Daniel", imageName: "Man", size: CGSize(width: 360, height: 360),
        mouthPatchRect: CGRect(x: 146, y: 174, width: 68, height: 24),
        eyelidsRect: CGRect(x: 126, y: 110, width: 114, height: 36),
        eyes: [CGRect(x: 136, y: 120, width: 30, height: 20), CGRect(x: 195, y: 120, width: 32, height: 20)],
        brows: [BrowRegion(minX: 120, maxX: 172, top: 86, line: 108, bottom: 119),
                 BrowRegion(minX: 185, maxX: 238, top: 86, line: 108, bottom: 119)],
        browLift: 3,
        mouthCenter: CGPoint(x: 180, y: 184), chinY: 222, neckY: 250, mouthScale: 0.78,
        lip: Color(red: 0.72, green: 0.45, blue: 0.40))

    static let woman = Portrait(
        voiceName: "Samantha", imageName: "Woman", size: CGSize(width: 360, height: 360),
        mouthPatchRect: CGRect(x: 151, y: 146, width: 62, height: 26),
        eyelidsRect: CGRect(x: 114, y: 86, width: 132, height: 44),
        eyes: [CGRect(x: 125, y: 95, width: 41, height: 27), CGRect(x: 197, y: 95, width: 38, height: 27)],
        brows: [BrowRegion(minX: 118, maxX: 172, top: 66, line: 86, bottom: 94),
                 BrowRegion(minX: 188, maxX: 232, top: 66, line: 85, bottom: 94)],
        browLift: 2.5,
        mouthCenter: CGPoint(x: 182, y: 157), chinY: 190, neckY: 215, mouthScale: 0.7,
        lip: Color(red: 0.82, green: 0.50, blue: 0.50))

    static let all = [man, woman]

    private var mouthInside: Color { Color(red: 0.30, green: 0.10, blue: 0.09) }
    private var tongue: Color { Color(red: 0.86, green: 0.45, blue: 0.44) }
    private var skinShadow: Color { Color(red: 0.55, green: 0.36, blue: 0.28) }
    private var lash: Color { Color(red: 0.23, green: 0.15, blue: 0.11) }

    // MARK: Presence

    /// How far down a nod `nod` pixels deep moves the image's row `y`: nothing at the top of the
    /// frame, all of it at the brows, a little less at the chin (the face tips forward, the forehead
    /// coming down more than the chin), and nothing again by the collar, so the shoulders stay put.
    func nodShift(atY y: Double, nod: Double) -> Double {
        guard nod != 0, y > 0, y < neckY else { return 0 }
        let browY = brows[0].line
        let atChin = 0.6
        if y < browY { return nod * y / browY }
        if y < chinY { return nod * (1 - (1 - atChin) * (y - browY) / (chinY - browY)) }
        return nod * atChin * (1 - (y - chinY) / (neckY - chinY))
    }

    /// Draws the portrait with the head dipped `nod` pixels for a nod: rows down to the collar are
    /// redrawn in thin strips, each moved by `nodShift`, the neck stretching to follow.
    func drawNodding(in context: inout GraphicsContext, nod: Double) {
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard nod != 0 else { return }
        let strip = 2.0
        var y = 0.0
        while y < neckY {
            let next = min(y + strip, neckY)
            drawSlice(in: &context, x: 0, width: size.width, from: y, next,
                      to: y + nodShift(atY: y, nod: nod), next + nodShift(atY: next, nod: nod))
            y = next
        }
    }

    /// A copy of `context` moved down with the face at row `y`, for what is drawn over it there.
    func following(nod: Double, atY y: Double, _ context: GraphicsContext) -> GraphicsContext {
        var moved = context
        moved.translateBy(x: 0, y: nodShift(atY: y, nod: nod))
        return moved
    }

    // MARK: Eyebrows

    /// Moves the eyebrows by redrawing the image over each brow region in narrow columns,
    /// each stretched vertically so the brow line moves up by `lift` × `browLift` pixels (down
    /// when `lift` is negative, and less toward the ends of the brow), while the forehead above
    /// and the eye below stay put. `tilt` also raises (or, negative, lowers) the inner ends by
    /// up to `tilt` × `browLift` pixels.
    /// `asymmetry` is added to the first brow's lift and taken from the second's.
    func drawBrows(in context: inout GraphicsContext, lift: Double, tilt: Double = 0, asymmetry: Double = 0) {
        guard abs(lift) > 0.01 || abs(tilt) > 0.01 || abs(asymmetry) > 0.01 else { return }
        let column = 2.0
        for (index, brow) in brows.enumerated() {
            let lift = min(1.6, max(-1, lift + (index == 0 ? asymmetry : -asymmetry)))
            var x = brow.minX
            while x < brow.maxX {
                let middle = x + column / 2
                let rise = browLift * (lift * brow.weight(atX: middle)
                    + tilt * brow.tiltWeight(atX: middle, centerX: mouthCenter.x))
                if abs(rise) > 0.05 {
                    let raised = brow.line - rise
                    // Forehead: top ... line squeezed into (or stretched over) top ... raised.
                    drawSlice(in: &context, x: x, width: column, from: brow.top, brow.line,
                              to: brow.top, raised)
                    // Under the brow: line ... bottom stretched over (or squeezed into) raised ... bottom.
                    drawSlice(in: &context, x: x, width: column, from: brow.line, brow.bottom,
                              to: raised, brow.bottom)
                }
                x += column
            }
        }
    }

    /// Draws the image's rows `sourceTop ..< sourceBottom` over `top ..< bottom`, within one
    /// column.
    private func drawSlice(in context: inout GraphicsContext, x: Double, width: Double,
                           from sourceTop: Double, _ sourceBottom: Double, to top: Double, _ bottom: Double) {
        let stretch = (bottom - top) / (sourceBottom - sourceTop)
        context.drawLayer { layer in
            // A hair of overlap with the neighbouring columns and slices keeps seams from showing
            // (a half-covered pixel would let the unmoved image show through).
            layer.clip(to: Path(CGRect(x: x - 0.25, y: top - 0.5, width: width + 0.5, height: bottom - top + 1)))
            layer.draw(image, in: CGRect(x: 0, y: top - sourceTop * stretch,
                                         width: size.width, height: size.height * stretch))
        }
    }

    // MARK: Mouth

    /// Draws the mouth. `frown` (0 ... 1) turns the corners down and, since the portrait's own
    /// mouth smiles, covers it even when the mouth is closed.
    func drawMouth(in context: inout GraphicsContext, shape: MouthShape, frown: Double = 0) {
        // Fade the animated mouth in as it opens, so a closed mouth shows the portrait's smile.
        let fade = min(1, max((shape.top + shape.bottom) / 6, frown * 4))
        guard fade > 0.01 else { return }
        let droop = 5 * frown

        context.drawLayer { layer in
            layer.opacity = fade
            layer.draw(mouthPatch, in: mouthPatchRect)

            let center = mouthCenter
            layer.translateBy(x: center.x, y: center.y)
            layer.scaleBy(x: mouthScale, y: mouthScale)
            layer.translateBy(x: -center.x, y: -center.y)

            let w = shape.halfWidth
            // Two cubic curves between the corners; roundness pushes the control points out
            // toward the corners, turning a pointed grin into an oval.
            let reach = w * (0.45 + 0.55 * shape.roundness)
            let left = CGPoint(x: center.x - w, y: center.y + droop)
            let right = CGPoint(x: center.x + w, y: center.y + droop)
            var mouth = Path()
            mouth.move(to: left)
            mouth.addCurve(to: right,
                           control1: CGPoint(x: center.x - reach, y: center.y - shape.top * 1.33),
                           control2: CGPoint(x: center.x + reach, y: center.y - shape.top * 1.33))
            mouth.addCurve(to: left,
                           control1: CGPoint(x: center.x + reach, y: center.y + shape.bottom * 1.33),
                           control2: CGPoint(x: center.x - reach, y: center.y + shape.bottom * 1.33))
            mouth.closeSubpath()

            // Soft shadow under the lower lip.
            layer.drawLayer { shadow in
                shadow.addFilter(.blur(radius: 2.5))
                shadow.fill(Path(ellipseIn: CGRect(x: center.x - w * 0.55, y: center.y + shape.bottom + 3,
                                                   width: w * 1.1, height: 5)),
                            with: .color(skinShadow.opacity(0.5)))
            }

            layer.fill(mouth, with: .color(mouthInside))
            layer.drawLayer { inside in
                inside.clip(to: mouth)
                let opening = shape.top + shape.bottom
                let top = center.y - shape.top
                let bottom = center.y + shape.bottom
                if shape.tongue > 0.01 {
                    let height = shape.bottom * 1.1 * shape.tongue
                    inside.fill(Path(ellipseIn: CGRect(x: center.x - w * 0.55, y: bottom - height,
                                                       width: w * 1.1, height: height * 2)),
                                with: .color(tongue))
                }
                if shape.upperTeeth > 0.01 {
                    inside.fill(Path(CGRect(x: center.x - w, y: top - 2, width: w * 2, height: 2 + opening * shape.upperTeeth)),
                                with: .color(Color(white: 0.96)))
                }
                if shape.lowerTeeth > 0.01 {
                    let height = opening * shape.lowerTeeth
                    inside.fill(Path(CGRect(x: center.x - w, y: bottom - height, width: w * 2, height: height + 2)),
                                with: .color(Color(white: 0.88)))
                }
                // Inner shadow around the edges.
                inside.addFilter(.blur(radius: 2.5))
                inside.stroke(mouth, with: .color(.black.opacity(0.45)), lineWidth: 5)
            }
            // A closed mouth is only a line: lips pressed together, with a dark crease between.
            let closed = max(0, 1 - (shape.top + shape.bottom) / 3)
            if closed > 0.01 {
                // Upper and lower lips as one lens along the mouth line, fuller below.
                var lips = Path()
                lips.move(to: left)
                lips.addCurve(to: right,
                              control1: CGPoint(x: center.x - reach, y: center.y - shape.top * 1.33 - 8),
                              control2: CGPoint(x: center.x + reach, y: center.y - shape.top * 1.33 - 8))
                lips.addCurve(to: left,
                              control1: CGPoint(x: center.x + reach, y: center.y + shape.bottom * 1.33 + 11),
                              control2: CGPoint(x: center.x - reach, y: center.y + shape.bottom * 1.33 + 11))
                lips.closeSubpath()
                layer.drawLayer { soft in
                    soft.addFilter(.blur(radius: 0.7))
                    soft.fill(lips, with: .color(lip.opacity(closed)))
                }
                layer.stroke(mouth, with: .color(mouthInside.opacity(0.6 * closed)),
                             style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }
            layer.stroke(mouth, with: .color(lip.opacity(1 - closed)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }

    // MARK: Eyelids

    /// Lowers the upper eyelids by `amount` (0 ... 1 of the eye's height) using the portrait's own
    /// lids and lashes: in narrow columns, the lid is stretched down and the top of the eye below it
    /// squeezed, fading out toward the corners. (Holding the blink texture half-closed shows a pale
    /// patch, so it is kept for blinks.)
    func lowerLids(in context: inout GraphicsContext, by amount: Double) {
        guard amount > 0.01 else { return }
        let column = 1.5
        for r in eyes {
            let top = r.minY - 3                    // skin just above the lashes stays put
            let line = r.minY + r.height * 0.15     // the lash line, which moves down
            let bottom = r.midY + r.height * 0.25   // the lower part of the eye stays put
            let region = BrowRegion(minX: r.minX - 2, maxX: r.maxX + 2, top: top, line: line, bottom: bottom)
            var x = region.minX
            while x < region.maxX {
                let drop = amount * r.height * 0.6 * region.weight(atX: x + column / 2, taper: 0.35)
                if drop > 0.05 {
                    drawSlice(in: &context, x: x, width: column, from: top, line, to: top, line + drop)
                    drawSlice(in: &context, x: x, width: column, from: line, bottom, to: line + drop, bottom)
                }
                x += column
            }
        }
    }

    func drawEyelids(in context: inout GraphicsContext, openness: Double) {
        guard openness < 0.98 else { return }
        for r in eyes {
            // The lid edge runs corner to corner: its middle travels from the top of the eye
            // (open) to a gentle downward curve a little below centre (closed).
            let closedY = r.midY + r.height * 0.22
            let edgeY = closedY + (r.minY - closedY) * openness
            let control = CGPoint(x: r.midX, y: 2 * edgeY - r.midY)
            var lid = Path()
            lid.move(to: CGPoint(x: r.minX - 2, y: r.minY - 6))
            lid.addLine(to: CGPoint(x: r.minX - 2, y: r.midY))
            lid.addQuadCurve(to: CGPoint(x: r.maxX + 2, y: r.midY), control: control)
            lid.addLine(to: CGPoint(x: r.maxX + 2, y: r.minY - 6))
            lid.closeSubpath()

            let eyeball = Path(ellipseIn: r.insetBy(dx: -2, dy: -2))
            context.drawLayer { layer in
                layer.clip(to: eyeball)
                layer.clip(to: lid)
                layer.draw(eyelids, in: eyelidsRect)
            }
            // As the lid finishes closing, cover the rest of the eye (below the lash line) too.
            let seal = min(1, max(0, (0.3 - openness) / 0.3))
            if seal > 0 {
                context.drawLayer { layer in
                    layer.opacity = seal
                    layer.clip(to: eyeball)
                    layer.draw(eyelids, in: eyelidsRect)
                }
            }
            context.drawLayer { layer in
                layer.clip(to: eyeball)
                layer.clip(to: lid)
                // A little shading toward the lash line gives the lid some roundness.
                layer.fill(lid, with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.07)]),
                                                      startPoint: CGPoint(x: r.midX, y: r.minY),
                                                      endPoint: CGPoint(x: r.midX, y: max(r.minY + 1, edgeY))))
            }
            var lashLine = Path()
            lashLine.move(to: CGPoint(x: r.minX + 1, y: r.midY))
            lashLine.addQuadCurve(to: CGPoint(x: r.maxX - 1, y: r.midY), control: control)
            context.drawLayer { layer in
                layer.clip(to: eyeball)
                layer.stroke(lashLine, with: .color(lash), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }
}

#Preview("Mouth shapes") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(160)), count: 4)) {
        ForEach(Viseme.allCases, id: \.self) { viseme in
            VStack {
                FaceView(mouth: viseme.shape, isAnimated: false)
                    .frame(width: 150, height: 220)
                Text(viseme.rawValue).font(.caption)
            }
        }
    }
    .padding()
}

#Preview("Eyebrows") {
    HStack {
        ForEach(Portrait.all) { portrait in
            ForEach([-0.5, 0.0, 1.0, Emphasis.exclaimedLift], id: \.self) { lift in
                FaceView(mouth: .rest, portrait: portrait, brows: lift, isAnimated: false)
                    .frame(width: 200, height: 200)
            }
        }
    }
    .padding()
}

#Preview("Blink") {
    HStack {
        ForEach([1.0, 0.5, 0.0], id: \.self) { openness in
            FaceView(mouth: .rest, isAnimated: false, eyeOpenness: openness)
                .frame(width: 200, height: 290)
        }
    }
    .padding()
}
