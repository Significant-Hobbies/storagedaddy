import DiskCore
import Testing
@testable import StorageDaddy

@MainActor @Suite struct CleanupReviewFilterTests {
    private func fixture() -> ScanResult {
        ScanResult(rootPath: "/workspace", nodes: [
            DiskNode(id: 0, parent: nil, name: "workspace", isDirectory: true, children: [1, 4, 7]),
            DiskNode(id: 1, parent: 0, name: "a", isDirectory: true, children: [2]),
            DiskNode(id: 2, parent: 1, name: "web", isDirectory: true, children: [3]),
            DiskNode(id: 3, parent: 2, name: "node_modules", isDirectory: true),
            DiskNode(id: 4, parent: 0, name: "b", isDirectory: true, children: [5]),
            DiskNode(id: 5, parent: 4, name: "web", isDirectory: true, children: [6]),
            DiskNode(id: 6, parent: 5, name: "node_modules", isDirectory: true),
            DiskNode(id: 7, parent: 0, name: "build", isDirectory: true),
        ])
    }

    @Test func hiddenSelectionIsRevealedBeforeContinuingReview() {
        let selected = [3, 6]
        let scan = fixture()
        var filter = CleanupReviewFilter(query: "/a/")
        #expect(filter.matchingIDs(selected, in: scan) == [3])
        #expect(filter.hiddenCount(selected, in: scan) == 1)
        let revealed = filter.revealHiddenSelection(selected, in: scan)
        #expect(revealed)
        #expect(filter.query.isEmpty)
        #expect(filter.matchingIDs(selected, in: scan) == selected)
        let alreadyVisible = filter.revealHiddenSelection(selected, in: scan)
        #expect(!alreadyVisible)
        #expect(selected == [3, 6])
    }

    @Test func emptyResultsPreserveAndRevealTheWholeSelection() {
        var filter = CleanupReviewFilter(query: "no such folder")
        #expect(filter.matchingIDs([3, 6], in: fixture()).isEmpty)
        #expect(filter.hiddenCount([3, 6], in: fixture()) == 2)
        let revealed = filter.revealHiddenSelection([3, 6], in: fixture())
        #expect(revealed)
        #expect(filter.matchingIDs([3, 6], in: fixture()) == [3, 6])
    }

    @Test func fullyVisibleSelectionDoesNotNeedAnExtraReviewStep() {
        var filter = CleanupReviewFilter(query: "node_modules")
        #expect(filter.hiddenCount([3, 6], in: fixture()) == 0)
        let revealed = filter.revealHiddenSelection([3, 6], in: fixture())
        #expect(!revealed)
        #expect(filter.query == "node_modules")
    }

    @Test func sameProjectNamesKeepDistinctVisibleLocations() {
        let scan = fixture()
        #expect(CleanupReviewLabels.title(3, in: scan) == "web")
        #expect(CleanupReviewLabels.title(6, in: scan) == "web")
        #expect(CleanupReviewLabels.subtitle(3, in: scan) != CleanupReviewLabels.subtitle(6, in: scan))
    }

    @Test func genericBuildNameDoesNotInventAProjectRole() {
        #expect(CleanupReviewLabels.title(7, in: fixture()) == "build")
        #expect(!CleanupReviewLabels.subtitle(7, in: fixture()).contains("Build output"))
    }
}
