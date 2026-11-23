import KeyboardCore
import SwiftUI
import UIKit

/// The dictation's voice field: a soft gradient in the theme's colours with small glowing particles pulled across it
/// from left to right toward a light beside Done, as if a black hole draws them in. Listening, the voice's loudness
/// (`KeyboardModel.voiceLevels`, from the keyboard's own capture or from Gistsmith) speeds the particles up, brightens
/// them and brings more in; without levels yet they drift gently. Processing: slower and dimmer. Finished, or with
/// Reduce Motion: still. The motion is the pure `keyboardParticle` in KeyboardCore; `KeyboardParticleFieldView` draws it.
struct KeyboardParticleField: UIViewRepresentable {
    enum Mode: Equatable {
        case listening
        case processing
        case still
    }

    let brand: KeyboardBrand
    let isDark: Bool
    let levels: [Double]
    let mode: Mode
    /// The frame's time (`KeyboardModel.frameDate`, from the keyboard's display link).
    let date: Date

    func makeUIView(context: Context) -> KeyboardParticleFieldView {
        KeyboardParticleFieldView(frame: .zero)
    }

    func updateUIView(_ view: KeyboardParticleFieldView, context: Context) {
        view.show(brand: brand, isDark: isDark, levels: levels, mode: mode, date: date, reduceMotion: context.environment.accessibilityReduceMotion)
    }
}

/// What the field shows in one frame.
struct KeyboardParticleScene: Equatable {
    /// The particles' running travel (`keyboardParticleTravel`).
    let travel: Double
    /// The twinkle's clock.
    let time: TimeInterval
    /// The voice level 0…1 (`keyboardParticleLevel`).
    let level: Double
    /// How strongly the gradient glows.
    let glow: Double
    let fill: UIColor
    let tint: UIColor
    let isDark: Bool
}

/// Draws the voice field with Core Animation layers only: two gradients and, per particle, a glow and a body (small
/// white pictures drawn once, then moved, stretched, turned and faded each frame). Not a SwiftUI `Canvas`: a `Canvas`
/// renders into its own RenderBox image queue (`RBDrawingLayer` › `RBImageQueueLayer`), and in the keyboard extension
/// that queue stayed full when the dictation panel appeared ("RBLayer: full image queue", "RBDrawable: no surface,
/// dropping frame" on an iPhone 17 Pro Max with iOS 27): the field then showed nothing, not even its gradient, while the
/// timer beside it kept counting. The render server draws these layers itself, with no image queue in the extension.
@MainActor
final class KeyboardParticleFieldView: UIView {
    /// The blur the glows stand for, in points.
    private static let glowSpread: CGFloat = 2.5
    private let backdrop: CAGradientLayer = CAGradientLayer()
    private let light: CAGradientLayer = CAGradientLayer()
    private let glows: [CALayer]
    private let bodies: [CALayer]
    private var travel: Double = 0
    private var lastDate: Date?
    private var scene: KeyboardParticleScene?

