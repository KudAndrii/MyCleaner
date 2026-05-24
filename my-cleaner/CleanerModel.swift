//
//  CleanerModel.swift
//  my-cleaner
//

import Foundation
import Observation
import AppKit

/// Observable state for the cleanup UI.
///
/// Owns the `Stage` machine, both result lists (per-app and orphan),
/// and the two cleanup flows. The flows have the same shape:
///
///   1. Move a list of URLs to the Trash, capturing per-URL failures.
///   2. Re-try every failure via an admin-elevated helper.
///   3. Drop side-effects that survive a Trash move (cfprefsd cache,
///      TCC grants) so the UI doesn't appear to have left state behind.
///
/// Both flows funnel into ``trashURLs(_:)``; their differences are
/// confined to which URLs they collect and which side-effects they
/// trigger.
@Observable
final class CleanerModel {

    /// High-level UI phase.
    ///
    /// Used by the view layer to pick which screen to show. The
    /// `done(_:)` case carries the final ``CleanupReport`` so the
    /// summary screen can render counts and per-URL failures without
    /// re-reading model state.
    enum Stage: Equatable {
        case idle
        case analyzing
        case results
        case cleaning
        case done(CleanupReport)
        case orphanScanning
        case orphanResults
        case largeFileScanning
        case largeFileResults
        case cacheScanning
        case cacheResults
        case duplicateScanning
        case duplicateResults
    }

    // MARK: - Shared state

    var stage: Stage = .idle
    var droppedApp: DroppedApp?
    var appSize: Int64 = 0
    var items: [RelatedItem] = []
    var systemExtensions: [SystemExtensionInfo] = []
    var orphanGroups: [OrphanGroup] = []
    var largeFiles: [LargeFileEntry] = []
    var cacheGroups: [CacheGroup] = []
    var duplicateGroups: [DuplicateGroup] = []

    /// User-controlled minimum-size filter for the large-file view.
    /// Drives the slider in `LargeFileResultsView` and re-narrows the
    /// already-scanned `largeFiles` list client-side — no re-scan
    /// needed when the user nudges the slider.
    var largeFileMinimumBytes: Int64 = LargeFileScanner.defaultMinimumBytes

    /// Size floor the most recent scan was started with.
    ///
    /// The results-view slider hides any standard chip below this
    /// value, since nothing smaller could ever surface no matter
    /// where the slider sits. Set once at scan start and not touched
    /// when the user nudges `largeFileMinimumBytes`.
    var largeFileScanFloorBytes: Int64 = LargeFileScanner.defaultMinimumBytes

    /// User-controlled category filter chip. `nil` means "show every
    /// category"; otherwise only entries in the selected bucket are
    /// visible.
    var largeFileCategoryFilter: LargeFileCategory?

    /// Structural progress of the in-flight large-file scan. One
    /// entry per phase (Spotlight + every nest the user kept
    /// selected), populated up front in `.pending` so the scanning
    /// view can render the full step list immediately; entries flip
    /// to `.inProgress` and `.completed` as the scanner emits events.
    var largeFileScanPhases: [LargeFileScanPhase] = []

    /// The currently-running large-file scan, kept around so the user
    /// can cancel it from the scanning screen.
    @ObservationIgnored
    private var largeFileScanTask: Task<Void, Never>?

    /// Structural progress of the in-flight cache scan. One entry per
    /// phase (user/system Library Caches + every well-known toolchain
    /// root), pre-populated in `.pending` so the scanning view can
    /// render the full step list immediately.
    var cacheScanPhases: [CacheScanPhase] = []

    /// The currently-running cache scan, kept around so the user can
    /// cancel it from the scanning screen.
    @ObservationIgnored
    private var cacheScanTask: Task<Void, Never>?

    /// Throttled progress signal published by the in-flight duplicate
    /// scan. `nil` when no scan is running; resets to `nil` after the
    /// scan settles. The scanning view binds directly to this so the
    /// UI can show file-counts and a determinate hash bar instead of
    /// an opaque spinner.
    var duplicateScanProgress: DuplicateScanner.Progress?

