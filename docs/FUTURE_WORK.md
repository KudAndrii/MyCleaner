# Future work

Tracked-but-not-yet-implemented cleanup techniques. Each entry below
exists because most established macOS cleaners (AppCleaner, Pearcleaner,
CleanMyMac) ship some version of it, and MyCleaner is missing it.

All four below apply primarily to the **app-deletion flow** — i.e. what
runs when the user drops an app onto the window. Where the technique
also has value for the **orphan-files scanner**, that's called out
explicitly.

## 1. Installer package receipts (`pkgutil`)

**Status:** Not implemented.

**Problem.** Apps installed via `.pkg` installers (especially anything
from a vendor with a kernel/network extension, or paid software with a
licensing helper) drop files outside the `.app` bundle that the current
scanner can't find: `/Library/LaunchDaemons/<helper>.plist`,
`/Library/PrivilegedHelperTools/<binary>`, `/usr/local/bin/<tool>`,
`/Library/Application Support/<vendor>/*`. None of these follow
bundle-ID naming, so neither the directory walk nor Spotlight catches
them.

**Solution sketch.** Use `pkgutil` to query the receipt database:

```
pkgutil --pkgs                 # list every installed package
pkgutil --pkg-info <pkg-id>    # install date, location, version
pkgutil --files <pkg-id>       # every path the package wrote, root-relative
pkgutil --forget <pkg-id>      # remove the receipt (after files are gone)
```

For each dropped app:

1. Cross-reference `pkgutil --pkgs` against the app's bundle ID and
   name hints. Typical receipt IDs are `<bundleID>`, `<bundleID>.pkg`,
   or `com.<vendor>.<product>`.
2. For matching receipts, run `pkgutil --files <pkg-id>`, prefix each
   entry with `/`, filter to ones that still exist.
3. Surface those paths under a new **Installer Files** category.
4. After cleanup, run `pkgutil --forget` on each receipt so the
   database matches reality.

**Where it lives.** New `my-cleaner/PkgutilReceipts.swift` with a single
`receiptsForApp(_:)` entry point. Add a `.installerFiles` case to
`RelatedItem.Category`.

**Orphan-scanner crossover.** Yes — packages whose `--files` list is
mostly missing are orphan receipts. Could surface them in a sub-section
of the orphan UI, with `pkgutil --forget` as the cleanup.

**Pitfalls.** `--files` paths can include `/` (root) and directory
entries that are shared between packages. Don't trash directories that
other packages also own.

---

## 2. System Extensions / Network Extensions

**Status:** Not implemented.

**Problem.** Modern VPN clients, content filters, endpoint security
tools, DriverKit-based drivers, and some backup tools install
**system extensions** that live outside the `.app` and stay loaded
after the bundle is trashed. The cleaner can't trash these — they're
managed by `sysextd` and require the system to unload them first.

**Solution sketch.** Detect, don't auto-remove. Removal requires a
user-confirmed Apple prompt that we shouldn't try to script around.

1. Run `systemextensionsctl list` and parse the output for entries
   whose `Identifier` column matches the dropped app's bundle ID or
   team identifier.
2. Surface them in a non-trashable **System Extensions** section of
   the results view with a one-line explanation and a button that
   runs `systemextensionsctl uninstall <team-id> <bundleID>` for the
   user (this triggers the system prompt).
3. If `systemextensionsctl` isn't usable from the app (it needs SIP
   off in some setups), fall back to reading the on-disk database at
   `/Library/SystemExtensions/db.plist`.

**Where it lives.** New `my-cleaner/SystemExtensions.swift`.

**Orphan-scanner crossover.** Theoretically yes — a system extension
whose owning app is gone is an orphan. In practice macOS cleans these
up itself when the parent app is removed, so it's a rare case.

**Pitfalls.** Some system extensions are part of macOS itself or
installed by MDM; never offer to uninstall those.

---

## 3. SMAppService login items (`backgrounditems.btm`)

**Status:** Not implemented.

**Problem.** Modern apps (anything using `SMAppService` from
ServiceManagement) don't drop a `.plist` into `~/Library/LaunchAgents`.
They register with the system's background-task manager, and the only
on-disk trace is in:

