//
//  AppScannerCategorizeTests.swift
//  my-cleanerTests
//
//  Covers AppScanner.categorize — used to bucket Spotlight hits
//  into the category headers shown in the results view.
//

import Foundation
import Testing
@testable import my_cleaner

@Suite("AppScanner.categorize")
struct AppScannerCategorizeTests {

    @Test(
        "Categorizes well-known Library subpaths",
        arguments: [
            ("/Users/jane/Library/Application Support/Foo/bar.txt", RelatedItem.Category.applicationSupport),
            ("/Users/jane/Library/Caches/Foo/bar.dat", .caches),
            ("/Users/jane/Library/Containers/Foo.app", .containers),
            ("/Users/jane/Library/Group Containers/Foo.shared", .groupContainers),
            ("/Users/jane/Library/Preferences/Foo.plist", .preferences),
            ("/Users/jane/Library/Saved Application State/Foo.savedState", .savedState),
            ("/Users/jane/Library/Logs/DiagnosticReports/Foo-2025.ips", .crashReports),
            ("/Users/jane/Library/Logs/Foo/foo.log", .logs),
            ("/Users/jane/Library/HTTPStorages/Foo.binarycookies", .cookies),
            ("/Users/jane/Library/WebKit/Foo/data.db", .cookies),
            ("/Users/jane/Library/Cookies/Foo.binarycookies", .cookies),
            ("/Users/jane/Library/LaunchAgents/Foo.plist", .launchItems),
            ("/Library/LaunchDaemons/Foo.plist", .launchItems),
            ("/Library/PrivilegedHelperTools/com.foo.helper", .launchItems),
            ("/Users/jane/Library/Application Scripts/Foo/script.scpt", .scripts),
            ("/Users/jane/Library/Mobile Documents/iCloud~com~apple~Pages/doc.pages", .iCloud),
            ("/usr/local/lib/random.dylib", .other),
        ]
    )
    func mapsPathToCategory(path: String, expected: RelatedItem.Category) {
        #expect(AppScanner.categorize(path: path) == expected)
    }

    @Test("Crash reports take precedence over generic logs")
    func crashReportsBeforeLogs() {
        let path = "/Users/jane/Library/Logs/DiagnosticReports/Foo.ips"
        #expect(AppScanner.categorize(path: path) == .crashReports)
    }
}

@Suite("AppScanner.shouldSkipDescent")
struct AppScannerShouldSkipDescentTests {

    @Test("Skips com.apple.* vendor folders")
    func skipsApple() {
        let url = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC")
        #expect(AppScanner.shouldSkipDescent(url) == true)
    }

    @Test("Skips 'Apple' folder")
    func skipsAppleFolder() {
        let url = URL(fileURLWithPath: "/Library/Application Support/Apple")
        #expect(AppScanner.shouldSkipDescent(url) == true)
    }

    @Test("Skips CrashReporter folder")
    func skipsCrashReporter() {
        let url = URL(fileURLWithPath: "/Library/Application Support/CrashReporter")
        #expect(AppScanner.shouldSkipDescent(url) == true)
    }

    @Test("Descends into regular vendor folders")
    func descendsIntoVendor() {
        let url = URL(fileURLWithPath: "/Library/Application Support/JetBrains")
        #expect(AppScanner.shouldSkipDescent(url) == false)
    }
}