    var errorMessage: String?
    var isHovering: Bool = false

    /// Cancellation handle for the in-flight duplicate scan, if any.
    /// Stored so the UI can call ``cancelDuplicateScan()`` from the
    /// scanning view without coordinating Task identity through state.
    private var duplicateScanTask: Task<[DuplicateGroup], Error>?

    // MARK: - Login items (opt-in)

    /// Whether the user has opted into reading SMAppService /
    /// background-task-manager entries. Defaults to `false` because
    /// `sfltool dumpbtm` requires an admin password prompt. The
    /// preference is **session-only** — every relaunch starts off so
    /// the user is never surprised by a credential prompt on startup.
    var loginItemsEnabled: Bool = false

    /// Snapshot of every btm entry returned by `sfltool dumpbtm` the
    /// last time the user enabled the toggle. Cached for the lifetime
    /// of the process so dropping a second app — or toggling off and
    /// back on — doesn't re-prompt. `nil` until the first successful
    /// fetch.
    var cachedAllLoginItems: [LoginItemInfo]?

    /// Team identifier of the most recently dropped app. Stored so
    /// the login-items filter can use the team-ID fallback without
    /// re-reading the bundle's signature.
    var currentTeamID: String?

    /// Login items attributable to the currently dropped app.
    ///
    /// Returns an empty array when the toggle is off, no app is
    /// dropped, or the cache hasn't been populated yet. Filters the
    /// cached snapshot through ``LoginItems/matches(_:bundleID:teamID:)``
    /// so the predicate stays in one place.
    var loginItems: [LoginItemInfo] {
        guard loginItemsEnabled,
              let cache = cachedAllLoginItems,
              let app = droppedApp else { return [] }
        return cache.filter {
            LoginItems.matches($0, bundleID: app.bundleID, teamID: currentTeamID)
        }
    }

    // MARK: - Per-app selection (derived)

    /// Number of items the user has selected for deletion in the per-app flow.
    var selectedCount: Int { items.lazy.filter(\.isSelected).count }

    /// Bytes the user has selected for deletion in the per-app flow.
    var selectedSize: Int64 { items.lazy.filter(\.isSelected).map(\.sizeBytes).reduce(0, +) }

    /// Bytes across every related item, regardless of selection.
    var totalSize: Int64 { items.map(\.sizeBytes).reduce(0, +) }

    /// Bytes that will go to the Trash if the user confirms — selected items + the app itself.
    var trashTotal: Int64 { selectedSize + appSize }

    /// `true` when every related item is selected (and the list isn't empty).
    var allSelected: Bool { !items.isEmpty && items.allSatisfy(\.isSelected) }

    // MARK: - Per-app flow

    /// Validates a dropped URL, starts the scan, and parks the result
    /// on `items`. Updates `errorMessage` when the URL isn't a `.app`.
    func handleDrop(url: URL) async {
        guard let app = DroppedApp(url: url) else {
            errorMessage = "That doesn't look like an application."
            return
        }
        errorMessage = nil
        droppedApp = app
        items = []
        appSize = 0
        stage = .analyzing

        let result = await Task.detached(priority: .userInitiated) {
            AppScanner.scan(app: app)
        }.value

        appSize = result.appSize
        items = result.items.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return categoryOrder(lhs.category) < categoryOrder(rhs.category)
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
        systemExtensions = result.systemExtensions
        currentTeamID = result.teamID
        stage = .results
    }

    /// Flips the opt-in login-items toggle.
    ///
    /// Enabling for the first time runs `sfltool dumpbtm` (which
    /// triggers the admin prompt) and caches the parsed result.
    /// Subsequent enables — including after toggling off and back on,
    /// or after dropping a different app — reuse the cached snapshot
    /// without re-prompting.
    ///
    /// If the shell-out fails (user cancels the prompt, `sfltool`
    /// exits non-zero), the toggle is left in the off position so the
    /// UI accurately reflects "no data".
    func setLoginItemsEnabled(_ enabled: Bool) async {
        if enabled, cachedAllLoginItems == nil {
            let fetched = await Task.detached(priority: .userInitiated) {
                LoginItems.allItems()
            }.value
            guard let fetched else {
                // Cancellation or failure — keep the toggle off.
                loginItemsEnabled = false
                return
            }
            cachedAllLoginItems = fetched
        }
        loginItemsEnabled = enabled
    }

