//
//  AdminTrashTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("AdminTrash.shellQuote")
struct ShellQuoteTests {

    @Test("Wraps simple paths in single quotes")
    func wrapsSimple() {
        #expect(AdminTrash.shellQuote("/tmp/foo") == "'/tmp/foo'")
    }

    @Test("Escapes embedded single quotes")
    func escapesSingleQuotes() {
        // POSIX-safe escape: close, escaped-quote, reopen.
        // 'a'\''b' represents the literal a'b.
        #expect(AdminTrash.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test("Leaves double quotes alone (single-quote context)")
    func leavesDoubleQuotes() {
        #expect(AdminTrash.shellQuote("a\"b") == "'a\"b'")
    }

    @Test("Leaves spaces and dollar signs alone (single-quote context)")
    func leavesSpacesAndDollars() {
        #expect(AdminTrash.shellQuote("/path with $HOME") == "'/path with $HOME'")
    }
}

@Suite("AdminTrash.appleScriptString")
struct AppleScriptStringTests {

    @Test("Wraps simple strings in double quotes")
    func wrapsSimple() {
        #expect(AdminTrash.appleScriptString("hello") == "\"hello\"")
    }

    @Test("Escapes backslashes before double quotes")
    func escapesBackslash() {
        #expect(AdminTrash.appleScriptString("a\\b") == "\"a\\\\b\"")
    }

    @Test("Escapes embedded double quotes")
    func escapesDoubleQuotes() {
        #expect(AdminTrash.appleScriptString("a\"b") == "\"a\\\"b\"")
    }

    @Test("Backslash + double quote order")
    func combinedEscape() {
        // Input: a\"b — we expect backslashes escaped first, so the
        // backslash becomes \\, and the double quote becomes \".
        // Final wrapper: "a\\\"b"
        #expect(AdminTrash.appleScriptString("a\\\"b") == "\"a\\\\\\\"b\"")
    }
}

@Suite("AdminTrash.uniqueTrashDestination")
struct UniqueTrashDestinationTests {

    @Test("Returns the original name if no collision")
    func noCollision() throws {
        let dir = try TempDir(label: "trash-unique-1")
        let original = URL(fileURLWithPath: "/somewhere/file.txt")
        let dest = AdminTrash.uniqueTrashDestination(for: original, trashDir: dir.url.path)
        #expect(dest == dir.url.path + "/file.txt")
    }

    @Test("Appends a numeric suffix on collision")
    func appendsSuffix() throws {
        let dir = try TempDir(label: "trash-unique-2")
        // Pre-create the destination so the function has to pick the next free slot.
        _ = try dir.makeFile(at: "file.txt")
        let original = URL(fileURLWithPath: "/somewhere/file.txt")
        let dest = AdminTrash.uniqueTrashDestination(for: original, trashDir: dir.url.path)
        #expect(dest == dir.url.path + "/file 2.txt")
    }

    @Test("Picks the first non-colliding numeric suffix")
    func picksFirstFreeSlot() throws {
        let dir = try TempDir(label: "trash-unique-3")
        _ = try dir.makeFile(at: "file.txt")
        _ = try dir.makeFile(at: "file 2.txt")
        _ = try dir.makeFile(at: "file 3.txt")
        let original = URL(fileURLWithPath: "/somewhere/file.txt")
        let dest = AdminTrash.uniqueTrashDestination(for: original, trashDir: dir.url.path)
        #expect(dest == dir.url.path + "/file 4.txt")
    }

    @Test("Handles extensionless names")
    func extensionless() throws {
        let dir = try TempDir(label: "trash-unique-4")
        _ = try dir.makeFile(at: "noext")
        let original = URL(fileURLWithPath: "/somewhere/noext")
        let dest = AdminTrash.uniqueTrashDestination(for: original, trashDir: dir.url.path)
        #expect(dest == dir.url.path + "/noext 2")
    }
}
