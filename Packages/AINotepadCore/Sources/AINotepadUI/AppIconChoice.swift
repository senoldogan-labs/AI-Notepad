/// User-selectable app icon (Settings › Appearance › App icon on Mac and iPhone). Every variant uses the same glyph
/// (three bars and a note stroke); `scripts/render-app-icon.swift` draws them. The App Store icon is always `standard`.
///
/// iPhone: the variants are alternate app icons in `iOS/Assets.xcassets/AppIcons` (`AppIcon-<Name>`, listed in
/// project.yml's `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`); the system stores the choice. Mac: the variant is the
/// running app's Dock icon (`DockIcon-<Name>` in `App/Assets.xcassets/DockIcons`), stored under `appearance.appIcon`.
public enum AppIconChoice: String, CaseIterable, Sendable {
    case standard
    case ember
    case cream
    case night
    case classic

    /// Mac `UserDefaults` key of the choice (nothing stored is `standard`). The iPhone needs no key: the system keeps
    /// the alternate icon name.
    public static let macStorageKey: String = "appearance.appIcon"

    /// Name shown in the picker.
    public var displayName: String {
        switch self {
        case .standard: String(localized: "Varsayılan")
        case .ember: String(localized: "Kor")
        case .cream: String(localized: "Krem")
        case .night: String(localized: "Gece")
        case .classic: String(localized: "Klasik")
        }
    }

    /// Asset name suffix shared by the iPhone and Mac sets (`AppIcon-Ember`, `DockIcon-Ember`…).
    private var assetSuffix: String {
        switch self {
        case .standard: "Standard"
        case .ember: "Ember"
        case .cream: "Cream"
        case .night: "Night"
        case .classic: "Classic"
        }
    }

    /// iPhone alternate icon name for `setAlternateIconName`; nil is the primary icon.
    public var alternateIconName: String? {
        self == .standard ? nil : "AppIcon-\(assetSuffix)"
    }

    /// iPhone image set that shows the icon in the picker.
    public var previewImageName: String {
        "AppIconPreview-\(assetSuffix)"
    }

    /// Mac image set drawn as the Dock icon; nil is the bundle's own icon.
    public var dockImageName: String? {
        self == .standard ? nil : "DockIcon-\(assetSuffix)"
    }
}

/// The choice behind an iPhone alternate icon name (`UIApplication.alternateIconName`). An unknown name means the
/// asset catalog and `AppIconChoice` disagree, which is a build mistake: it throws instead of showing the default.
/// Pure function.
public func appIconChoice(alternateIconName: String?) throws(AppIconChoiceError) -> AppIconChoice {
    guard let name = alternateIconName else {
        return .standard
    }
    guard let choice = AppIconChoice.allCases.first(where: { $0.alternateIconName == name }) else {
        throw AppIconChoiceError.unknownAlternateIconName(name)
    }
    return choice
}

/// The stored Mac choice (`appearance.appIcon`). Nothing stored is `standard`; an unknown stored value throws.
/// Pure function.
public func appIconChoice(storedValue: String?) throws(AppIconChoiceError) -> AppIconChoice {
    guard let value = storedValue else {
        return .standard
    }
    guard let choice = AppIconChoice(rawValue: value) else {
        throw AppIconChoiceError.unknownStoredValue(value)
    }
    return choice
}

/// A name or stored value that matches no `AppIconChoice`.
public enum AppIconChoiceError: Error, Equatable, CustomStringConvertible {
    case unknownAlternateIconName(String)
    case unknownStoredValue(String)

    public var description: String {
        switch self {
        case .unknownAlternateIconName(let name): "No AppIconChoice for alternate icon name \(name)"
        case .unknownStoredValue(let value): "No AppIconChoice for stored value \(value) (appearance.appIcon)"
        }
    }
}