    /// Asks macOS to uninstall a system extension via
    /// `systemextensionsctl uninstall`. The OS shows its own
    /// confirmation prompt; this method returns once the command
    /// exits, regardless of whether the user approved removal.
    ///
    /// Removes the entry from ``systemExtensions`` on success so the
    /// UI updates without re-scanning. Failures leave the row in
    /// place; callers can prompt the user to remove it via System
    /// Settings instead.
    @discardableResult
    func uninstallSystemExtension(_ ext: SystemExtensionInfo) async -> Bool {
        let ok = await Task.detached(priority: .userInitiated) {
            SystemExtensions.uninstall(ext)
        }.value
        if ok {
            systemExtensions.removeAll { $0.id == ext.id }
        }
        return ok
    }

    /// Flips every item to/from selected based on whether anything is currently unselected.
    func toggleAll() {
        let target = !allSelected
        for i in items.indices { items[i].isSelected = target }
    }

    /// Moves selected items plus the app itself to the Trash, then
    /// drops bundle-scoped side-effects (LaunchAgents, cfprefsd cache,
    /// TCC grants) and transitions to `.done`.
    func confirmCleanup() async {
        guard let app = droppedApp else { return }
        stage = .cleaning

        let selected = items.filter(\.isSelected)
        let urlsToTrash = selected.map(\.url) + [app.url]
        let launchItemURLs = selected.filter { $0.category == .launchItems }.map(\.url)
        let touchedPreferences = selected.contains { $0.category == .preferences }
        let bundleID = app.bundleID

        // Best-effort: bootout any LaunchAgents/Daemons before their plist is
        // moved to the Trash. Otherwise the in-memory job survives and the
        // helper keeps running until reboot.
        if !launchItemURLs.isEmpty {
            await Task.detached(priority: .userInitiated) {
                CleanupActions.bootoutLaunchItems(at: launchItemURLs)
            }.value
        }

        let report = await trashURLs(urlsToTrash)

        await Task.detached(priority: .userInitiated) {
            // Drop the cfprefsd in-memory cache so deleted plists don't get
            // re-synced from RAM, and clear the bundle ID's TCC grants so the
            // entries don't linger in System Settings → Privacy & Security.
            if touchedPreferences {
                CleanupActions.killCfprefsd()
            }
            if let bid = bundleID, !bid.isEmpty {
                CleanupActions.resetTCC(forBundleID: bid)
            }
        }.value

        stage = .done(report)
    }

    /// Returns the model to its initial state. Used when the user
    /// clicks "Done" or drops a second app on the dropzone.
    func reset() {
        droppedApp = nil
        appSize = 0
        items = []
        systemExtensions = []
        currentTeamID = nil
        orphanGroups = []
        largeFiles = []
        largeFileCategoryFilter = nil
        largeFileMinimumBytes = LargeFileScanner.defaultMinimumBytes
        largeFileScanFloorBytes = LargeFileScanner.defaultMinimumBytes
        largeFileScanPhases = []
        cacheGroups = []
        cacheScanPhases = []
        duplicateGroups = []
        duplicateScanTask?.cancel()
        duplicateScanTask = nil
        duplicateScanProgress = nil
        errorMessage = nil
        isHovering = false
        stage = .idle
        // `loginItemsEnabled` and `cachedAllLoginItems` deliberately
        // survive reset — once the user has paid the admin-prompt
        // cost, we don't want to re-prompt because they dropped a
        // second app.
    }

    // MARK: - Orphan selection (derived)

