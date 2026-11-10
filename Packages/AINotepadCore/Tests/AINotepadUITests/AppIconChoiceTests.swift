import Foundation
import Testing
@testable import AINotepadUI

/// The repository root (this file is in `Packages/AINotepadCore/Tests/AINotepadUITests`).
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

@Suite struct AppIconChoiceTests {
    /// Every choice maps back from its iPhone alternate icon name and its Mac stored value; unknown names throw.
    @Test func namesRoundTrip() throws {
        for choice in AppIconChoice.allCases {
            #expect(try appIconChoice(alternateIconName: choice.alternateIconName) == choice)
            #expect(try appIconChoice(storedValue: choice.rawValue) == choice)
        }
        #expect(try appIconChoice(storedValue: nil) == .standard)
        #expect(throws: AppIconChoiceError.unknownAlternateIconName("AppIcon-Gone")) { try appIconChoice(alternateIconName: "AppIcon-Gone") }
        #expect(throws: AppIconChoiceError.unknownStoredValue("gone")) { try appIconChoice(storedValue: "gone") }
    }

    /// The asset catalogs and project.yml carry every icon the pickers offer: an iPhone alternate icon set listed in
    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, an iPhone preview image and a Mac Dock image.
    @Test func assetsExistForEveryChoice() throws {
        let root: URL = repositoryRoot()
        let files: FileManager = .default
        let project: String = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
        let listed: Set<String> = Set(
            project.split(separator: "\n")
                .first { $0.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].replacingOccurrences(of: "\"", with: "").split(separator: " ").map(String.init) } ?? []
        )
        let alternates: [String] = AppIconChoice.allCases.compactMap(\.alternateIconName)
        #expect(listed == Set(alternates))
        for name in alternates {
            #expect(files.fileExists(atPath: root.appending(path: "iOS/Assets.xcassets/AppIcons/\(name).appiconset/icon_1024.png").path), "\(name)")
        }
        for choice in AppIconChoice.allCases {
            #expect(files.fileExists(atPath: root.appending(path: "iOS/Assets.xcassets/AppIcons/\(choice.previewImageName).imageset/Contents.json").path), "\(choice)")
            if let dock = choice.dockImageName {
                #expect(files.fileExists(atPath: root.appending(path: "App/Assets.xcassets/DockIcons/\(dock).imageset/icon_1024.png").path), "\(choice)")
            }
        }
    }
}
