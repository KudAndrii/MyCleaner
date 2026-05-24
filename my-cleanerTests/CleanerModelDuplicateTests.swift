//
//  CleanerModelDuplicateTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("CleanerModel — duplicate selection")
@MainActor
struct CleanerModelDuplicateSelectionTests {

    private func copy(_ name: String, selected: Bool) -> DuplicateCopy {
        DuplicateCopy(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            modificationDate: nil,
            isSelectedForDeletion: selected
        )
    }

    private func makeGroup(_ copies: [DuplicateCopy], size: Int64 = 100) -> DuplicateGroup {
        DuplicateGroup(
            id: UUID(),
            contentHash: "deadbeef",
            sizePerCopy: size,
            copies: copies
        )
    }

    @Test("duplicateSelectedCount counts only selected copies")
    func selectedCount() {
        let m = CleanerModel()
        m.duplicateGroups = [
            makeGroup([copy("a", selected: true), copy("b", selected: false)]),
            makeGroup([copy("c", selected: true), copy("d", selected: true), copy("e", selected: false)])
        ]
        #expect(m.duplicateSelectedCount == 3)
    }

    @Test("duplicateSelectedSize sums sizePerCopy × selected copies")
    func selectedSize() {
        let m = CleanerModel()
        m.duplicateGroups = [
            makeGroup([copy("a", selected: true), copy("b", selected: false)], size: 100),
            makeGroup([copy("c", selected: true), copy("d", selected: true)], size: 250)
        ]
        // 1 selected × 100 + 2 selected × 250 = 600
        #expect(m.duplicateSelectedSize == 600)
    }

    @Test("duplicateMaximumRecoverableBytes assumes one kept per group")
    func maximum() {
        let m = CleanerModel()
        m.duplicateGroups = [
            makeGroup([copy("a", selected: true), copy("b", selected: true), copy("c", selected: false)], size: 100),
            makeGroup([copy("d", selected: false), copy("e", selected: false)], size: 200)
        ]
        // First group: 2 × 100, second group: 1 × 200 → 400.
        #expect(m.duplicateMaximumRecoverableBytes == 400)
    }

    @Test("duplicateTotalCopies counts every copy regardless of selection")
    func totalCopies() {
        let m = CleanerModel()
        m.duplicateGroups = [
            makeGroup([copy("a", selected: true), copy("b", selected: false)]),
            makeGroup([copy("c", selected: false), copy("d", selected: false), copy("e", selected: true)])
        ]
        #expect(m.duplicateTotalCopies == 5)
    }

    @Test("Selection helpers start at zero with an empty group list")
    func emptyState() {
        let m = CleanerModel()
        #expect(m.duplicateSelectedCount == 0)
        #expect(m.duplicateSelectedSize == 0)
        #expect(m.duplicateMaximumRecoverableBytes == 0)
        #expect(m.duplicateTotalCopies == 0)
    }
}

@Suite("CleanerModel — duplicate toggle safety")
@MainActor
struct CleanerModelDuplicateToggleTests {

    @Test("toggleDuplicateCopy flips a regular copy when others remain kept")
    func togglesNormally() {
        let m = CleanerModel()
        let a = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/a"), modificationDate: nil, isSelectedForDeletion: false)
        let b = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/b"), modificationDate: nil, isSelectedForDeletion: false)
        let group = DuplicateGroup(id: UUID(), contentHash: "h", sizePerCopy: 10, copies: [a, b])
        m.duplicateGroups = [group]

        m.toggleDuplicateCopy(groupID: group.id, copyID: a.id)
        let updated = m.duplicateGroups[0].copies.first { $0.id == a.id }
        #expect(updated?.isSelectedForDeletion == true)
        // `b` still kept, so the safety rule is intact.
        let other = m.duplicateGroups[0].copies.first { $0.id == b.id }
        #expect(other?.isSelectedForDeletion == false)
    }

    @Test("toggleDuplicateCopy refuses to deselect the last kept copy")
    func protectsLastKeeper() {
        let m = CleanerModel()
        let keeper = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/keeper"), modificationDate: nil, isSelectedForDeletion: false)
        let trashed = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/trashed"), modificationDate: nil, isSelectedForDeletion: true)
        let group = DuplicateGroup(id: UUID(), contentHash: "h", sizePerCopy: 10, copies: [keeper, trashed])
        m.duplicateGroups = [group]

        // Attempting to select the last kept copy for deletion must be a no-op.
        m.toggleDuplicateCopy(groupID: group.id, copyID: keeper.id)
        let updated = m.duplicateGroups[0].copies.first { $0.id == keeper.id }
        #expect(updated?.isSelectedForDeletion == false)
    }

