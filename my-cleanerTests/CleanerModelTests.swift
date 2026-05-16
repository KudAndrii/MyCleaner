//
//  CleanerModelTests.swift
//  my-cleanerTests
//
//  Tests for the observable state model — focused on selection,
//  computed totals, state transitions, and orphan group toggling.
//  Filesystem-touching paths (handleDrop, confirmCleanup,
//  confirmOrphanCleanup) are only exercised in their early-bail
//  branches; the full scan paths are covered by the scanner-level
//  integration tests.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("CleanerModel — initial state")
@MainActor
struct CleanerModelInitialStateTests {

    @Test("Starts idle")
    func idle() {
        let m = CleanerModel()
        #expect(m.stage == .idle)
        #expect(m.droppedApp == nil)
        #expect(m.appSize == 0)
        #expect(m.items.isEmpty)
        #expect(m.orphanGroups.isEmpty)
        #expect(m.errorMessage == nil)
        #expect(m.isHovering == false)
    }

    @Test("Selection totals start at zero")
    func zeroTotals() {
        let m = CleanerModel()
        #expect(m.selectedCount == 0)
        #expect(m.selectedSize == 0)
        #expect(m.totalSize == 0)
        #expect(m.trashTotal == 0)
        #expect(m.allSelected == false)
        #expect(m.orphanSelectedCount == 0)
        #expect(m.orphanSelectedSize == 0)
        #expect(m.orphanTotalSize == 0)
        #expect(m.allOrphansSelected == false)
    }
}

@Suite("CleanerModel — per-app selection")
@MainActor
struct CleanerModelPerAppTests {

    private func item(_ size: Int64, selected: Bool, shared: Bool = false) -> RelatedItem {
        var i = RelatedItem(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
            category: .caches,
            sizeBytes: size,
            isDirectory: true,
            isShared: shared
        )
        i.isSelected = selected
        return i
    }

    @Test("selectedCount counts only selected")
    func selectedCount() {
        let m = CleanerModel()
        m.items = [item(10, selected: true), item(20, selected: false), item(30, selected: true)]
        #expect(m.selectedCount == 2)
    }

    @Test("selectedSize sums sizes of selected items")
    func selectedSize() {
        let m = CleanerModel()
        m.items = [item(10, selected: true), item(20, selected: false), item(30, selected: true)]
        #expect(m.selectedSize == 40)
    }

    @Test("totalSize sums every item regardless of selection")
    func totalSize() {
        let m = CleanerModel()
        m.items = [item(10, selected: true), item(20, selected: false), item(30, selected: true)]
        #expect(m.totalSize == 60)
    }

    @Test("trashTotal sums selectedSize + appSize")
    func trashTotal() {
        let m = CleanerModel()
        m.items = [item(10, selected: true), item(30, selected: false)]
        m.appSize = 100
        #expect(m.trashTotal == 110)
    }

    @Test("allSelected is true only when every item is selected (and list is non-empty)")
    func allSelected() {
        let m = CleanerModel()
        #expect(m.allSelected == false) // empty list
        m.items = [item(10, selected: true), item(20, selected: true)]
        #expect(m.allSelected == true)
        m.items = [item(10, selected: true), item(20, selected: false)]
        #expect(m.allSelected == false)
    }

    @Test("toggleAll selects everything when at least one was unselected")
    func toggleAllSelects() {
        let m = CleanerModel()
        m.items = [item(10, selected: true), item(20, selected: false), item(30, selected: false)]
        m.toggleAll()
        #expect(m.items.allSatisfy { $0.isSelected })
    }

    @Test("toggleAll deselects everything when all were selected")
    func toggleAllDeselects() {
        let m = CleanerModel()
        m.items = [item(10, selected: true), item(20, selected: true)]
        m.toggleAll()
        #expect(m.items.allSatisfy { !$0.isSelected })
    }
}

@Suite("CleanerModel — orphan selection")
@MainActor
struct CleanerModelOrphanTests {

    private func item(_ size: Int64) -> RelatedItem {
        RelatedItem(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
            category: .containers,
            sizeBytes: size,
            isDirectory: true,
            isShared: false
        )
    }

    private func group(_ bid: String, sizes: [Int64], selected: Bool) -> OrphanGroup {
        OrphanGroup(
            bundleID: bid,
            items: sizes.map(item),
            isSelected: selected
        )
    }

    @Test("orphanSelectedCount sums items in selected groups only")
    func selectedCount() {
        let m = CleanerModel()
        m.orphanGroups = [
            group("com.a.foo", sizes: [10, 20], selected: true),     // counts 2
            group("com.b.bar", sizes: [10, 20, 30], selected: false),
            group("com.c.baz", sizes: [50], selected: true),         // counts 1
        ]
        #expect(m.orphanSelectedCount == 3)
    }

