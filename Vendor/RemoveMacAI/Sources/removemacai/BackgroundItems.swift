import Foundation

/// A launch agent or daemon another app installed: updaters, helpers and
/// sync tools that run whether or not their app is open.
struct BackgroundItem: Identifiable, Hashable {
  let label: String
  let plist: String
  let program: String
  var arguments: [String] = []
  /// Daemons run for the whole Mac and need an administrator to change.
  let system: Bool

  var id: String { "background:" + (system ? "system/" : "gui/") + label }
  var target: String { system ? "system/\(label)" : "gui/\(Engine.uid)/\(label)" }
  var domain: String { system ? "system" : "gui/\(Engine.uid)" }

  static let interpreters: Set<String> = ["sh", "bash", "zsh", "python3", "python", "node", "osascript", "perl", "ruby"]

  /// Whether it only keeps its app up to date, judged by its label and the
  /// name of what it runs. Anything else (a VPN, Docker's socket, a sync or
  /// licensing helper) can be what makes its app work, so it gets a warning.
  var isUpdater: Bool {
    [label, (program as NSString).lastPathComponent].contains { $0.lowercased().contains("update") }
  }

  /// What switching it off can break, or nil for an updater.
  var warning: String? {
    isUpdater ? nil : "Not an updater. Turning it off can stop \(owner) working."
  }

  /// The app or program it runs, as people know it.
  var owner: String {
    if let app = program.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
      return String(app.dropLast(4))
    }
    var name = (program as NSString).lastPathComponent
    if Self.interpreters.contains(name), let script = arguments.dropFirst().first(where: { $0.contains("/") }) {
      name = (script as NSString).lastPathComponent
    }
    if name.isEmpty || name == label {
      let parts = label.split(separator: ".")
      return parts.count >= 3 ? String(parts[2]) : label
    }
    return name
  }
}

enum BackgroundItems {
  static let folders: [(String, Bool)] = [
    (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path, false),
    ("/Library/LaunchAgents", false),
    ("/Library/LaunchDaemons", true),
  ]

  /// Every third-party agent and daemon, Apple's own left out.
  static func scan() -> [BackgroundItem] {
    var items: [BackgroundItem] = []
    for (folder, system) in folders {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
      for name in names.sorted() where name.hasSuffix(".plist") {
        let path = folder + "/" + name
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
          let label = dict["Label"] as? String, !label.hasPrefix("com.apple.")
        else { continue }
        let arguments = dict["ProgramArguments"] as? [String] ?? []
        let program = dict["Program"] as? String ?? arguments.first ?? ""
        items.append(BackgroundItem(label: label, plist: path, program: program, arguments: arguments, system: system))
      }
    }
    return items
  }

  static func disabled(in domain: String) -> Set<String> {
    let out = Shell.run("/bin/launchctl", ["print-disabled", domain]).output
    var labels = Set<String>()
    for line in out.split(separator: "\n") {
      let parts = line.components(separatedBy: "=>")
      guard parts.count == 2 else { continue }
      let value = parts[1].trimmingCharacters(in: .whitespaces)
      if value == "disabled" || value == "true" {
        labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
      }
    }
    return labels
  }

  /// Labels switched off, by domain.
  static func disabledLabels() -> (user: Set<String>, system: Set<String>) {
    (disabled(in: "gui/\(Engine.uid)"), disabled(in: "system"))
  }

  static func isDisabled(_ item: BackgroundItem, _ labels: (user: Set<String>, system: Set<String>)) -> Bool {
    (item.system ? labels.system : labels.user).contains(item.label)
  }

  /// Switches items off or back on. Daemons share one administrator prompt.
  static func set(_ items: [BackgroundItem], disabled: Bool) -> [String] {
    var journal = Engine.loadJournal()
    if let blocked = Engine.journalBlocked { return [blocked] }
    let current = Set(scan())
    guard items.allSatisfy({ current.contains($0) }) else { return ["Background items changed since review. Refresh and review again."] }
    let labels = disabledLabels()
    var problems: [String] = []
    var adminCommands: [String] = []
    for item in items {
      if disabled, journal.entries[item.id] == nil {
        journal.entries[item.id] = .init(
          tweak: item.id, date: Date(), previous: .background(disabled: isDisabled(item, labels)))
      }
      guard Engine.save(journal) else { return [Engine.journalBlocked ?? "Could not save undo history."] }
      let commands: [[String]] =
        disabled
        ? [["disable", item.target], ["bootout", item.target]]
        : [["enable", item.target], ["bootstrap", item.domain, item.plist]]
      if item.system {
        adminCommands += commands.map { (["/bin/launchctl"] + $0).map(Shell.quote).joined(separator: " ") }
      } else {
        for args in commands {
          let result = Shell.run("/bin/launchctl", args)
          // bootout can fail when a job was already stopped; enable/disable must succeed.
          if !result.ok && args.first != "bootout" {
            problems.append("\(item.label): \(result.output.trimmed)")
          }
        }
      }

    }
    if !adminCommands.isEmpty {
      let result = Shell.admin(adminCommands, prompt: "RemoveMacAI needs your password to change background items for all users.")
      if !result.ok { problems.append(Shell.adminError(result)) }
    }
    let after = disabledLabels()
    if !disabled {
      for item in items where !isDisabled(item, after) && problems.isEmpty { journal.entries[item.id] = nil }
    }
    if !Engine.save(journal) { problems.append(Engine.journalBlocked ?? "Could not save undo history.") }
    for item in items where isDisabled(item, after) != disabled {
      problems.append("\(item.label) is still \(disabled ? "on" : "off")")
    }
    return problems
  }

  /// Undoes one journal entry, for revert-everything.
  static func revert(_ id: String, journal: inout Engine.Journal) -> [String] {
    guard let entry = journal.entries[id] else { return [] }
    if case .background(let wasDisabled) = entry.previous, wasDisabled {
      journal.entries[id] = nil
      return []
    }
    guard let item = scan().first(where: { $0.id == id }) else {
      return ["The background item \(id) is missing; its undo history was retained."]
    }
    guard Engine.save(journal) else { return [Engine.journalBlocked ?? "Could not save undo history."] }
    let problems = set([item], disabled: false)
    journal = Engine.loadJournal()
    return problems
  }
}
