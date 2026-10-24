import SwiftUI
import DiskCore

struct DeveloperReportView: View {
    @EnvironmentObject private var m: ExplorerModel
    @State private var mode: ReportMode = .projects
    @State private var selectedProjectID: Int?
    @State private var expandedFindingID: Int?
    @State private var toolFilter = ""

    private enum ReportMode {
        case projects
        case tools
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your projects & tools")
                        .font(.title2.weight(.semibold))
                    Text("Dependencies, builds and tool data. Project totals include recognized artifacts, not all source files.")
                        .font(.callout)
                        .foregroundStyle(Tints.secondaryText)
                }
                Spacer(minLength: 12)
                modePicker
            }

            if let report = m.developerReport {
                if mode == .projects {
                    projects(report)
                } else {
                    tools(report)
                }
            } else {
                Text("Scan a folder to build the developer report.")
                    .font(.callout)
                    .foregroundStyle(Tints.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 28)
            }
        }
        .onAppear { selectedProjectID = m.developerReport?.projects.first?.id }
        .onChange(of: m.scan?.started) { _, _ in
            selectedProjectID = m.developerReport?.projects.first?.id; expandedFindingID = nil
        }
        .padding(20)
        .background(AppColors.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.18), lineWidth: 1))
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            Button("Projects") { mode = .projects }
                .buttonStyle(StorageButtonStyle(prominent: mode == .projects))
                .accessibilityAddTraits(mode == .projects ? .isSelected : [])
            Button("Tools") { mode = .tools }
                .buttonStyle(StorageButtonStyle(prominent: mode == .tools))
                .accessibilityAddTraits(mode == .tools ? .isSelected : [])
        }
    }

    @ViewBuilder
    private func projects(_ report: DeveloperReport) -> some View {
        if report.projects.isEmpty {
            Text("No project-scoped findings in this folder.")
                .font(.callout)
                .foregroundStyle(Tints.secondaryText)
                .padding(.vertical, 24)
        } else {
            let findingsByID = m.reportFindingsByID
            Text("Largest recognized project footprints")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tints.secondaryText)
                .textCase(.uppercase)
                .tracking(1)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(report.projects.prefix(30)) { project in projectRow(project) }
                }
            }.frame(height: min(300, CGFloat(report.projects.count) * 90))
            if report.projects.count > 30 {
                Text("Showing the 30 largest projects.")
                    .font(.caption)
                    .foregroundStyle(Tints.secondaryText)
            }
            if let project = selectedProject(in: report) {
                Divider().overlay(Tints.mint.opacity(0.18))
                projectDetail(project, findingsByID: findingsByID)
            }
        }
    }

    @ViewBuilder
    private func tools(_ report: DeveloperReport) -> some View {
        let projectNames = m.reportProjectNames
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shared and project findings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tints.secondaryText)
                    .textCase(.uppercase)
                    .tracking(1)
                Spacer()
                TextField("Filter tools", text: $toolFilter)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 9)
                    .frame(width: 170, height: 29)
                    .background(AppColors.canvas)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tints.mint.opacity(0.4), lineWidth: 1))
            }
            let filtered = Array(report.findings.lazy.filter { toolFilter.isEmpty || $0.tool.localizedCaseInsensitiveContains(toolFilter) }.prefix(30))
            if filtered.isEmpty {
                Text("No findings match this tool filter.")
                    .font(.callout)
                    .foregroundStyle(Tints.secondaryText)
                    .padding(.vertical, 24)
            } else {
                ForEach(filtered.prefix(30)) { finding in
                    findingRow(finding, projectName: finding.projectID.flatMap { projectNames[$0] })
                }
                if filtered.count == 30 {
                    Text("Showing up to 30 largest matching findings.")
                        .font(.caption)
                        .foregroundStyle(Tints.secondaryText)
                }
            }
        }
    }

    private func projectRow(_ project: DeveloperProject) -> some View {
        Button { selectedProjectID = project.id } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Tints.mint)
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(DiskFormat.bytes(project.allocatedBytes))
                        .font(.headline.monospacedDigit())
                }
                HStack(spacing: 7) {
                    categoryChips(project)
                    Spacer(minLength: 8)
                    growthLabel(for: project.id)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedProjectID == project.id ? Tints.mint.opacity(0.08) : AppColors.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedProjectID == project.id ? Tints.mint : Tints.mint.opacity(0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedProjectID == project.id ? .isSelected : [])
    }

    @ViewBuilder
    private func categoryChips(_ project: DeveloperProject) -> some View {
        let categories = DeveloperCategory.allCases.filter { (project.categoryBytes[$0] ?? 0) > 0 }
        ForEach(categories.prefix(2), id: \.self) { category in
            if let bytes = project.categoryBytes[category], bytes > 0 {
                Text(category.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(category.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(category.color.opacity(0.1), in: Capsule())
            }
        }
    }

    private func growthLabel(for projectID: Int) -> some View {
        Group {
            if let change = m.projectGrowth[projectID] {
                Text(change == 0 ? "No change" : (change > 0 ? "+" : "") + DiskFormat.bytes(change))
                    .foregroundStyle(change > 0 ? Tints.coral : change < 0 ? Tints.mint : Tints.secondaryText)
            } else {
                Text("Rescan to compare").foregroundStyle(Tints.secondaryText)
            }
        }
        .font(.caption.monospacedDigit())
        .help("Net recognized storage change since the previous scan of this same folder. This does not measure write activity.")
    }

    private func selectedProject(in report: DeveloperReport) -> DeveloperProject? {
        if let selectedProjectID, let project = report.projects.first(where: { $0.id == selectedProjectID }) {
            return project
        }
        return report.projects.first
    }

    private func projectDetail(_ project: DeveloperProject, findingsByID: [Int: DeveloperFinding]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name).font(.title3.weight(.semibold))
                Spacer()
                Text("Recognized footprint · " + DiskFormat.bytes(project.allocatedBytes))
                    .font(.caption)
                    .foregroundStyle(Tints.secondaryText)
            }
            Text("Why these paths were recognized and what to review before making changes.")
                .font(.callout)
                .foregroundStyle(Tints.secondaryText)
            ForEach(project.findingIDs.prefix(30), id: \.self) { id in
                if let finding = findingsByID[id] {
                    findingRow(finding)
                }
            }
            if project.findingIDs.count > 30 {
                Text("Showing the 30 largest findings for this project.")
                    .font(.caption)
                    .foregroundStyle(Tints.secondaryText)
            }
        }
    }

    private func findingRow(_ finding: DeveloperFinding, projectName: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedFindingID = expandedFindingID == finding.id ? nil : finding.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: finding.category.symbol)
                        .foregroundStyle(finding.category.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(finding.tool).fontWeight(.semibold)
                            if let projectName {
                                Text("· " + projectName).foregroundStyle(Tints.secondaryText)
                            }
                        }
                        Text(finding.category.title).font(.caption).foregroundStyle(Tints.secondaryText)
                        CleanupFlag(category: finding.category)
                    }
                    Spacer(minLength: 8)
                    Text(DiskFormat.bytes(finding.allocatedBytes)).monospacedDigit()
                    Image(systemName: expandedFindingID == finding.id ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Tints.secondaryText)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expandedFindingID == finding.id {
                VStack(alignment: .leading, spacing: 10) {
                    detail("Why it was recognized", finding.evidence)
                    detail("What to consider", finding.consequence)
                    HStack(spacing: 16) {
                        Label("Item modified " + finding.lastModified.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        Label("Match confidence: " + finding.confidence, systemImage: "info.circle")
                            .help("Confidence describes the path match, not whether deleting it is safe.")
                    }
                    .font(.caption)
                    .foregroundStyle(Tints.secondaryText)
                    HStack(spacing: 9) {
                        Button("Inspect") { inspect(finding) }
                            .buttonStyle(StorageButtonStyle())
                            .disabled(!canOpen(finding))
                        Button(m.staged.contains(finding.id) ? "Added to Cleanup" : "Add to Cleanup") { m.stage(finding.id) }
                            .disabled(m.busy || m.monitoring || m.staged.contains(finding.id))
                        Button("Reveal in Finder") { m.reveal(finding.id) }
                            .buttonStyle(StorageButtonStyle())
                            .disabled(m.scan == nil)
                    }
                }
                .padding(.leading, 30)
                .padding(.bottom, 12)
            }
        }
        .contextMenu {
            if let scan = m.scan, scan.nodes.indices.contains(finding.id) { StorageItemMenu(node: scan.nodes[finding.id]) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Tints.mint.opacity(0.14)).frame(height: 1) }
    }

    private func detail(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Tints.mint)
            Text(body).font(.callout).foregroundStyle(Tints.secondaryText)
        }
    }

    private func canOpen(_ finding: DeveloperFinding) -> Bool {
        guard let scan = m.scan else { return false }
        return scan.nodes.indices.contains(finding.id)
    }

    private func inspect(_ finding: DeveloperFinding) {
        guard let scan = m.scan, scan.nodes.indices.contains(finding.id) else { return }
        m.openStorage(.explore)
        m.open(scan.nodes[finding.id])
    }
}
