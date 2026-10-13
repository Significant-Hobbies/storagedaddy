import Foundation
import SaaSMakerUI
import Testing
@testable import StorageDaddy

struct StorageUIResourcesTests {
    @Test func missingBundleUsesFallback() {
        #expect(!StorageUIResources.registerFonts(in: nil))
    }

    @Test func incompleteAndCorruptFontsFailQualificationWithoutTrapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-fonts-\(UUID().uuidString).bundle")
        let fonts = root.appendingPathComponent("Contents/Resources/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: root))
        #expect(!StorageUIResources.registerFonts(in: bundle))
        for name in SMFonts.files {
            try Data("invalid font".utf8).write(to: fonts.appendingPathComponent(name + ".ttf"))
        }
        #expect(!StorageUIResources.registerFonts(in: bundle))
    }
}