```
~/Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm
```

That file is opaque binary plist data, but `sfltool dumpbtm` decodes
it. The current scanner sees `~/Library/LaunchAgents` only — login
items registered via `SMAppService` are invisible.

**Solution sketch.**

1. Run `/usr/bin/sfltool dumpbtm` and parse the output (it's
   human-readable but not machine-friendly; a small parser is
   needed).
2. For each entry, extract the registering bundle ID, the embedded
   helper path, and whether it's enabled.
3. Match against the dropped app's bundle ID and team identifier.
4. Surface matches in the **Launch Items** section with a note that
   they were registered via SMAppService (so the user understands
   they came from the app, not from a `LaunchAgents` plist).

There is **no public API** for removing a btm entry programmatically.
The only sanctioned removal is for the registering app to call
`SMAppService.unregister()` itself, which we can't do from outside.
For now: detect and inform the user; once the app is trashed, macOS
prunes the entry on the next launch of `backgroundtaskmanagementagent`.

**Where it lives.** New `my-cleaner/LoginItems.swift`.

**Orphan-scanner crossover.** Limited — btm entries for missing apps
are usually pruned automatically. Could surface remaining stale
entries in the orphan UI.

**Pitfalls.** `sfltool` output format changes between macOS releases;
the parser needs to be defensive.

---

## 4. Keychain item cleanup

**Status:** Not implemented.

**Problem.** Apps that store credentials, OAuth tokens, or signing
keys leave entries in `login.keychain-db`. When the app is uninstalled
those entries don't go anywhere — they sit forever, occasionally
prompting "<deleted app> wants to access the keychain" if anything
else queries for a similar name.

**Solution sketch.** Use the Security framework to enumerate items
attributed to the dropped app, and surface them as an opt-in,
default-off section.

1. Build a `kSecMatchSearchListAttribute` query that filters by:
   - `kSecAttrAccessGroup` = bundle ID (or `<teamID>.<bundleID>` for
     app-group items).
   - For OAuth tokens: `kSecAttrService` matching the bundle ID, the
     last reverse-DNS component, or the display name.
2. For each result, surface its **service** + **account** (no
   password) plus a delete button.
3. Default to **off**; require explicit user confirmation per item.
   Keychain deletion is irreversible — they're not moved to the Trash.

**Where it lives.** New `my-cleaner/KeychainCleanup.swift`.

**Orphan-scanner crossover.** Hard to do well. Would need to
enumerate every keychain item, parse the access group, derive the
team ID, and cross-reference with the installed-app team ID set
from the orphan scanner. False positives are very expensive here
because deletion is irreversible.

**Pitfalls.**

- The keychain prompts for permission to read items — first scan will
  generate a flood of prompts unless the user clicks "Always Allow".
- App-group entries are shared between every app the developer ships;
  the team-prefix-sibling check from the orphan scanner needs to apply
  here too.
- Some entries are part of Apple's iCloud Keychain sync and shouldn't
  be touched.

---

## Priority order (suggested)

1. **`pkgutil`** — highest value, lowest risk. Catches a category of
   leftover files the current scanner is entirely blind to.
2. **System Extensions** — second priority for users who install VPN /
   security software.
3. **SMAppService** — useful for any modern app that auto-starts;
   read-only surfacing has no risk.
4. **Keychain** — last. Irreversible, prompts-heavy, and the value is
   mostly cosmetic (the items don't take meaningful disk space).

## What's intentionally not on this list

- **Dock plist surgery** to remove the trashed app from
  `~/Library/Preferences/com.apple.dock.plist`. Too fragile; macOS
  handles this itself when the bundle is gone.
- **Sandbox proxy data** in `~/Library/Containers/<bundleID>/Data/`.
  This is what the container *is* — already covered by the
  Containers category.
- **CFPreferences global plist surgery**. We kill `cfprefsd` after
  trashing; that's enough for in-memory values to be flushed.
- **Browser extension data**. Out of scope — the cleaner targets
  apps, not Safari/Chrome/Firefox extensions.