    @Test("orphanSelectedSize sums sizes in selected groups only")
    func selectedSize() {
        let m = CleanerModel()
        m.orphanGroups = [
            group("com.a.foo", sizes: [10, 20], selected: true),     // 30
            group("com.b.bar", sizes: [100, 100], selected: false),
            group("com.c.baz", sizes: [50], selected: true),         // 50
        ]
        #expect(m.orphanSelectedSize == 80)
    }

    @Test("orphanTotalSize sums every group regardless of selection")
    func totalSize() {
        let m = CleanerModel()
        m.orphanGroups = [
            group("com.a.foo", sizes: [10, 20], selected: true),
            group("com.b.bar", sizes: [100], selected: false),
        ]
        #expect(m.orphanTotalSize == 130)
    }

    @Test("allOrphansSelected logic")
    func allOrphansSelected() {
        let m = CleanerModel()
        #expect(m.allOrphansSelected == false)
        m.orphanGroups = [group("a.b.c", sizes: [1], selected: true)]
        #expect(m.allOrphansSelected == true)
        m.orphanGroups = [
            group("a.b.c", sizes: [1], selected: true),
            group("a.b.d", sizes: [1], selected: false),
        ]
        #expect(m.allOrphansSelected == false)
    }

    @Test("toggleOrphanGroup flips a single group's selection")
    func toggleOrphanGroup() {
        let m = CleanerModel()
        m.orphanGroups = [
            group("com.a.foo", sizes: [10], selected: false),
            group("com.b.bar", sizes: [20], selected: false),
        ]
        m.toggleOrphanGroup(id: "com.a.foo")
        #expect(m.orphanGroups[0].isSelected == true)
        #expect(m.orphanGroups[1].isSelected == false)
        m.toggleOrphanGroup(id: "com.a.foo")
        #expect(m.orphanGroups[0].isSelected == false)
    }

    @Test("toggleOrphanGroup is a no-op for unknown id")
    func toggleUnknown() {
        let m = CleanerModel()
        m.orphanGroups = [group("com.a.foo", sizes: [10], selected: false)]
        m.toggleOrphanGroup(id: "not.a.real.id")
        #expect(m.orphanGroups[0].isSelected == false)
    }

    @Test("toggleAllOrphans selects all when at least one is unselected")
    func toggleAllOrphansSelects() {
        let m = CleanerModel()
        m.orphanGroups = [
            group("a.b.c", sizes: [1], selected: true),
            group("a.b.d", sizes: [1], selected: false),
        ]
        m.toggleAllOrphans()
        #expect(m.orphanGroups.allSatisfy { $0.isSelected })
    }

    @Test("toggleAllOrphans deselects all when all are selected")
    func toggleAllOrphansDeselects() {
        let m = CleanerModel()
        m.orphanGroups = [
            group("a.b.c", sizes: [1], selected: true),
            group("a.b.d", sizes: [1], selected: true),
        ]
        m.toggleAllOrphans()
        #expect(m.orphanGroups.allSatisfy { !$0.isSelected })
    }
}

@Suite("CleanerModel — reset & error paths")
@MainActor
struct CleanerModelResetTests {

    @Test("reset clears every dirty bit")
    func resetClearsEverything() {
        let m = CleanerModel()
        m.droppedApp = nil
        m.appSize = 12345
        m.items = [RelatedItem(
            url: URL(fileURLWithPath: "/tmp/x"),
            category: .caches,
            sizeBytes: 1,
            isDirectory: false
        )]
        m.orphanGroups = [OrphanGroup(bundleID: "com.a.b", items: [], isSelected: true)]
        m.errorMessage = "boom"
        m.isHovering = true
        m.stage = .results

        m.reset()
        #expect(m.droppedApp == nil)
        #expect(m.appSize == 0)
        #expect(m.items.isEmpty)
        #expect(m.orphanGroups.isEmpty)
        #expect(m.errorMessage == nil)
        #expect(m.isHovering == false)
        #expect(m.stage == .idle)
    }

    @Test("handleDrop with a non-.app URL sets the error message and stays idle")
    func handleDropRejectsNonApp() async {
        let m = CleanerModel()
        await m.handleDrop(url: URL(fileURLWithPath: "/tmp/not-an-app.txt"))
        #expect(m.errorMessage == "That doesn't look like an application.")
        #expect(m.stage == .idle)
        #expect(m.droppedApp == nil)
    }

    @Test("confirmOrphanCleanup with no selection stays in orphanResults")
    func confirmOrphanCleanupNoop() async {
        let m = CleanerModel()
        m.orphanGroups = [
            OrphanGroup(bundleID: "com.a.b", items: [], isSelected: false),
        ]
        m.stage = .orphanResults
        await m.confirmOrphanCleanup()
        // Early return: stage shouldn't move to .cleaning or .done.
        #expect(m.stage == .orphanResults)
    }

