//
//  DuplicateModelsTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("DuplicateGroup")
struct DuplicateGroupTests {

    private func copy(
        _ name: String,
        selected: Bool = true,
        modified: Date? = nil
    ) -> DuplicateCopy {
        DuplicateCopy(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            modificationDate: modified,
            isSelectedForDeletion: selected
        )
    }

    @Test("wastedBytes scales with selection count")
    func wastedBytes() {
        let group = DuplicateGroup(
            id: UUID(),
            contentHash: "abc",
            sizePerCopy: 100,
            copies: [
                copy("a", selected: true),
                copy("b", selected: true),
                copy("c", selected: false)
            ]
        )
        #expect(group.wastedBytes == 200)
    }

    @Test("wastedBytes is zero when nothing is selected")
    func zeroWaste() {
        let group = DuplicateGroup(
            id: UUID(),
            contentHash: "abc",
            sizePerCopy: 1000,
            copies: [copy("a", selected: false), copy("b", selected: false)]
        )
        #expect(group.wastedBytes == 0)
    }

    @Test("maximumRecoverableBytes assumes one kept copy")
    func maximumRecoverable() {
        let group = DuplicateGroup(
            id: UUID(),
            contentHash: "abc",
            sizePerCopy: 50,
            copies: [copy("a"), copy("b"), copy("c"), copy("d")]
        )
        #expect(group.maximumRecoverableBytes == 150)
    }

    @Test("maximumRecoverableBytes is zero for a single-copy group")
    func singleCopyMax() {
        let group = DuplicateGroup(
            id: UUID(),
            contentHash: "abc",
            sizePerCopy: 999,
            copies: [copy("only")]
        )
        #expect(group.maximumRecoverableBytes == 0)
    }
}

@Suite("DuplicateScopeFolder")
struct DuplicateScopeFolderTests {

    @Test("URL is under the user's home directory")
    func urlIsUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in DuplicateScopeFolder.allCases {
            #expect(folder.url.path.hasPrefix(home))
            #expect(folder.url.lastPathComponent == folder.title)
        }
    }

    @Test("Every case has a title and SF symbol")
    func titlesAndSymbols() {
        for folder in DuplicateScopeFolder.allCases {
            #expect(!folder.title.isEmpty)
            #expect(!folder.symbol.isEmpty)
        }
    }
}
