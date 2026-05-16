//
//  SpotlightSearchTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import my_cleaner

@Suite("SpotlightSearch.bundleIDPredicate")
struct BundleIDPredicateTests {

    @Test("Builds an exact-match + wildcard predicate")
    func basicPredicate() {
        let predicate = SpotlightSearch.bundleIDPredicate("com.example.foo")
        #expect(predicate.contains("kMDItemCFBundleIdentifier == \"com.example.foo\"c"))
        #expect(predicate.contains("kMDItemCFBundleIdentifier == \"com.example.foo.*\"wc"))
        // Both clauses joined by ` || `.
        #expect(predicate.contains(" || "))
    }

    @Test("Strips embedded double quotes for safety")
    func stripsDoubleQuotes() {
        let predicate = SpotlightSearch.bundleIDPredicate("com.\"example.foo")
        #expect(!predicate.contains("\"com.\""))
        // Double quote should be removed from the bundle ID, not left in.
        #expect(predicate.contains("com.example.foo"))
    }

    @Test("Predicate has case-insensitive (`c`) and wildcard-case (`wc`) flags")
    func flags() {
        let predicate = SpotlightSearch.bundleIDPredicate("a.b")
        #expect(predicate.contains("\"c"))
        #expect(predicate.contains("\"wc"))
    }
}
