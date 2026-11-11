import Foundation

/// Kor marka yüzeylerinin (band, kontur çizgileri, küreler) vurgu rengine göre tonu. Bakır duraklar OKLCH'de vurgunun
/// tonuna döndürülür: algılanan açıklık ve doygunluk aynı kalır (koyu durak koyu, açık durak açık), yalnız ton değişir;
/// sRGB'ye sığmayan renkte doygunluk sığana kadar azalır. Kor vurgusu (turuncu) bugünkü renkleri aynen verir.

/// Bandın sekiz durağı (900 en koyu, 100 en açık; bkz. `EmberStop`).
public struct EmberBandStops: Equatable, Sendable {
    public let e900: UInt32
    public let e700: UInt32
    public let e600: UInt32
    public let e500: UInt32
    public let e400: UInt32
    public let e300: UInt32
    public let e200: UInt32
    public let e100: UInt32
}

/// Vurgunun band durakları: Kor (turuncu) vurgusunda `EmberStop`'un kendisi, ötekilerde vurgunun tonuna döndürülmüşü.
/// Saf fonksiyondur.
public func emberBandStops(accent: PanelAccent) -> EmberBandStops {
    let tint: (UInt32) -> UInt32 = { (hex: UInt32) -> UInt32 in emberTinted(hex: hex, accent: accent) }
    return EmberBandStops(
        e900: tint(EmberStop.e900), e700: tint(EmberStop.e700), e600: tint(EmberStop.e600), e500: tint(EmberStop.e500),
        e400: tint(EmberStop.e400), e300: tint(EmberStop.e300), e200: tint(EmberStop.e200), e100: tint(EmberStop.e100)
    )
}

/// Kor paletindeki bir bakır rengin vurgu tonundaki karşılığı. Ton farkı, vurgunun Kor paletindeki açık renginin
/// (`ThemePalette.ember.accents`) Kor vurgusununkinden farkıdır; turuncuda renk aynen döner. Saf fonksiyondur.
public func emberTinted(hex: UInt32, accent: PanelAccent) -> UInt32 {
    guard accent != .orange else {
        return hex
    }
    let reference: OKLCH = oklch(hex: ThemePalette.ember.accents[.orange].light)
    let target: OKLCH = oklch(hex: ThemePalette.ember.accents[accent].light)
    let source: OKLCH = oklch(hex: hex)
    return srgbHex(oklch: OKLCH(lightness: source.lightness, chroma: source.chroma, hue: source.hue + target.hue - reference.hue))
}

/// OKLCH rengi (açıklık 0...1, doygunluk, ton radyan).
struct OKLCH: Equatable {
    let lightness: Double
    let chroma: Double
    let hue: Double
}

/// sRGB onaltılık renginin OKLCH karşılığı. Saf fonksiyondur.
func oklch(hex: UInt32) -> OKLCH {
    let linear: (UInt32) -> Double = { (value: UInt32) -> Double in
        let channel: Double = Double(value & 0xFF) / 255
        return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    let red: Double = linear(hex >> 16)
    let green: Double = linear(hex >> 8)
    let blue: Double = linear(hex)
    let long: Double = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
    let medium: Double = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
    let short: Double = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
    let lightness: Double = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
    let a: Double = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
    let b: Double = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
    return OKLCH(lightness: lightness, chroma: (a * a + b * b).squareRoot(), hue: atan2(b, a))
}

/// OKLCH renginin sRGB onaltılık karşılığı; sRGB'ye sığmıyorsa doygunluk sığana kadar azaltılır (açıklık ve ton
/// korunur). Saf fonksiyondur.
func srgbHex(oklch color: OKLCH) -> UInt32 {
    var low: Double = 0
    var high: Double = color.chroma
    if linearRGB(oklch: color).allSatisfy({ (-0.000_01...1.000_01).contains($0) }) {
        low = color.chroma
    } else {
        for _ in 0..<24 {
            let middle: Double = (low + high) / 2
            let channels: [Double] = linearRGB(oklch: OKLCH(lightness: color.lightness, chroma: middle, hue: color.hue))
            if channels.allSatisfy({ (0...1).contains($0) }) {
                low = middle
            } else {
                high = middle
            }
        }
    }
    let channels: [Double] = linearRGB(oklch: OKLCH(lightness: color.lightness, chroma: low, hue: color.hue))
    let encoded: [UInt32] = channels.map { (value: Double) -> UInt32 in
        let clamped: Double = min(1, max(0, value))
        let gamma: Double = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return UInt32((gamma * 255).rounded())
    }
    return encoded[0] << 16 | encoded[1] << 8 | encoded[2]
}

/// OKLCH renginin doğrusal sRGB kanalları (kırmızı, yeşil, mavi; 0...1 dışı sığmıyor demektir). Saf fonksiyondur.
private func linearRGB(oklch color: OKLCH) -> [Double] {
    let a: Double = color.chroma * cos(color.hue)
    let b: Double = color.chroma * sin(color.hue)
    let long: Double = pow(color.lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
    let medium: Double = pow(color.lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
    let short: Double = pow(color.lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
    return [
        4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
        -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
        -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short,
    ]
}
