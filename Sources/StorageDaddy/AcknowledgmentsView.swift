import AppKit
import SwiftUI
import SaaSMakerUI

struct AcknowledgmentsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("BUILT WITH THANKS").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Tints.mint)
                HStack { SMSectionHeader("Acknowledgments", size: 32).accessibilityLabel("Acknowledgments"); DoodleArt(topic: .thanks).frame(width: 90, height: 90); Spacer() }
                Text("The foundations behind storagedaddy.").foregroundStyle(Tints.secondaryText)
                credit("Swift & Swift Package Manager", "Language, concurrency, and build tools. Swift is open source under Apache 2.0 with the Runtime Library Exception.", "https://www.swift.org/about/")
                credit("Apple platform frameworks", "SwiftUI and AppKit power the native interface. Foundation and Darwin provide filesystem access; Quick Look provides previews. These are Apple platform SDKs.", "https://developer.apple.com/documentation/")
                credit("Memory Pack · Memory Map", "The bundled local conversation archiver extracts prompts, replies and session metadata from Claude Code and Codex transcripts. Memory Pack is MIT-licensed; its Rust dependencies are credited in the bundled license notices.", "https://github.com/Significant-Hobbies/chatgpt-memory-insights/tree/main/packer")
                if let notices = Bundle.main.url(forResource: "MemoryPack-THIRD_PARTY_NOTICES", withExtension: "txt") {
                    Button("open memory pack license notices") { NSWorkspace.shared.open(notices) }.accessibilityLabel("Open Memory Pack license notices").buttonStyle(StorageButtonStyle())
                }
                credit("FinderSearch & fsearch", "FinderSearch by zeusinsight provides the Swift transport pattern. Its MIT-licensed fsearch engine by Noah Dunnagan powers local fuzzy filename search over StorageDaddy scan metadata; it does not run a separate whole-disk daemon.", "https://github.com/zeusinsight/FinderSearch")
                if let notices = Bundle.main.url(forResource: "FinderSearch-THIRD_PARTY_NOTICES", withExtension: "txt") {
                    Button("Open FinderSearch license notices") { NSWorkspace.shared.open(notices) }.buttonStyle(StorageButtonStyle())
                }
                credit("Sparkle", "The open-source macOS updater checks for new versions and verifies signed downloads before installation. Sparkle uses a permissive license; its notices are bundled with the framework.", "https://sparkle-project.org/")
                if let license = Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: "txt") {
                    Button("open sparkle license") { NSWorkspace.shared.open(license) }.accessibilityLabel("Open Sparkle license").buttonStyle(StorageButtonStyle())
                }
                credit("App Health Swift SDK", "The MIT-licensed Foundation SDK supports optional foreground-session heartbeats. Reporting is disabled unless a per-user native public key is configured; it receives no file or scan details.", "https://github.com/sass-maker/app-health")
                if let license = Bundle.main.url(forResource: "AppHealth-LICENSE", withExtension: "txt") {
                    Button("open app health license") { NSWorkspace.shared.open(license) }.accessibilityLabel("Open App Health license").buttonStyle(StorageButtonStyle())
                }
                credit("Mole", "An inspiration and comparison tool for Mac storage workflows. No Mole code is included in this app. Mole is licensed under GPL-3.0.", "https://github.com/tw93/Mole")
                credit("dua & Dust", "Open-source disk analyzers evaluated for scan performance. The dua adapter is an isolated experiment; neither analyzer is bundled in this app.", "https://github.com/Byron/dua-cli")
                outdoorsCredit
                Link("Dust source and license", destination: URL(string: "https://github.com/bootandy/dust")!)
                credit("Development assistance", "OpenAI Codex assisted implementation and review. The app icon and doodle illustrations were created with OpenAI image generation. Scanning and developer insights run locally without AI calls.", "https://openai.com/codex/")
                Text("Memory Pack is bundled for conversation exports. Scanning uses Apple platform frameworks. Experimental tools are credited separately from shipped components.").font(.callout).foregroundStyle(Tints.secondaryText)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color.black)
    }
    private var outdoorsCredit: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI provider marks").font(.title3.weight(.semibold)).foregroundStyle(Tints.mint)
            Text("Claude artwork is provided by Anthropic’s official media kit. The ChatGPT mark comes from OpenAI’s signed app and identifies Codex history here. Claude and Anthropic are trademarks of Anthropic PBC; ChatGPT, Codex and OpenAI are trademarks of OpenAI. Their display identifies local history sources and does not imply endorsement.")
                .foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Anthropic media kit", destination: URL(string: "https://www.anthropic.com/press-kit")!)
                Link("OpenAI design guidelines", destination: URL(string: "https://openai.com/brand/")!)
            }
        }
    }
    private func credit(_ title: String, _ description: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(title, destination: URL(string: url)!).font(.title3.weight(.semibold)).foregroundStyle(Tints.mint)
            Text(description).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
}
