//
//  OrphanGroupTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("OrphanGroup")
struct OrphanGroupTests {

    private func item(_ size: Int64, _ url: String = "/tmp/x") -> RelatedItem {
        RelatedItem(
            url: URL(fileURLWithPath: url),
            category: .containers,
            sizeBytes: size,
            isDirectory: true,
            isShared: false
        )
    }

    @Test("totalSize sums item sizes")
    func totalSize() {
        let group = OrphanGroup(
            bundleID: "com.example.foo",
            items: [item(100), item(200), item(300)],
            isSelected: false
        )
        #expect(group.totalSize == 600)
    }

    @Test("id is the bundle ID")
    func idIsBundleID() {
        let group = OrphanGroup(
            bundleID: "com.example.foo",
            items: [item(1)],
            isSelected: false
        )
        #expect(group.id == "com.example.foo")
    }

    @Test("Empty items yields zero total")
    func emptyTotal() {
        let group = OrphanGroup(bundleID: "com.example.foo", items: [], isSelected: false)
        #expect(group.totalSize == 0)
    }
}

@Suite("OrphanScanResult")
struct OrphanScanResultTests {

    private func item(_ size: Int64) -> RelatedItem {
        RelatedItem(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
            category: .containers,
            sizeBytes: size,
            isDirectory: true,
            isShared: false
        )
    }

    @Test("totalSize sums across every group")
    func sumsAcrossGroups() {
        let result = OrphanScanResult(groups: [
            OrphanGroup(bundleID: "com.a.foo", items: [item(10), item(20)], isSelected: false),
            OrphanGroup(bundleID: "com.b.bar", items: [item(30)], isSelected: true),
        ])
        #expect(result.totalSize == 60)
    }

    @Test("Empty groups list yields zero total")
    func empty() {
        let result = OrphanScanResult(groups: [])
        #expect(result.totalSize == 0)
    }
}