    /// Items across every **selected** orphan group.
    var orphanSelectedCount: Int {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.items.count : 0) }
    }

    /// Bytes across every **selected** orphan group.
    var orphanSelectedSize: Int64 {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.totalSize : 0) }
    }

    /// Bytes across every orphan group, regardless of selection.
    var orphanTotalSize: Int64 {
        orphanGroups.map(\.totalSize).reduce(0, +)
    }

    /// `true` when every orphan group is selected (and the list isn't empty).
    var allOrphansSelected: Bool {
        !orphanGroups.isEmpty && orphanGroups.allSatisfy(\.isSelected)
    }

    // MARK: - Orphan flow

    /// Kicks off the orphan scan and parks the result on `orphanGroups`.
    func startOrphanScan() async {
        errorMessage = nil
        orphanGroups = []
        stage = .orphanScanning

        let result = await Task.detached(priority: .userInitiated) {
            OrphanScanner.scan()
        }.value

        orphanGroups = result.groups
        stage = .orphanResults
    }

    /// Flips a single orphan group's selection. No-op for unknown ids.
    func toggleOrphanGroup(id: String) {
        guard let i = orphanGroups.firstIndex(where: { $0.id == id }) else { return }
        orphanGroups[i].isSelected.toggle()
    }

    /// Flips every orphan group to/from selected based on whether
    /// anything is currently unselected.
    func toggleAllOrphans() {
        let target = !allOrphansSelected
        for i in orphanGroups.indices { orphanGroups[i].isSelected = target }
    }

    /// Moves every item in every selected orphan group to the Trash,
    /// then drops the same side-effects as the per-app flow but for
    /// every bundle ID across the selected groups.
    func confirmOrphanCleanup() async {
        let selected = orphanGroups.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        stage = .cleaning

        let urls = selected.flatMap { $0.items.map(\.url) }
        let bundleIDs = selected.map(\.bundleID)
        let touchedPreferences = selected
            .flatMap(\.items)
            .contains { $0.category == .preferences }

        let report = await trashURLs(urls)

        await Task.detached(priority: .userInitiated) {
            if touchedPreferences {
                CleanupActions.killCfprefsd()
            }
            for bid in bundleIDs {
                CleanupActions.resetTCC(forBundleID: bid)
            }
        }.value

        stage = .done(report)
    }

    // MARK: - Large-file selection (derived)

    /// Entries that pass the current category-chip and minimum-size
    /// filters. The slider and chips re-filter this view in real time
    /// without touching `largeFiles`, so the underlying scan result
    /// survives both filter changes.
    var visibleLargeFiles: [LargeFileEntry] {
        largeFiles.filter { entry in
            if entry.sizeBytes < largeFileMinimumBytes { return false }
            if let cat = largeFileCategoryFilter, entry.category != cat { return false }
            return true
        }
    }

    /// Number of currently-visible entries the user has selected.
    var largeFileSelectedCount: Int {
        visibleLargeFiles.lazy.filter(\.isSelected).count
    }

    /// Bytes across every currently-visible selected entry.
    var largeFileSelectedSize: Int64 {
        visibleLargeFiles.lazy.filter(\.isSelected).map(\.sizeBytes).reduce(0, +)
    }

    /// Bytes across every visible entry, regardless of selection.
    var largeFileVisibleSize: Int64 {
        visibleLargeFiles.map(\.sizeBytes).reduce(0, +)
    }

    /// `true` when every currently-visible entry is selected
    /// (and the visible list isn't empty). Drives the Select-All toggle.
    var allLargeFilesSelected: Bool {
        let visible = visibleLargeFiles
        return !visible.isEmpty && visible.allSatisfy(\.isSelected)
    }

    // MARK: - Large-file flow

    func startLargeFileScan(
        minimumBytes: Int64 = LargeFileScanner.defaultMinimumBytes,
        nests: [LargeFileNest]? = nil
    ) {
        errorMessage = nil
        largeFiles = []
        largeFileCategoryFilter = nil
        largeFileMinimumBytes = minimumBytes
        largeFileScanFloorBytes = minimumBytes
        let walkNests = nests ?? LargeFileScanner.availableNests()
        largeFileScanPhases = makeInitialLargeFilePhases(nests: walkNests)
        stage = .largeFileScanning

        let eventHandler: @Sendable (LargeFileScanner.ScanEvent) -> Void = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleLargeFileScanEvent(event)
            }
        }

        largeFileScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let scanned = try await Task.detached(priority: .userInitiated) {
                    try await LargeFileScanner.scan(
                        minimumBytes: minimumBytes,
                        nests: walkNests,
                        onEvent: eventHandler
                    )
                }.value
                try Task.checkCancellation()
                self.largeFiles = scanned
                self.stage = .largeFileResults
                self.largeFileScanTask = nil
            } catch is CancellationError {
                return
            } catch {
                self.stage = .idle
                self.largeFileScanTask = nil
            }
        }
    }

    func cancelLargeFileScan() {
        largeFileScanTask?.cancel()
        largeFileScanTask = nil
        largeFileScanPhases = []
        stage = .idle
    }

    func setLargeFileMinimumBytes(_ bytes: Int64) {
        largeFileMinimumBytes = bytes
        if let category = largeFileCategoryFilter,
           !largeFiles.contains(where: { $0.sizeBytes >= bytes && $0.category == category }) {
            largeFileCategoryFilter = nil
        }
    }

    private func makeInitialLargeFilePhases(nests: [LargeFileNest]) -> [LargeFileScanPhase] {
        var phases: [LargeFileScanPhase] = [
            LargeFileScanPhase(
                id: LargeFileScanner.spotlightPhaseID,
                displayName: "Spotlight (home folder)",
                status: .pending
            )
        ]
        for nest in nests {
            phases.append(LargeFileScanPhase(
                id: nest.url.path,
                displayName: nest.displayName,
                status: .pending
            ))
        }
        return phases
    }

    private func handleLargeFileScanEvent(_ event: LargeFileScanner.ScanEvent) {
        switch event {
        case .phaseStarted(let id):
            if let i = largeFileScanPhases.firstIndex(where: { $0.id == id }) {
                largeFileScanPhases[i].status = .inProgress
            }
        case .phaseCompleted(let id, let candidatesAfter):
            if let i = largeFileScanPhases.firstIndex(where: { $0.id == id }) {
                largeFileScanPhases[i].status = .completed
                largeFileScanPhases[i].candidatesAfter = candidatesAfter
            }
        }
    }

    func toggleLargeFile(id: URL) {
        guard let i = largeFiles.firstIndex(where: { $0.id == id }) else { return }
        largeFiles[i].isSelected.toggle()
    }

    func toggleAllLargeFiles() {
        let visible = visibleLargeFiles
        guard !visible.isEmpty else { return }
        let target = !visible.allSatisfy(\.isSelected)
        let visibleIDs = Set(visible.map(\.id))
        for i in largeFiles.indices where visibleIDs.contains(largeFiles[i].id) {
            largeFiles[i].isSelected = target
        }
    }

    func confirmLargeFileCleanup() async {
        let selected = largeFiles.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        stage = .cleaning

        let urls = selected.map(\.url)
        let report = await trashURLs(urls)
        stage = .done(report)
    }

    // MARK: - Cache selection (derived)

    /// Items across every **selected** cache group.
    var cacheSelectedCount: Int {
        cacheGroups.reduce(0) { $0 + ($1.isSelected ? $1.entries.count : 0) }
    }

    /// Bytes across every **selected** cache group.
    var cacheSelectedSize: Int64 {
        cacheGroups.reduce(0) { $0 + ($1.isSelected ? $1.totalBytes : 0) }
    }

    /// Bytes across every cache group, regardless of selection.
    var cacheTotalSize: Int64 {
        cacheGroups.map(\.totalBytes).reduce(0, +)
    }

    /// `true` when every cache group is selected (and the list isn't empty).
    var allCachesSelected: Bool {
        !cacheGroups.isEmpty && cacheGroups.allSatisfy(\.isSelected)
    }

    // MARK: - Cache flow

    func startCacheScan() {
        errorMessage = nil
        cacheGroups = []
        cacheScanPhases = makeInitialCachePhases()
        stage = .cacheScanning

        let eventHandler: @Sendable (CacheScanner.ScanEvent) -> Void = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleCacheScanEvent(event)
            }
        }

        cacheScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await CacheScanner.scan(onEvent: eventHandler)
                }.value
                try Task.checkCancellation()
                self.cacheGroups = result.groups
                self.stage = .cacheResults
                self.cacheScanTask = nil
            } catch is CancellationError {
                return
            } catch {
                self.stage = .idle
                self.cacheScanTask = nil
            }
        }
    }

    func cancelCacheScan() {
        cacheScanTask?.cancel()
        cacheScanTask = nil
        cacheScanPhases = []
        stage = .idle
    }

    private func makeInitialCachePhases() -> [CacheScanPhase] {
        var phases: [CacheScanPhase] = [
            CacheScanPhase(
                id: CacheScanner.userLibraryCachesPhaseID,
                displayName: "~/Library/Caches",
                status: .pending
            ),
            CacheScanPhase(
                id: CacheScanner.systemLibraryCachesPhaseID,
                displayName: "/Library/Caches",
                status: .pending
            ),
        ]
        for path in CacheScanner.wellKnownPaths() {
            phases.append(CacheScanPhase(
                id: path.relativePath,
                displayName: path.displayName,
                status: .pending
            ))
        }
        return phases
    }

    private func handleCacheScanEvent(_ event: CacheScanner.ScanEvent) {
        switch event {
        case .phaseStarted(let id):
            if let i = cacheScanPhases.firstIndex(where: { $0.id == id }) {
                cacheScanPhases[i].status = .inProgress
            }
        case .phaseCompleted(let id, let groupsAfter):
            if let i = cacheScanPhases.firstIndex(where: { $0.id == id }) {
                cacheScanPhases[i].status = .completed
                cacheScanPhases[i].groupsAfter = groupsAfter
            }
        }
    }

    func toggleCacheGroup(id: String) {
        guard let i = cacheGroups.firstIndex(where: { $0.id == id }) else { return }
        cacheGroups[i].isSelected.toggle()
    }

    func toggleAllCaches() {
        let target = !allCachesSelected
        for i in cacheGroups.indices { cacheGroups[i].isSelected = target }
    }

    func confirmCacheCleanup() async {
        let selected = cacheGroups.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        stage = .cleaning

        let urls = selected.flatMap { $0.entries.map(\.url) }
        let report = await trashURLs(urls)

        stage = .done(report)
    }

    // MARK: - Duplicate selection (derived)

    /// Total number of copies the user has selected for deletion
    /// across every duplicate group.
    var duplicateSelectedCount: Int {
        duplicateGroups.reduce(0) { acc, group in
            acc + group.copies.lazy.filter(\.isSelectedForDeletion).count
        }
    }

    /// Bytes the user would recover by trashing the currently
    /// selected copies — `sum(sizePerCopy × selectedCopies)` across
    /// every group.
    var duplicateSelectedSize: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.wastedBytes }
    }

    /// Maximum recoverable bytes across every group — `wastedBytes`
    /// summed with one copy kept per group. Used by the results
    /// header so the user can see how much is reachable in total
    /// independently of their current selection.
    var duplicateMaximumRecoverableBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.maximumRecoverableBytes }
    }

    /// Total distinct file copies across every duplicate group,
    /// regardless of selection. Used by the empty-state and
    /// header strings.
    var duplicateTotalCopies: Int {
        duplicateGroups.reduce(0) { $0 + $1.copies.count }
    }

    // MARK: - Duplicate flow

    /// Kicks off the duplicate scan and parks the result on
    /// ``duplicateGroups``.
    func startDuplicateScan(scope: [URL]) async {
        errorMessage = nil
        duplicateGroups = []
        duplicateScanProgress = .enumerating(filesSeen: 0)
        stage = .duplicateScanning

        let (progressStream, continuation) = AsyncStream<DuplicateScanner.Progress>.makeStream()

        let progressTask = Task { @MainActor [weak self] in
            for await update in progressStream {
                self?.duplicateScanProgress = update
            }
        }

        let task = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try await DuplicateScanner.scan(scope: scope) { progress in
                continuation.yield(progress)
            }
        }
        duplicateScanTask = task

        do {
            let groups = try await task.value
            guard duplicateScanTask == task else { return }
            duplicateGroups = groups
            stage = .duplicateResults
        } catch is CancellationError {
            if stage == .duplicateScanning { stage = .idle }
        } catch {
            errorMessage = "Duplicate scan failed: \(error.localizedDescription)"
            stage = .idle
        }

        await progressTask.value
        if duplicateScanTask == task { duplicateScanTask = nil }
        duplicateScanProgress = nil
    }

    func cancelDuplicateScan() {
        duplicateScanTask?.cancel()
    }

    func toggleDuplicateCopy(groupID: UUID, copyID: UUID) {
        guard let gi = duplicateGroups.firstIndex(where: { $0.id == groupID }),
              let ci = duplicateGroups[gi].copies.firstIndex(where: { $0.id == copyID })
        else { return }

        let currentlySelected = duplicateGroups[gi].copies[ci].isSelectedForDeletion
        if !currentlySelected {
            let othersKept = duplicateGroups[gi].copies.enumerated().contains { idx, copy in
                idx != ci && !copy.isSelectedForDeletion
            }
            guard othersKept else { return }
        }
        duplicateGroups[gi].copies[ci].isSelectedForDeletion.toggle()
    }

    func canDeselectDuplicateCopy(groupID: UUID, copyID: UUID) -> Bool {
        guard let group = duplicateGroups.first(where: { $0.id == groupID }) else { return false }
        guard let copy = group.copies.first(where: { $0.id == copyID }) else { return false }
        if copy.isSelectedForDeletion { return true }
        return group.copies.contains { $0.id != copyID && !$0.isSelectedForDeletion }
    }

    func confirmDuplicateCleanup() async {
        let urls = duplicateGroups.flatMap { group in
            group.copies.filter(\.isSelectedForDeletion).map(\.url)
        }
        guard !urls.isEmpty else { return }
        stage = .cleaning
        let report = await trashURLs(urls)
        stage = .done(report)
    }

    // MARK: - Shared trash plumbing

    /// Moves every URL to the Trash, retries refusals via the
    /// admin-elevated helper, and aggregates everything into a
    /// ``CleanupReport``.
    ///
    /// Shared by ``confirmCleanup()`` and ``confirmOrphanCleanup()``;
    /// both flows have identical retry / error-mapping requirements
    /// so the duplication isn't worth keeping.
    private func trashURLs(_ urls: [URL]) async -> CleanupReport {
        let firstPass = await Task.detached(priority: .userInitiated) { () -> FirstPassResult in
            var trashed = 0
            var failed: [URL] = []
            var messages: [URL: String] = [:]
            let fm = FileManager.default
            for url in urls {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    trashed += 1
                } catch {
                    failed.append(url)
                    messages[url] = error.localizedDescription
                }
            }
            return FirstPassResult(trashed: trashed, failed: failed, messages: messages)
        }.value

        var elevatedSucceeded = 0
        var failures: [CleanupReport.Failure] = []

        if !firstPass.failed.isEmpty {
            let elevation = await AdminTrash.move(urls: firstPass.failed)
            elevatedSucceeded = elevation.succeeded.count
            for url in elevation.refused {
                let msg = elevation.errorMessage
                    ?? firstPass.messages[url]
                    ?? "Item could not be moved to the Trash."
                failures.append(.init(url: url, message: msg))
            }
        }

        return CleanupReport(
            trashedNormally: firstPass.trashed,
            trashedWithElevation: elevatedSucceeded,
            failures: failures
        )
    }
}

// MARK: - File-private helpers

/// First-pass trash outcome — split out so the detached closure stays
/// `Sendable`. Not exposed beyond ``CleanerModel/trashURLs(_:)``.
private nonisolated struct FirstPassResult: Sendable {
    let trashed: Int
    let failed: [URL]
    let messages: [URL: String]
}

/// Display order for `RelatedItem.Category` — uses `allCases` order so
/// adding a new case to the enum implicitly sorts it correctly.
private nonisolated func categoryOrder(_ c: RelatedItem.Category) -> Int {
    RelatedItem.Category.allCases.firstIndex(of: c) ?? Int.max
}