    override init(frame: CGRect) {
        glows = (0..<keyboardParticleCount).map { (_: Int) -> CALayer in CALayer() }
        bodies = (0..<keyboardParticleCount).map { (_: Int) -> CALayer in CALayer() }
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        backdrop.startPoint = CGPoint(x: 0, y: 0.5)
        backdrop.endPoint = CGPoint(x: 1, y: 0.5)
        backdrop.locations = [0, 0.55, 0.85, 1]
        light.type = .radial
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 1)
        light.locations = [0, 0.35, 1]
        layer.addSublayer(backdrop)
        layer.addSublayer(light)
        for particle in glows + bodies {
            particle.isHidden = true
            layer.addSublayer(particle)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The next frame: advances the particles by the time since the last moving frame and lays the layers out.
    func show(brand: KeyboardBrand, isDark: Bool, levels: [Double], mode: KeyboardParticleField.Mode, date: Date, reduceMotion: Bool) {
        let level: Double = mode == .listening ? keyboardParticleLevel(levels: levels) : 0
        let isStill: Bool = reduceMotion || mode == .still
        if !isStill {
            let elapsed: TimeInterval = lastDate.map { date.timeIntervalSince($0) } ?? 0
            lastDate = date
            travel = keyboardParticleTravel(previous: travel, elapsed: elapsed, motion: mode == .processing ? .processing : .listening, level: level)
        }
        let traits: UITraitCollection = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        scene = KeyboardParticleScene(
            travel: isStill ? 0.35 : travel, time: isStill ? 0 : date.timeIntervalSinceReferenceDate, level: level,
            glow: mode == .processing ? 0.55 : 0.75 + 0.25 * level, fill: brand.fill.resolvedColor(with: traits),
            tint: brand.tint.resolvedColor(with: traits), isDark: isDark
        )
        layOut()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layOut()
    }

    private func layOut() {
        guard let scene, bounds.width > 0, bounds.height > 0 else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
        }
        let size: CGSize = bounds.size
        layer.cornerRadius = size.height / 2
        backdrop.frame = bounds
        let dark: Bool = scene.isDark
        backdrop.colors = [
            scene.tint.withAlphaComponent(dark ? 0.14 : 0.3).cgColor,
            scene.fill.withAlphaComponent((dark ? 0.42 : 0.6) * scene.glow).cgColor,
            scene.fill.withAlphaComponent((dark ? 0.68 : 0.9) * scene.glow).cgColor,
            scene.tint.withAlphaComponent((dark ? 0.5 : 0.6) * scene.glow).cgColor,
        ]
        // Where the particles are drawn in, beside Done: a soft light that swells with the voice (no dark core: on the
        // capsule it reads as a stain).
        let pull: Double = keyboardParticleEnergy(level: scene.level)
        let core: CGPoint = CGPoint(x: size.width - size.height * 0.2, y: size.height / 2)
        let reach: CGFloat = size.height * (0.8 + 0.35 * CGFloat(pull))
        light.frame = CGRect(x: core.x - reach, y: core.y - reach, width: reach * 2, height: reach * 2)
        light.colors = [
            UIColor.white.withAlphaComponent(0.18 + 0.3 * pull).cgColor,
            UIColor.white.withAlphaComponent(0.06 + 0.1 * pull).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        let spread: CGFloat = Self.glowSpread
        for index in 0..<keyboardParticleCount {
            let particle: KeyboardParticle = keyboardParticle(
                index: index, count: keyboardParticleCount, travel: scene.travel, level: scene.level, time: scene.time
            )
            let glow: CALayer = glows[index]
            let body: CALayer = bodies[index]
            guard particle.opacity > 0.02 else {
                glow.isHidden = true
                body.isHidden = true
                continue
            }
            glow.isHidden = false
            body.isHidden = false
            let radius: CGFloat = CGFloat(particle.radius) * size.height
            let head: CGPoint = CGPoint(x: CGFloat(particle.x) * size.width, y: CGFloat(particle.y) * size.height)
            if particle.isStreak {
                let tail: CGPoint = CGPoint(x: CGFloat(particle.tailX) * size.width, y: CGFloat(particle.tailY) * size.height)
                let width: CGFloat = radius * 1.3
                let placement: KeyboardStreakPlacement = keyboardStreakPlacement(tail: tail, head: head, width: width)
                place(
                    glow, picture: KeyboardParticlePictures.streakGlow, center: placement.center,
                    size: CGSize(width: placement.length + spread * 2, height: width + spread * 4), angle: placement.angle,
                    opacity: particle.opacity * 0.45
                )
                place(
                    body, picture: KeyboardParticlePictures.streak, center: placement.center, size: CGSize(width: placement.length, height: width),
                    angle: placement.angle, opacity: particle.opacity * 0.95
                )
            } else {
                let glowSide: CGFloat = radius * 4 + spread * 4
                place(
                    glow, picture: KeyboardParticlePictures.glow, center: head, size: CGSize(width: glowSide, height: glowSide), angle: 0,
                    opacity: particle.opacity * 0.32
                )
                place(body, picture: KeyboardParticlePictures.dot, center: head, size: CGSize(width: radius * 2, height: radius * 2), angle: 0, opacity: particle.opacity * 0.95)
            }
        }
    }

    private func place(_ target: CALayer, picture: CGImage, center: CGPoint, size: CGSize, angle: CGFloat, opacity: Double) {
        if (target.contents as AnyObject?) !== picture {
            target.contents = picture
        }
        target.bounds = CGRect(origin: .zero, size: size)
        target.position = center
        target.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        target.opacity = Float(opacity)
    }
}

/// The field's white pictures, drawn once: Core Animation stretches, turns and fades them per particle.
@MainActor
enum KeyboardParticlePictures {
    /// A particle's body: a sharp disc.
    static let dot: CGImage = keyboardParticlePicture(width: 32, height: 32) { (x: Double, y: Double) -> Double in
        let distance: Double = ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)).squareRoot() * 32
        return min(1, max(0, 16 - distance + 0.5))
    }

    /// A dot's glow: a disc blurred to a soft falloff.
    static let glow: CGImage = keyboardParticlePicture(width: 64, height: 64) { (x: Double, y: Double) -> Double in
        let squared: Double = ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)) * 4
        return exp(-squared * 4.5)
    }

    /// A streak: a sliver from a sharp, clear tail (left) to a bright head, its point beyond (right).
    static let streak: CGImage = keyboardParticlePicture(width: 128, height: 16) { (x: Double, y: Double) -> Double in
        let headAt: Double = 0.94
        let halfWidth: Double = x < headAt ? x / headAt : (1 - x) / (1 - headAt)
        let across: Double = abs(y - 0.5) * 2
        let coverage: Double = min(1, max(0, (halfWidth - across) * 8 + 0.5))
        return coverage * min(1, x / headAt)
    }

    /// A streak's glow: the sliver blurred, brightest by the head.
    static let streakGlow: CGImage = keyboardParticlePicture(width: 128, height: 32) { (x: Double, y: Double) -> Double in
        let across: Double = (y - 0.5) * 2
        let along: Double = x < 0.9 ? x / 0.9 : (1 - x) / 0.1
        return along * exp(-across * across * 4.5)
    }
}

/// A white picture `width` × `height` pixels whose opacity at each pixel's centre (0…1 across and down) is `alpha`.
private func keyboardParticlePicture(width: Int, height: Int, alpha: (Double, Double) -> Double) -> CGImage {
    var bytes: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
        for column in 0..<width {
            let value: Double = min(1, max(0, alpha((Double(column) + 0.5) / Double(width), (Double(row) + 0.5) / Double(height))))
            let byte: UInt8 = UInt8((value * 255).rounded())
            let offset: Int = (row * width + column) * 4
            // Premultiplied white: every channel equals the opacity.
            bytes[offset] = byte
            bytes[offset + 1] = byte
            bytes[offset + 2] = byte
            bytes[offset + 3] = byte
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
              width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
              shouldInterpolate: true, intent: .defaultIntent
          )
    else {
        preconditionFailure("The voice field's \(width)×\(height) picture could not be made")
    }
    return image
}