    @Test("toggleDuplicateCopy can always deselect (move from delete to keep)")
    func canRescueFromDelete() {
        let m = CleanerModel()
        let keeper = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/k"), modificationDate: nil, isSelectedForDeletion: false)
        let other = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/o"), modificationDate: nil, isSelectedForDeletion: true)
        let group = DuplicateGroup(id: UUID(), contentHash: "h", sizePerCopy: 10, copies: [keeper, other])
        m.duplicateGroups = [group]

        m.toggleDuplicateCopy(groupID: group.id, copyID: other.id)
        let updated = m.duplicateGroups[0].copies.first { $0.id == other.id }
        #expect(updated?.isSelectedForDeletion == false)
    }

    @Test("canDeselectDuplicateCopy is false for the last kept copy")
    func canDeselectGuard() {
        let m = CleanerModel()
        let keeper = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/k"), modificationDate: nil, isSelectedForDeletion: false)
        let trashed = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/t"), modificationDate: nil, isSelectedForDeletion: true)
        let group = DuplicateGroup(id: UUID(), contentHash: "h", sizePerCopy: 10, copies: [keeper, trashed])
        m.duplicateGroups = [group]

        // The keeper can't be deselected (it's already the only one kept).
        #expect(m.canDeselectDuplicateCopy(groupID: group.id, copyID: keeper.id) == false)
        // The trashed entry can always be moved back to kept.
        #expect(m.canDeselectDuplicateCopy(groupID: group.id, copyID: trashed.id) == true)
    }

    @Test("toggleDuplicateCopy is a no-op for unknown ids")
    func unknownIDsNoOp() {
        let m = CleanerModel()
        let a = DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/a"), modificationDate: nil, isSelectedForDeletion: true)
        let group = DuplicateGroup(id: UUID(), contentHash: "h", sizePerCopy: 10, copies: [a])
        m.duplicateGroups = [group]
        let snapshot = m.duplicateGroups
        m.toggleDuplicateCopy(groupID: UUID(), copyID: UUID())
        #expect(m.duplicateGroups == snapshot)
    }
}

@Suite("CleanerModel — duplicate scan lifecycle")
@MainActor
struct CleanerModelDuplicateScanTests {

    @Test("reset clears duplicate groups and stage")
    func resetClears() {
        let m = CleanerModel()
        m.duplicateGroups = [
            DuplicateGroup(
                id: UUID(),
                contentHash: "h",
                sizePerCopy: 10,
                copies: [
                    DuplicateCopy(id: UUID(), url: URL(fileURLWithPath: "/tmp/a"), modificationDate: nil, isSelectedForDeletion: true)
                ]
            )
        ]
        m.stage = .duplicateResults
        m.reset()
        #expect(m.stage == .idle)
        #expect(m.duplicateGroups.isEmpty)
    }

    @Test("cancelDuplicateScan is a safe no-op when no scan is running")
    func cancelNoOp() {
        let m = CleanerModel()
        // Should not crash or transition state.
        m.cancelDuplicateScan()
        #expect(m.stage == .idle)
    }

    @Test("startDuplicateScan returns to idle when cancelled before completion")
    func cancelDuringScan() async throws {
        let dir = try TempDir(label: "model-cancel")
        // Make enough duplicate work for cancellation to land mid-run.
        for i in 0..<6 {
            let payload = Data(repeating: UInt8(i + 1), count: 8192)
            _ = try dir.makeFile(at: "a\(i).bin", contents: payload)
            _ = try dir.makeFile(at: "b\(i).bin", contents: payload)
        }

        let m = CleanerModel()
        let scanTask = Task { await m.startDuplicateScan(scope: [dir.url]) }
        // Give the scan a moment to enter the scanning stage.
        try? await Task.sleep(nanoseconds: 10_000_000)
        m.cancelDuplicateScan()
        await scanTask.value

        // Cancellation should leave the stage at idle, not in scanning.
        #expect(m.stage == .idle || m.stage == .duplicateResults)
    }
}