    @Test("Stage equality treats matching done payloads as equal")
    func stageDoneEquality() {
        let url = URL(fileURLWithPath: "/tmp/foo")
        let a = CleanerModel.Stage.done(.init(
            trashedNormally: 1,
            trashedWithElevation: 0,
            failures: [.init(url: url, message: "x")]
        ))
        let b = CleanerModel.Stage.done(.init(
            trashedNormally: 1,
            trashedWithElevation: 0,
            failures: [.init(url: url, message: "x")]
        ))
        #expect(a == b)
    }
}

@Suite("CleanerModel — login items toggle")
@MainActor
struct CleanerModelLoginItemsTests {

    private func makeApp() throws -> DroppedApp {
        let dir = try TempDir(label: "login-items-app")
        let url = try AppBundleBuilder.makeApp(
            in: dir.url,
            name: "Sample",
            bundleID: "com.example.sample"
        )
        return try #require(DroppedApp(url: url))
    }

    private func makeItem(bundleID: String, parent: String? = nil) -> LoginItemInfo {
        LoginItemInfo(
            bundleID: bundleID,
            parentBundleID: parent,
            teamID: nil,
            displayName: bundleID,
            url: "",
            isEnabled: true
        )
    }

    @Test("Disabled by default; loginItems is empty")
    func defaultsDisabled() {
        let m = CleanerModel()
        #expect(m.loginItemsEnabled == false)
        #expect(m.loginItems.isEmpty)
    }

    @Test("Filters cache by current app when enabled")
    func filtersByCurrentApp() throws {
        let m = CleanerModel()
        m.droppedApp = try makeApp()
        m.cachedAllLoginItems = [
            makeItem(bundleID: "com.example.sample.helper"),
            makeItem(bundleID: "com.unrelated.helper"),
        ]
        m.loginItemsEnabled = true
        #expect(m.loginItems.count == 1)
        #expect(m.loginItems.first?.bundleID == "com.example.sample.helper")
    }

    @Test("Toggle off → loginItems empty even with populated cache")
    func toggleOffEmpty() throws {
        let m = CleanerModel()
        m.droppedApp = try makeApp()
        m.cachedAllLoginItems = [makeItem(bundleID: "com.example.sample.helper")]
        m.loginItemsEnabled = false
        #expect(m.loginItems.isEmpty)
    }

    @Test("No droppedApp → loginItems empty regardless of toggle")
    func noAppEmpty() {
        let m = CleanerModel()
        m.cachedAllLoginItems = [makeItem(bundleID: "com.example.sample.helper")]
        m.loginItemsEnabled = true
        #expect(m.loginItems.isEmpty)
    }

    @Test("reset() preserves enabled flag and cache (no re-prompt on next drop)")
    func resetPreservesLoginState() throws {
        let m = CleanerModel()
        m.droppedApp = try makeApp()
        m.cachedAllLoginItems = [makeItem(bundleID: "com.example.sample.helper")]
        m.loginItemsEnabled = true
        m.currentTeamID = "ABCDEFGHIJ"

        m.reset()

        #expect(m.loginItemsEnabled == true)
        #expect(m.cachedAllLoginItems != nil)
        #expect(m.currentTeamID == nil) // cleared because it's per-app
        #expect(m.droppedApp == nil)
    }

    @Test("setLoginItemsEnabled(false) flips the flag without touching cache")
    func disableKeepsCache() async {
        let m = CleanerModel()
        let cached = [makeItem(bundleID: "com.example.sample.helper")]
        m.cachedAllLoginItems = cached
        m.loginItemsEnabled = true

        await m.setLoginItemsEnabled(false)

        #expect(m.loginItemsEnabled == false)
        #expect(m.cachedAllLoginItems?.count == cached.count)
    }

    @Test("setLoginItemsEnabled(true) reuses cache without re-fetching")
    func enableReusesCache() async throws {
        // If the cache is already populated, enabling must NOT shell
        // out to sfltool — verifying that here indirectly by checking
        // that the operation completes synchronously-fast and leaves
        // the cache intact (a real shell-out would either prompt or
        // exit non-zero in the test environment).
        let m = CleanerModel()
        m.droppedApp = try makeApp()
        let cached = [makeItem(bundleID: "com.example.sample.helper")]
        m.cachedAllLoginItems = cached
        m.loginItemsEnabled = false

        await m.setLoginItemsEnabled(true)

        #expect(m.loginItemsEnabled == true)
        #expect(m.cachedAllLoginItems?.count == cached.count)
        #expect(m.loginItems.count == 1)
    }
}
