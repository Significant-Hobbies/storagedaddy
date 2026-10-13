import CoreText
import Foundation
import SaaSMakerUI

/// Fonts are optional at runtime; release qualification still requires all of them.
enum StorageUIResources {
    static let loaded = registerFonts(in: fontBundle())

    static func fontBundle() -> Bundle? {
        let name = "SaaSMakerUI_SaaSMakerUI.bundle"
        let locations = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name)
        ]
        return locations.compactMap { $0 }.compactMap { Bundle(url: $0) }.first
    }

    static func registerFonts(in bundle: Bundle?) -> Bool {
        guard let bundle else { return false }
        let urls = SMFonts.files.compactMap {
            bundle.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
        }
        guard urls.count == SMFonts.files.count,
              urls.allSatisfy({ !(CTFontManagerCreateFontDescriptorsFromURL($0 as CFURL) as? [CTFontDescriptor] ?? []).isEmpty }) else { return false }
        return urls.allSatisfy { url in
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            guard let error = error?.takeRetainedValue() else { return false }
            return CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
        }
    }
}
