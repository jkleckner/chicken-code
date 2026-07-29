# Build Warning and Analyzer Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive `xcodebuild clean build analyze -scheme Chicken` from 130 compiler warnings + 4 static-analyzer findings down to zero, fixing the genuine defects hiding among them.

**Architecture:** Phased, risk-ordered. Phase 1 fixes real defects the compiler already found (a guaranteed crash, two leaks, a broken initializer, dead drag-and-drop). Phase 2 is mechanical and behavior-preserving. Phase 3 swaps deprecated APIs whose replacements are drop-in. Phase 4 does the two migrations that change control flow or touch user data. Each task builds and re-counts warnings; the count is the test harness, since this project has no unit-test coverage of app code.

**Tech Stack:** Objective-C, Cocoa/AppKit, **no ARC** (manual `retain`/`release`/`autorelease` — match surrounding style), macOS 11.0 deployment target, universal (arm64 + x86_64), Xcode with the macOS 26.5 SDK.

## Global Constraints

- **No ARC.** Every `alloc`/`copy`/`retain` needs a balancing `release` or `autorelease`. Do not introduce `__weak`, `@autoreleasepool`-only assumptions, or ARC-only idioms.
- **Deployment target is macOS 11.0.** Any replacement API must exist in 11.0, or be guarded with `@available(macOS X, *)`. Do not raise the deployment target.
- **Do not change observable behavior** except where a task explicitly says so (Tasks 1, 10, 23–26).
- **Build products split by invocation.** Target-based builds land in `cotvnc/build/<Configuration>/`; `-scheme Chicken` builds land in DerivedData. Clean the same way you build.
- **Ad hoc signing for local builds.** Append `CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""` to every local `xcodebuild` invocation, or the build fails at `GatherProvisioningInputs`.
- **`FrameBufferDrawing.h` is a template**, included into four subclasses at four pixel depths. If a task touches it, the change must hold for all four. (No task in this plan does.)
- **Commit after every task.** Development happens on branch `moe`; CI builds and analyzes `moe` and its PRs.
- **Do not add `-Werror`.** Explicitly out of scope for this plan.

## Baseline (verified 2026-07-29)

`xcodebuild clean build analyze -scheme Chicken` → `** BUILD SUCCEEDED **`, `** ANALYZE SUCCEEDED **`. There are **no errors**. `./Tests/run_tests.sh` passes (282,869,099 checks, 0 failures).

The build emits **128 warning lines**, which collapse to **117 unique sites** — a warning in a header repeats once per translation unit that imports it. The unique-site count is what `count_warnings.sh` reports and what this plan tracks, because it is the number of places you actually have to edit.

| Flag | Unique sites | Raw lines |
|---|---|---|
| `-Wshorten-64-to-32` | 53 | 53 |
| `-Wdeprecated-declarations` | 36 | 36 |
| `-Wdeprecated-non-prototype` | 8 | 8 |
| `-Wobjc-method-access` | 4 | 4 |
| `-Wmismatched-parameter-types` | 3 | 3 |
| `-Wincomplete-implementation` | 3 | 3 |
| `-Wdeprecated-implementations` | 3 | 3 |
| `-Wduplicate-method-match` | 1 | 12 |
| `-Wunused-but-set-variable` | 1 | 1 |
| `-Wincompatible-pointer-types` | 1 | 1 |
| Clang static analyzer | 4 | 4 |
| **Total** | **117** | **128** |

Verified by running the Step 1 pipeline of Task 0 against the baseline build log.

---

## File Structure

No files are created or deleted except the verification script. Modified files, by responsibility:

| File | Why it changes |
|---|---|
| `Tests/count_warnings.sh` | **Create.** Verification harness for every task. |
| `Source/RFBConnectionManager.m` | Dead `setFullscreen:` selector (crash). |
| `Source/DockConnection.m` | Missing `AppDelegate.h` import. |
| `Source/Session.h` / `Source/Session.m` | Dead declarations; `NSClipView` pointer; alert/sheet migration; scroll-view geometry. |
| `Source/ServerDataViewController.h` / `.m` | Duplicate declaration; nib loading; `setBorderType:`; `controlTextDidChange:`. |
| `Source/vncauth.c` | Leaked buffer and stream on error paths. |
| `Source/KeyEquivalentScenario.m` | Broken designated-initializer chain. |
| `Source/PrefController.m` / `Source/PrefController_private.m` | Dead store; nib loading. |
| `Source/EventFilter.m` | Header/impl parameter type mismatch; truncating casts; `convertScreenToBase:`. |
| `Source/ProfileManager.m` | Deprecated table-view drag data source; truncating casts. |
| `Source/d3des.c` | K&R function definitions. |
| `Source/MyApp.m` | Unused variable. |
| `Source/Profile.m`, `ProfileDataManager.m`, `ProfileManager_private.m`, `ServerDataManager.m`, `ListenerController.m`, `CursorPseudoEncodingReader.m`, `ConnectionWaiter.m` | Truncating casts; archiver migration. |
| `Source/RFBConnection.m`, `TightEncodingReader.m`, `ZlibHexEncodingReader.m`, `ZRLEEncodingReader.m` | Truncating casts on wire-derived lengths. |
| `Source/AuthPrompt.m`, `Source/SshWaiter.m` | Sheet presentation migration. |
| `Source/KeyChain.m` | `SecKeychain` → `SecItem` migration. |

---

## Task 0: Warning-count verification harness

There is no test target that can exercise app code — `Tests/run_tests.sh` compiles standalone Foundation programs, so it can only reach header-only inline logic like `FrameBufferClip.h`. The warning count is therefore the only objective, repeatable signal for this work. Build it first so every later task has a real pass/fail gate.

**Files:**
- Create: `cotvnc/Tests/count_warnings.sh`

**Interfaces:**
- Produces: `Tests/count_warnings.sh [baseline-count]` — prints a per-flag warning table and the total; exits 0 always, exits 1 only if a baseline argument is supplied and the current total exceeds it. Every later task calls this.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# Counts compiler warnings and static-analyzer findings from a clean
# build+analyze. Pass a baseline count to fail when the total regresses above it.
#
#   ./Tests/count_warnings.sh        # report only
#   ./Tests/count_warnings.sh 128    # report, and fail if total > 128

set -o pipefail
cd "$(dirname "$0")/.." || exit 1

BASELINE="$1"
LOG=$(mktemp -t chicken-warnings)
trap 'rm -f "$LOG"' EXIT

echo "Building (clean build analyze)..." >&2
xcodebuild clean build analyze -scheme Chicken \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" > "$LOG" 2>&1
STATUS=$?

if ! grep -q '^\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
    echo "BUILD FAILED -- errors:" >&2
    grep -E "error:" "$LOG" | sed 's|.*/Source/|Source/|' | sort -u >&2
    exit 1
fi

# Unique warning sites. Compiler warnings declared in a header repeat once per
# translation unit; sort -u collapses them to the site that must actually be
# fixed, so the number tracks work remaining rather than TU count.
grep -E "warning:" "$LOG" \
    | sed 's|.*/cotvnc/Source/|Source/|' \
    | sed 's|^/.*/Chicken.build/|(generated) |' \
    | sort -u > "$LOG.warn"

echo
echo "=== By flag ==="
sed -n 's|.*\[\(-W[a-z0-9-]*\)\]$|\1|p' "$LOG.warn" | sort | uniq -c | sort -rn
echo "=== Static analyzer ==="
sed -n 's|.*\[\([a-z][a-zA-Z]*\.[a-zA-Z.]*\)\]$|\1|p' "$LOG.warn" | sort | uniq -c | sort -rn
echo
echo "=== Sites ==="
cat "$LOG.warn"

TOTAL=$(wc -l < "$LOG.warn" | tr -d ' ')
echo
echo "TOTAL: $TOTAL unique warning sites"
rm -f "$LOG.warn"

if [ -n "$BASELINE" ] && [ "$TOTAL" -gt "$BASELINE" ]; then
    echo "REGRESSION: $TOTAL > baseline $BASELINE" >&2
    exit 1
fi
exit $STATUS
```

- [ ] **Step 2: Make it executable and run it to establish the real baseline**

Run:
```bash
cd cotvnc && chmod +x Tests/count_warnings.sh && ./Tests/count_warnings.sh
```
Expected: `** BUILD SUCCEEDED **` detected, a per-flag table matching the baseline table above, and `TOTAL: 117 unique warning sites`. **Record that number** — it is the baseline every subsequent task compares against. If you get a different number, the SDK or Xcode version differs from the one this plan was written against (macOS 26.5 SDK); use your number as the baseline and expect the per-task deltas to shift slightly.

- [ ] **Step 3: Verify the regression gate actually works**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh 0; echo "exit=$?"
```
Expected: prints the table, then `REGRESSION: <N> > baseline 0` and `exit=1`. If it exits 0, the gate is broken — fix it before continuing, because every later task depends on it.

- [ ] **Step 4: Commit**

```bash
git add cotvnc/Tests/count_warnings.sh
git commit -m "add warning-count harness for build cleanup"
```

---

# Phase 1 — Real defects

Every task here fixes a bug, not just a diagnostic. Do this phase even if you stop afterward.

## Task 1: `--FullScreen` command-line flag crashes on launch

Commit `eaea5fa` removed the custom fullscreen support but left the command-line argument handler calling `-setFullscreen:`, which no longer exists on any `IServerData` implementation. `grep -rn "ullscreen" Source/` finds exactly two hits: a stale comment and this call. Launching with `--FullScreen` therefore raises `unrecognized selector sent to instance` and terminates the app. This is a behavior change by necessity — the flag cannot work, so it must stop pretending to.

**Files:**
- Modify: `cotvnc/Source/RFBConnectionManager.m:191-192`

**Interfaces:**
- Consumes: `Tests/count_warnings.sh` from Task 0.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Confirm the selector is genuinely gone**

Run:
```bash
cd cotvnc && grep -rn "setFullscreen\|- (void)setFullscreen" Source/
```
Expected: exactly one hit, `Source/RFBConnectionManager.m:192`. No declaration, no implementation anywhere. If a declaration turns up, stop — the diagnosis is wrong and this task needs rethinking.

- [ ] **Step 2: Replace the dead call with a deprecation notice**

Current code at `Source/RFBConnectionManager.m:191-192`:
```objc
		else if ([arg hasPrefix:@"--FullScreen"])
			[cmdlineServer setFullscreen: YES];
```

Replace with:
```objc
		else if ([arg hasPrefix:@"--FullScreen"])
			/* Custom fullscreen support was removed in 2026.7; macOS native
			 * fullscreen handles this. Accept and ignore the flag so existing
			 * scripts keep working instead of dying on an unknown argument. */
			NSLog(@"--FullScreen is no longer supported and has been ignored. "
			      @"Use the window's native fullscreen button instead.");
```

- [ ] **Step 3: Update the usage text if it advertises the flag**

Run:
```bash
cd cotvnc && grep -rn "FullScreen" Source/ Resources/
```
If `-cmdlineUsage` (in `RFBConnectionManager.m`) or any `.strings`/`.xcstrings` entry lists `--FullScreen`, remove that line from the usage output. If it does not appear, skip this step.

- [ ] **Step 4: Build and verify the crash is gone**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline-from-task-0>
```
Expected: total drops by 1; `-Wobjc-method-access` count drops from 4 to 3.

Then smoke-test the actual fix:
```bash
cd cotvnc && ./build/Development/Chicken.app/Contents/MacOS/Chicken --FullScreen --Host localhost 2>&1 | head -5
```
Expected: the "no longer supported" log line, and the process does **not** die with `unrecognized selector`. (A connection failure to localhost is fine and expected — you are testing argument parsing, not connectivity.) If the app was built via `-scheme`, the binary is under DerivedData instead; use `xcodebuild -showBuildSettings -scheme Chicken | grep BUILT_PRODUCTS_DIR` to locate it.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/RFBConnectionManager.m
git commit -m "fix crash when launched with --FullScreen

The flag's handler still called -setFullscreen:, removed in eaea5fa along
with the rest of the custom fullscreen code. Accept and ignore the flag."
```

---

## Task 2: `DockConnection` cannot see `-removeDockConnection:`

`-removeDockConnection:` is declared in `AppDelegate.h:33` and implemented at `AppDelegate.m:176`, but `DockConnection.m` never imports `AppDelegate.h`. `[NSApp delegate]` is typed `id<NSApplicationDelegate>`, which does not declare the method, so the compiler falls back to a default `id` return type at three call sites. It works today only because the runtime resolves the selector dynamically — it is one delegate swap away from being a crash, and the compiler cannot type-check the call.

**Files:**
- Modify: `cotvnc/Source/DockConnection.m` (imports, and lines 49, 54, 60)

- [ ] **Step 1: Read the current imports and call sites**

Run:
```bash
cd cotvnc && sed -n '1,30p' Source/DockConnection.m && echo "--- calls ---" && sed -n '45,62p' Source/DockConnection.m
```

- [ ] **Step 2: Add the import**

Add to the `#import` block at the top of `Source/DockConnection.m`, alongside the existing imports:
```objc
#import "AppDelegate.h"
```
If the file uses angle-bracket imports (`#import <DockConnection.h>`), match that style: `#import <AppDelegate.h>`.

- [ ] **Step 3: Cast the delegate at each of the three call sites**

The import alone is not enough — `[NSApp delegate]` is still typed `id<NSApplicationDelegate>`. At lines 49, 54 and 60, change:
```objc
    [[NSApp delegate] removeDockConnection:self];
```
to:
```objc
    [(AppDelegate *)[NSApp delegate] removeDockConnection:self];
```

Verify `AppDelegate` is the actual class name first:
```bash
cd cotvnc && grep -n "@interface" Source/AppDelegate.h
```
If the class has a different name, use that name.

- [ ] **Step 4: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 3; `-Wobjc-method-access` reaches 0.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/DockConnection.m
git commit -m "type-check -removeDockConnection: calls in DockConnection"
```

---

## Task 3: `Session.h` declares three methods `Session` does not implement

`Session.h:103-104` declares `-windowDidDeminiaturize:` and `-windowDidMiniaturize:`, and `Session.h:115` declares `-setFrameBufferUpdateSeconds:`. None are implemented in `Session.m`. The miniaturize pair are `NSWindowDelegate` notifications — declaring them without implementing them means nothing happens on minimize, and the declarations mislead anyone reading the header. `-setFrameBufferUpdateSeconds:` is implemented on `RFBConnection` (`RFBConnection.m:1136`), and `Session.m` forwards to `[connection setFrameBufferUpdateSeconds:]` in four places — but `RFBConnectionManager.m:648` and `:661` call it **on the session**, which resolves at runtime only by accident of the declaration existing.

Decide per method: implement it, or delete the declaration and fix the callers.

**Files:**
- Modify: `cotvnc/Source/Session.h:103-104`, `cotvnc/Source/Session.h:115`
- Modify: `cotvnc/Source/Session.m` (add one method)
- Modify: `cotvnc/Source/RFBConnectionManager.m:648`, `:661`

- [ ] **Step 1: Confirm the callers and the absence of implementations**

Run:
```bash
cd cotvnc && grep -n "windowDidMiniaturize\|windowDidDeminiaturize\|setFrameBufferUpdateSeconds" Source/*.h Source/*.m
```
Expected: declarations in `Session.h`, no definitions in `Session.m`, a definition in `RFBConnection.m:1136`, and calls at `RFBConnectionManager.m:648,661` and `Session.m:593,606,661,677`.

- [ ] **Step 2: Delete the two miniaturize declarations**

Remove these two lines from `Source/Session.h` (lines 103-104):
```objc
- (void)windowDidDeminiaturize:(NSNotification *)aNotification;
- (void)windowDidMiniaturize:(NSNotification *)aNotification;
```
There is no implementation to preserve and no caller — AppKit only sends these if the delegate responds, and `Session` does not. Deleting the declarations makes the header honest. Do not write empty implementations; that would silence the warning while adding dead code.

- [ ] **Step 3: Implement `-setFrameBufferUpdateSeconds:` on `Session` as a forwarder**

`RFBConnectionManager.m:648` and `:661` call this on a `Session`, and `Session` already forwards this exact call to its connection in four other places. Keep the declaration at `Session.h:115` and add the implementation to `Source/Session.m`, next to the other connection-forwarding methods (near line 593):

```objc
- (void)setFrameBufferUpdateSeconds: (float)seconds
{
    [connection setFrameBufferUpdateSeconds: seconds];
}
```

Confirm the ivar is named `connection` first:
```bash
cd cotvnc && sed -n '590,610p' Source/Session.m
```
Use whatever name those existing forwarding calls use.

- [ ] **Step 4: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 3; `-Wincomplete-implementation` reaches 0.

- [ ] **Step 5: Smoke-test the update interval**

Launch the app, open Preferences, and change the frame buffer update interval for the front connection. Expected: no crash, and the setting applies. (Before this fix it worked by dynamic dispatch; after, it is statically checked. The observable behavior should be identical.)

- [ ] **Step 6: Commit**

```bash
git add cotvnc/Source/Session.h cotvnc/Source/Session.m
git commit -m "implement -setFrameBufferUpdateSeconds: on Session, drop dead declarations

RFBConnectionManager calls it on the session; Session only ever forwarded
it inline. The miniaturize delegate methods were declared but never
implemented and had no callers."
```

---

## Task 4: Duplicate `-connectToServer:` declaration

`ServerDataViewController.h` declares `- (IBAction)connectToServer:(id)sender;` twice, at lines 77 and 82. This produces a `-Wduplicate-method-match` warning in every one of the 12 translation units that import the header — the single largest warning cluster in the build, from a one-line fix.

**Files:**
- Modify: `cotvnc/Source/ServerDataViewController.h:82`

- [ ] **Step 1: Confirm both declarations are identical**

Run:
```bash
cd cotvnc && grep -n "connectToServer" Source/ServerDataViewController.h
```
Expected: two hits, lines 77 and 82, byte-identical. If the signatures differ, stop — that is a different problem.

- [ ] **Step 2: Delete the second declaration**

Remove line 82 from `Source/ServerDataViewController.h`:
```objc
- (IBAction)connectToServer:(id)sender;
```
Keep the one at line 77, which sits with the other `IBAction`s (`sharedChanged:`, `viewOnlyChanged:`, `useSshTunnelChanged:`, `sshHostChanged:`, `addServerChanged:`). Line 82 sits next to `cancelConnect:`.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: `-Wduplicate-method-match` reaches 0 — 12 warning lines, 1 unique site, gone.

- [ ] **Step 4: Verify the nib connection still works**

Launch the app. The connection dialog's Connect button must still work — the `IBAction` is wired in `Resources/Base.lproj`. Removing a duplicate declaration cannot break the connection (the selector is unchanged), but confirm the button responds.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/ServerDataViewController.h
git commit -m "remove duplicate -connectToServer: declaration"
```

---

## Task 5: `vncauth.c` leaks the password buffer and the file handle

`vncDecryptPasswdFromFile` at `Source/vncauth.c:100-129` `malloc`s a 9-byte buffer up front, then returns `NULL` on two error paths without freeing it. The analyzer reports both a `unix.Malloc` leak and a `unix.Stream` resource leak. This runs on the `--PasswordFile` command-line path, so it leaks decrypted-password-sized allocations — worth fixing properly rather than suppressing.

**Files:**
- Modify: `cotvnc/Source/vncauth.c:100-129`

- [ ] **Step 1: Read the whole function**

Run:
```bash
cd cotvnc && sed -n '95,132p' Source/vncauth.c
```

Current shape:
```c
    FILE *fp;
    int i, ch;
    unsigned char *passwd = (unsigned char *)malloc(9);

    if (strcmp(fname, "-") != 0) {
	if ((fp = fopen(fname,"r")) == NULL)
	    return NULL;              /* leaks passwd */
    } else {
	fp = stdin;
    }
    ...
    if (fp != stdin)
	fclose(fp);

    if (i != 8)                 /* Could not read eight bytes */
	return NULL;              /* leaks passwd */
```

- [ ] **Step 2: Free on both error paths and handle malloc failure**

Rewrite the function body so both early returns release the buffer, and a failed `malloc` does not get dereferenced. Preserve the existing tab indentation and the `/* Could not read eight bytes */` comment.

```c
    FILE *fp;
    int i, ch;
    unsigned char *passwd = (unsigned char *)malloc(9);

    if (passwd == NULL)
	return NULL;

    if (strcmp(fname, "-") != 0) {
	if ((fp = fopen(fname,"r")) == NULL) {
	    free(passwd);
	    return NULL;
	}
    } else {
	fp = stdin;
    }

    for (i = 0; i < 8; i++) {
	ch = getc(fp);
	if (ch == EOF)
	    break;
	passwd[i] = ch;
    }

    if (fp != stdin)
	fclose(fp);

    if (i != 8) {               /* Could not read eight bytes */
	free(passwd);
	return NULL;
    }

    deskey(s_fixedkey, DE1);
    des(passwd, passwd);

    passwd[8] = 0;

    return (char *)passwd;
```

Note the `fclose` already runs before the `i != 8` check, so the stream is closed on that path — the analyzer's `unix.Stream` report is resolved by the same restructuring that makes the ownership obvious.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 2; the `unix.Malloc` and `unix.Stream` analyzer findings are gone. `Analyze .../vncauth.c` no longer appears in the "commands produced analyzer issues" list.

- [ ] **Step 4: Smoke-test the password-file path**

```bash
cd cotvnc && printf 'testpass' > /tmp/vncpw && \
  ./build/Development/Chicken.app/Contents/MacOS/Chicken --PasswordFile /tmp/vncpw --Host localhost 2>&1 | head -5; \
  rm -f /tmp/vncpw
```
Expected: no "Cannot read password from file." for a valid 8-byte file, and no crash. Then test the error path with a short file:
```bash
cd cotvnc && printf 'ab' > /tmp/vncpw && \
  ./build/Development/Chicken.app/Contents/MacOS/Chicken --PasswordFile /tmp/vncpw --Host localhost 2>&1 | head -5; \
  rm -f /tmp/vncpw
```
Expected: `Cannot read password from file.` and a clean `exit(1)`, not a crash.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/vncauth.c
git commit -m "fix password buffer leak on error paths in vncDecryptPasswdFromFile"
```

---

## Task 6: `-initFromMainMenu` never chains its initializer

`KeyEquivalentScenario.m:88-94` reads:

```objc
- (id)initFromMainMenu
{
    if ([self init] != nil) {
        NSMenu *mainMenu = [NSApp mainMenu];
        [self loadKeyEquivalentsFromMenu: mainMenu];
    }
    return self;
}
```

It calls `[self init]` but discards the result and returns the original `self` unconditionally. If `-init` ever returns `nil` or a different object (the standard initializer contract), this returns a half-initialized or freed object. The analyzer flags it as `osx.cocoa.SelfInit`.

**Files:**
- Modify: `cotvnc/Source/KeyEquivalentScenario.m:88-94`

- [ ] **Step 1: Check what `-init` does in this class**

Run:
```bash
cd cotvnc && grep -n "^- (id)init\|^- (instancetype)init\|mEquivalentToEntryMapping" Source/KeyEquivalentScenario.m | head -20
```
You need to know whether `-init` is overridden here (allocating `mEquivalentToEntryMapping`) or inherited from `NSObject`. The fix is the same either way, but this tells you whether the `nil` branch is reachable in practice.

- [ ] **Step 2: Assign the result of the chained initializer**

Replace the method with:
```objc
- (id)initFromMainMenu
{
    if ((self = [self init])) {
        NSMenu *mainMenu = [NSApp mainMenu];
        [self loadKeyEquivalentsFromMenu: mainMenu];
    }
    return self;
}
```

The double parentheses are deliberate — they tell the compiler the assignment-in-condition is intentional and suppress `-Wparentheses`, which is enabled in this project.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 1; the `osx.cocoa.SelfInit` finding is gone and `Analyze .../KeyEquivalentScenario.m` leaves the analyzer-issues list.

- [ ] **Step 4: Smoke-test key equivalents**

Launch the app and open a connection. Key equivalents are loaded from the main menu into the scenario at startup; verify that menu shortcuts (⌘W, ⌘Q) still work and that `EventFilter`'s menu-key interception is unchanged.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/KeyEquivalentScenario.m
git commit -m "chain the initializer properly in -initFromMainMenu"
```

---

## Task 7: Dead store in `PrefController` prefs migration

`PrefController.m:84` sets `prefsVersion = 0x00000002;` at the end of a version-migration ladder, and nothing reads it afterward. The variable documents the migration sequence, so deleting the assignment outright loses information for whoever adds version 3.

**Files:**
- Modify: `cotvnc/Source/PrefController.m:70-90`

- [ ] **Step 1: Read the full migration block**

Run:
```bash
cd cotvnc && sed -n '60,92p' Source/PrefController.m
```

- [ ] **Step 2: Replace the dead store with a comment that carries the same information**

The final ladder rung currently reads:
```objc
		if ( 0x00000001 == prefsVersion )
		{
			// some menu items have changed
			[defaults removeObjectForKey: @"KeyEquivalentScenarios"];
			prefsVersion = 0x00000002;
		}
```

Change to:
```objc
		if ( 0x00000001 == prefsVersion )
		{
			// some menu items have changed
			[defaults removeObjectForKey: @"KeyEquivalentScenarios"];
			// prefsVersion is now 0x00000002; when adding a version 3
			// migration, re-add the assignment above and test for it here.
		}
```

This keeps the ladder readable without storing a value nothing reads. Do **not** add `(void)prefsVersion;` or a pragma — the comment is the honest fix.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 1; `deadcode.DeadStores` gone; `Analyze .../PrefController.m` leaves the analyzer-issues list. All four analyzer findings are now resolved and `** ANALYZE SUCCEEDED **` reports no commands with analyzer issues.

- [ ] **Step 4: Smoke-test prefs migration**

```bash
defaults read com.geekspiff.chickenofthevnc 2>/dev/null | head -20
```
Launch the app, confirm Preferences opens and settings persist across a relaunch. If you want to exercise the migration path itself, back up and delete the version key first:
```bash
defaults read com.geekspiff.chickenofthevnc > /tmp/chicken-prefs-backup.txt
```
(Restore from the backup if anything goes wrong. Confirm the actual bundle identifier from `Resources/Info.plist` before running these.)

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/PrefController.m
git commit -m "remove dead store in prefs version migration"
```

---

## Task 8: `NSView *` assigned to `NSClipView *` in `Session`

`Session.m:438` does `contentView = [scrollView contentView];`. On the current SDK `-[NSScrollView contentView]` is typed `NSView * _Nullable`, while the local is `NSClipView *` — an implicit downcast the compiler rejects with `-Wincompatible-pointer-types`. The very next line calls `-constrainScrollPoint:`, an `NSClipView` method, so the code genuinely requires a clip view.

**Files:**
- Modify: `cotvnc/Source/Session.m:438`

- [ ] **Step 1: Read the surrounding block and find the declaration**

Run:
```bash
cd cotvnc && sed -n '425,445p' Source/Session.m && echo "--- decl ---" && grep -n "contentView" Source/Session.m Source/Session.h
```
Determine whether `contentView` is a local or an ivar.

- [ ] **Step 2: Add the explicit cast**

Change line 438 from:
```objc
	contentView = [scrollView contentView];
```
to:
```objc
	contentView = (NSClipView *)[scrollView contentView];
```

An `NSScrollView`'s content view is always an `NSClipView` in practice; the SDK's looser return type is for subclass flexibility. The cast documents the requirement that the next line already depends on.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 1; `-Wincompatible-pointer-types` reaches 0. (`Session.m:439`'s `constrainScrollPoint:` deprecation warning remains — that is Task 20.)

- [ ] **Step 4: Smoke-test scrolling**

Connect to a VNC server whose desktop is larger than the window. Confirm the view scrolls to the bottom-left on connect (that is what the `constrainScrollPoint:` line does) and that scrolling with the trackpad works.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/Session.m
git commit -m "cast NSScrollView contentView to NSClipView explicitly"
```

---

## Task 9: Header and implementation disagree on parameter types

Three methods are declared with one parameter type and implemented with another. The compiler accepts this but the mismatch means the implementation silently truncates on 64-bit:

| Site | Declared | Implemented |
|---|---|---|
| `EventFilter.m:438` `-queueModifierPressed:timestamp:` | `NSEventModifierFlags` (`EventFilter.h:155`) | `unsigned int` |
| `EventFilter.m:447` `-queueModifierReleased:timestamp:` | `NSEventModifierFlags` (`EventFilter.h:156`) | `unsigned int` |
| `Profile.m:677` `-setEmulationScenario:forButton:` | `EventFilterEmulationScenario` (`Profile.h:145`) | `unsigned int` vs `NSInteger` |

`NSEventModifierFlags` is a 64-bit `NS_OPTIONS` enum. `EventFilter.m:432` passes `masks[i]` — the caller loops over modifier masks. On current macOS all defined modifier bits fit in 32 bits, so this does not misbehave today, but it will the moment Apple defines a flag above bit 31.

**Files:**
- Modify: `cotvnc/Source/EventFilter.m:438`, `:447`
- Modify: `cotvnc/Source/Profile.m:676-677`

- [ ] **Step 1: Read all three declarations and implementations**

Run:
```bash
cd cotvnc && grep -n "queueModifierPressed\|queueModifierReleased" Source/EventFilter.h Source/EventFilter.m && \
  echo "--- profile ---" && \
  sed -n '143,148p' Source/Profile.h && sed -n '674,682p' Source/Profile.m && \
  grep -n "typedef.*EventFilterEmulationScenario" Source/*.h
```

- [ ] **Step 2: Widen the two `EventFilter` implementations to match the header**

At `Source/EventFilter.m:438`, change:
```objc
- (void)queueModifierPressed: (unsigned int)modifier timestamp: (NSTimeInterval)timestamp
```
to:
```objc
- (void)queueModifierPressed: (NSEventModifierFlags)modifier timestamp: (NSTimeInterval)timestamp
```

At `Source/EventFilter.m:447`, change:
```objc
- (void)queueModifierReleased: (unsigned int)modifier timestamp: (NSTimeInterval)timestamp
```
to:
```objc
- (void)queueModifierReleased: (NSEventModifierFlags)modifier timestamp: (NSTimeInterval)timestamp
```

Then check the bodies: if either assigns `modifier` into a 32-bit field or passes it to a 32-bit parameter, that becomes a new `-Wshorten-64-to-32` warning. Read the bodies and, where the value is stored into the queue's 32-bit modifier state, add an explicit cast with a comment noting all currently-defined modifier bits are below bit 31. Task 14 handles `EventFilter`'s existing truncation warnings; if this task creates new ones, fix them here rather than deferring.

- [ ] **Step 3: Align `-setEmulationScenario:forButton:`**

Read both signatures from Step 1. Make the implementation at `Source/Profile.m:676-677` use exactly the types from `Source/Profile.h:145`. The warning names both an `unsigned int` vs `NSInteger` mismatch on the `forButton:` parameter — match the header, and if the header's own type is the odd one out (e.g. `unsigned int` where every caller passes an `NSInteger` tag from a popup), change the header to `NSInteger` and update the implementation to match. Check the callers before deciding:
```bash
cd cotvnc && grep -rn "setEmulationScenario" Source/
```

- [ ] **Step 4: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: `-Wmismatched-parameter-types` reaches 0 (down 3). The `-Wshorten-64-to-32` count must not increase; if it does, resolve the new sites now.

- [ ] **Step 5: Smoke-test modifier handling and button emulation**

Connect to a server. Verify: holding ⌘/⌥/⌃/⇧ reaches the remote side; releasing them clears the remote modifier state; and multi-button mouse emulation still works for whichever scenario the active profile selects (Preferences → Profiles → emulation settings).

- [ ] **Step 6: Commit**

```bash
git add cotvnc/Source/EventFilter.m cotvnc/Source/Profile.m
git commit -m "align method parameter types between headers and implementations"
```

---

## Task 10: Profile Manager encoding drag-and-drop is dead code

`ProfileManager.m:329` implements `-tableView:writeRows:toPasteboard:`, deprecated since macOS 10.4 and **no longer called by AppKit**. Dragging to reorder encodings in the Profile Manager therefore does nothing. Fixing the warning means restoring the feature, so this task changes behavior — verify it manually.

`ProfileManager.m:218` and `ServerDataViewController.m:325` implement `-controlTextDidChange:`, also flagged by `-Wdeprecated-implementations`; those are handled in Task 22 because they are a different problem.

**Files:**
- Modify: `cotvnc/Source/ProfileManager.m:329` and the surrounding drag-source methods

- [ ] **Step 1: Read the existing drag implementation and its partners**

Run:
```bash
cd cotvnc && grep -n "tableView:" Source/ProfileManager.m && echo "--- writeRows ---" && sed -n '325,375p' Source/ProfileManager.m
```
You need the full set: the `writeRows` method, the `validateDrop` method, and the `acceptDrop` method. Note the pasteboard type string it registers and what it puts on the pasteboard.

- [ ] **Step 2: Replace `writeRows:` with `writeRowsWithIndexes:`**

Change the signature from:
```objc
- (BOOL)tableView:(NSTableView *)tableView writeRows:(NSArray *)rows toPasteboard:(NSPasteboard *)pboard
```
to:
```objc
- (BOOL)tableView:(NSTableView *)tableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
```

The old method received an `NSArray` of `NSNumber` row indices; the new one receives an `NSIndexSet`. Inside the body, replace index extraction accordingly. If the body archived the row array onto the pasteboard, archive the index set instead — and update the matching `acceptDrop` method to read it back the same way. The two must agree; read both before editing either.

If the body only ever uses the first selected row (common in single-selection tables), the conversion is:
```objc
	NSUInteger row = [rowIndexes firstIndex];
	if (row == NSNotFound)
		return NO;
```

- [ ] **Step 3: Verify the table view is registered for the drag type**

Run:
```bash
cd cotvnc && grep -n "registerForDraggedTypes\|setDraggingSourceOperationMask" Source/ProfileManager.m
```
If the encoding table view is never registered for dragged types, dragging cannot work regardless of the data source method — add the registration in the same place the table view is configured (likely `-awakeFromNib` or the window-loading method), using the same pasteboard type the `writeRows` body uses.

- [ ] **Step 4: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 1; `-Wdeprecated-implementations` drops from 3 to 2.

- [ ] **Step 5: Smoke-test the restored feature**

Launch the app → Preferences → Profiles → select the encodings list. Drag an encoding to a different position. Expected: the row moves and the new order persists after closing and reopening the Profile Manager. **This did not work before this task** — if it still does not work, the drag registration in Step 3 or the `acceptDrop` counterpart is the remaining gap. Do not commit a half-working drag; either finish it or revert to the deprecated method and note the limitation in the commit.

- [ ] **Step 6: Commit**

```bash
git add cotvnc/Source/ProfileManager.m
git commit -m "restore encoding drag-and-drop in Profile Manager

-tableView:writeRows:toPasteboard: was deprecated in 10.4 and is no
longer called by AppKit, so reordering silently did nothing."
```

---

# Phase 2 — Mechanical, behavior-preserving

Nothing in this phase should change runtime behavior. If a smoke test shows a difference, you made a mistake.

## Task 11: `d3des.c` K&R function definitions

`Source/d3des.c` defines eight functions in pre-ANSI K&R style (`void deskey(key, edf) unsigned char *key; int edf; { ... }`) at lines 72, 109, 132, 142, 152, 163, 178 and 337. Clang warns that this is deprecated in all C versions and removed in C23. Prototypes already exist in `d3des.h`, so converting the definitions is purely mechanical.

**Files:**
- Modify: `cotvnc/Source/d3des.c` (lines 72, 109, 132, 142, 152, 163, 178, 337)

- [ ] **Step 1: List every K&R definition with its current signature**

Run:
```bash
cd cotvnc && grep -n "deprecated-non-prototype" /dev/null; \
  for n in 72 109 132 142 152 163 178 337; do \
    echo "--- line $n ---"; sed -n "${n},$((n+4))p" Source/d3des.c; \
  done
```

Also read the authoritative prototypes:
```bash
cd cotvnc && grep -n "extern\|static" Source/d3des.h Source/d3des.c | grep "(" | head -30
```

- [ ] **Step 2: Convert each definition to ANSI style**

For each, fold the parameter declarations into the parameter list. Keep the trailing comments and the file's tab indentation. Example — line 72 currently:
```c
void deskey(key, edf)	/* Thanks to James Gillogly & Phil Karn! */
unsigned char *key;
int edf;
{
```
becomes:
```c
void deskey(unsigned char *key, int edf)	/* Thanks to James Gillogly & Phil Karn! */
{
```

And line 109:
```c
static void cookey(raw1)
register unsigned long *raw1;
{
```
becomes:
```c
static void cookey(register unsigned long *raw1)
{
```

`register` is still valid in a parameter list in C17; keep it to minimise the diff. Do this for all eight. The types in the new parameter lists must match `d3des.h` exactly — if any definition's implicit type disagrees with the header, that is a latent bug; stop and report it rather than silently picking one.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 8; `-Wdeprecated-non-prototype` reaches 0.

- [ ] **Step 4: Verify DES still produces identical output**

This code implements the VNC authentication cipher — a silent behavior change breaks every password login. Test it directly:

```bash
cd cotvnc && cat > /tmp/test_d3des.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include "d3des.h"

int main(void) {
    /* Fixed key and plaintext; the ciphertext below was captured from the
     * pre-conversion build. Any difference means the conversion changed
     * behavior and VNC authentication is broken. */
    unsigned char key[8] = {0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef};
    unsigned char in[8]  = {0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xe7};
    unsigned char out[8];
    int i;
    deskey(key, 0);           /* 0 == EN0, encrypt */
    des(in, out);
    for (i = 0; i < 8; i++) printf("%02x", out[i]);
    printf("\n");
    return 0;
}
EOF
clang -Wall -ISource /tmp/test_d3des.c Source/d3des.c -o /tmp/test_d3des && /tmp/test_d3des
```

**Run this on the pre-change code first** (`git stash`, run, `git stash pop`), record the hex output, then run it after the conversion. The two must be byte-identical. Confirm the `EN0`/`DE1` constant values in `d3des.h` and use the right one.

- [ ] **Step 5: Smoke-test a real authenticated connection**

Connect to a VNC server that requires a password. Authentication must succeed. This is the test that matters.

- [ ] **Step 6: Commit**

```bash
git add cotvnc/Source/d3des.c
git commit -m "convert d3des.c to ANSI function definitions

K&R definitions are removed in C23. Prototypes were already in d3des.h;
verified the cipher produces byte-identical output."
```

---

## Task 12: Unused variable in `MyApp`

`MyApp.m:31` declares `static Class NSScrollViewClass = nil;` and assigns `[NSScrollView class]` to it inside the one-time initialization block, but nothing ever reads it. The neighbouring `RFBViewClass` is used; this one is a leftover.

**Files:**
- Modify: `cotvnc/Source/MyApp.m:31`, `:35`

- [ ] **Step 1: Confirm it is genuinely unused**

Run:
```bash
cd cotvnc && grep -n "NSScrollViewClass" Source/MyApp.m
```
Expected: exactly two hits — the declaration at line 31 and the assignment at line 35. If there is a third, it is used and this task is wrong.

- [ ] **Step 2: Delete both lines**

Remove from `Source/MyApp.m`:
```objc
	static Class NSScrollViewClass = nil;
```
and, inside the `if ( ! RFBViewClass )` block:
```objc
		NSScrollViewClass = [NSScrollView class];
```

Leave `RFBViewClass` and its assignment alone, and keep the `// do some static lookups for a tiny speed gain` comment.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 1; `-Wunused-but-set-variable` reaches 0.

- [ ] **Step 4: Smoke-test menu key equivalents**

This method intercepts key equivalents before they reach `RFBView`. Connect to a server and confirm ⌘-key menu shortcuts still reach the menu (not the remote desktop) as configured by the active `KeyEquivalentScenario`.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/MyApp.m
git commit -m "remove unused NSScrollViewClass lookup in MyApp"
```

---

## Task 13: Truncating casts — UI and settings code (~27 sites)

The largest cluster of `-Wshorten-64-to-32` warnings comes from reading `NSInteger`/`NSUInteger` out of AppKit controls and collections and storing them in `int`/`unsigned int` model fields. These are bounded by UI reality — a popup index, a checkbox state, a table row count — so explicit casts are the correct fix, not widening every model field.

**Decision rule for every site in this task:** if the value's range is bounded by the UI (control tag, popup index, state, row index, array count of a collection the user maintains by hand), add an explicit cast. If the value comes off the wire or from a file, it belongs in Task 15 instead — do not cast it here.

**Files (site counts from the baseline build):**
- Modify: `cotvnc/Source/ProfileManager.m` — lines 155, 158, 160, 162, 163, 165, 170, 173, 175, 177, 178, 180, 184, 185, 186, 195, 246, 279 (18 sites)
- Modify: `cotvnc/Source/Profile.m` — lines 89, 409 (2 sites)
- Modify: `cotvnc/Source/ProfileDataManager.m` — line 111
- Modify: `cotvnc/Source/ProfileManager_private.m` — line 35
- Modify: `cotvnc/Source/ServerDataManager.m` — lines 299, 334
- Modify: `cotvnc/Source/ListenerController.m` — line 414
- Modify: `cotvnc/Source/ConnectionWaiter.m` — line 305
- Modify: `cotvnc/Source/CursorPseudoEncodingReader.m` — line 97

- [ ] **Step 1: Get the exact current line for every site**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh 2>/dev/null | grep "shorten-64-to-32" | sort
```
Work from this list, not from the line numbers above — earlier tasks may have shifted them.

- [ ] **Step 2: Apply the casts, one file at a time**

Worked example, `ProfileManager.m:155`:
```objc
	[profile setEmulationScenario: [sender indexOfSelectedItem] forButton: button];
```
`-indexOfSelectedItem` returns `NSInteger`; the parameter is `EventFilterEmulationScenario` (32-bit). A popup index cannot exceed the number of menu items:
```objc
	[profile setEmulationScenario: (EventFilterEmulationScenario)[sender indexOfSelectedItem] forButton: button];
```

Worked example, `ProfileDataManager.m:111`:
```objc
	return [mProfiles count];
```
into an `int` return. Collection counts here are user-maintained profile lists:
```objc
	return (int)[mProfiles count];
```

Worked example, `ConnectionWaiter.m:305`:
```objc
        ret = NSRunAlertPanel(theAction, message, ok, NULL, NULL, NULL);
```
`ret` is `int`, `NSRunAlertPanel` returns `NSInteger`. Change the local's type instead of casting — the return is a small enumerated response code:
```objc
        NSInteger ret;
        ret = NSRunAlertPanel(theAction, message, ok, NULL, NULL, NULL);
```
Then check `-errorDidEnd:returnCode:contextInfo:` — if its `returnCode:` parameter is `int`, widen it to `NSInteger` too. (Task 23 rewrites this call entirely; doing it correctly here keeps the two tasks from fighting.)

For `CursorPseudoEncodingReader.m:97`, read the site first — cursor dimensions come off the wire, but are bounded to `CARD16` by the protocol. If the truncation source is an `NSData` length derived from a `CARD16`, cast explicitly and add a one-line comment naming the bound.

- [ ] **Step 3: Build after each file, not at the end**

Run after each file:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
The count must drop monotonically. If it goes up, the cast changed a type in a way that created a new mismatch — fix it before moving to the next file.

- [ ] **Step 4: Smoke-test the settings UI end to end**

This task touches nearly everything the Preferences and Profile Manager windows do. Launch the app and verify:
- Preferences → Profiles: create a profile, change every popup (encodings, color depth, each mouse-button emulation scenario), close and reopen — every setting must round-trip.
- The server list (add, edit, delete a saved server) still persists across a relaunch.
- The listener window (`ListenerController`) opens and accepts a port number.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/ProfileManager.m cotvnc/Source/Profile.m \
        cotvnc/Source/ProfileDataManager.m cotvnc/Source/ProfileManager_private.m \
        cotvnc/Source/ServerDataManager.m cotvnc/Source/ListenerController.m \
        cotvnc/Source/ConnectionWaiter.m cotvnc/Source/CursorPseudoEncodingReader.m
git commit -m "add explicit casts for UI-bounded 64-to-32 truncations"
```

---

## Task 14: Truncating casts — `EventFilter` (8 sites)

`EventFilter.m` truncates `NSEventModifierFlags` and `NSUInteger` into `int`/`unsigned int` at lines 245, 428, 472, 569, 685, 687, 752 and 856. Modifier flags are the interesting case: the type is 64-bit, but every currently-defined flag sits below bit 31, and the RFB protocol's key events are 32-bit anyway.

**Files:**
- Modify: `cotvnc/Source/EventFilter.m` — lines 245, 428, 472, 569, 685, 687, 752, 856

- [ ] **Step 1: Get the current sites**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh 2>/dev/null | grep "EventFilter.m.*shorten-64-to-32" | sort
```

- [ ] **Step 2: Cast, with a comment where the bound is non-obvious**

For the modifier-flag sites (245, 428), the value is an `NSEventModifierFlags` stored into the filter's 32-bit modifier state:
```objc
	// All AppKit modifier flags are defined below bit 31; the RFB wire
	// format carries 32-bit keysyms, so the queue stores 32 bits.
	unsigned int flags = (unsigned int)[theEvent modifierFlags];
```
Add that comment once, at the first such site, and just cast at the second.

For the `NSUInteger` → `int` sites (472, 685, 687, 752, 856), these are queue indices and counts into `EventFilter`'s own event queue. Read each site and cast explicitly. If any is a `[array count]` used as a loop bound, prefer changing the loop variable to `NSUInteger` over casting the count — that removes the truncation instead of documenting it.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 8; no `EventFilter.m` entries remain under `-Wshorten-64-to-32`.

- [ ] **Step 4: Smoke-test input thoroughly**

`EventFilter` is the input path — a mistake here breaks typing. Connect to a server and verify:
- Typing ordinary characters, including shifted characters.
- Each modifier individually: ⇧ ⌃ ⌥ ⌘ — press, observe the remote side, release, confirm the remote modifier clears.
- Mouse: left click, right click (and whichever multi-button emulation the profile uses — ⌘-click, ⌥-click, click-and-hold, per `EventFilter.h`'s documented scenarios).
- Dragging with the button held.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/EventFilter.m
git commit -m "add explicit casts for event-queue 64-to-32 truncations"
```

---

## Task 15: Truncating casts — wire-derived lengths (10 sites)

These sites truncate lengths that originate from the network or from `NSData` objects built from network reads. Most are bounded in practice by the RFB protocol (`CARD16` rect dimensions, `CARD32` lengths) or by zlib's API, which takes a 32-bit `uInt` regardless. **One is a genuine latent heap overflow** and must be fixed with a bounds check, not a cast.

**Files:**
- Modify: `cotvnc/Source/RFBConnection.m` — lines 398, 837, 886, 915, 939
- Modify: `cotvnc/Source/TightEncodingReader.m` — lines 272, 300
- Modify: `cotvnc/Source/ZlibHexEncodingReader.m` — lines 83, 111
- Modify: `cotvnc/Source/ZRLEEncodingReader.m` — line 37

- [ ] **Step 1: Fix the under-allocation at `RFBConnection.m:837` first**

Current code:
```objc
    NSData *compressed = compressZlib(payload);
    if (!compressed) {
        NSLog(@"Failed to compress clipboard data");
        return;
    }

    unsigned int msgSz = 12 + [compressed length];
    unsigned char *buf = malloc(msgSz);
```

`[compressed length]` is `NSUInteger` (64-bit). If it ever exceeds `UINT_MAX - 12`, `msgSz` wraps, `malloc` succeeds with a tiny buffer, and the subsequent writes overflow the heap. Clipboard contents are user-controlled, so this is worth a real guard rather than a cast:

```objc
    NSUInteger compressedLen = [compressed length];
    if (compressedLen > UINT_MAX - 12) {
        NSLog(@"Clipboard data too large to send (%lu bytes)",
              (unsigned long)compressedLen);
        return;
    }

    unsigned int msgSz = 12 + (unsigned int)compressedLen;
    unsigned char *buf = malloc(msgSz);
```

`UINT_MAX` needs `#import <limits.h>` — check whether the file already gets it transitively before adding the import.

- [ ] **Step 2: Guard the clipboard string length at `RFBConnection.m:886`**

`-sendStringToServersClipboard:length:` takes `(unsigned)len`, and `RFBConnection.m:886` passes `strlen(cStr)` (`size_t`). Same exposure, same fix shape — check the length against `UINT_MAX` before the cast, and log and return if it exceeds. Read lines 880-890 for the exact call before editing. `RFBConnection.m:915` passes `[data length]` to the same method; guard it the same way.

- [ ] **Step 3: Cast the socket-read sites**

`RFBConnection.m:398` — `consumed = [currentReader readBytes:bytes length:length]` where `length` is `ssize_t` from `read(2)` and the parameter is `unsigned int`. The value is bounded by the read buffer size, and the preceding lines already reject `length <= 0`, so an explicit cast is correct:
```objc
            consumed = [currentReader readBytes:bytes length:(unsigned int)length];
```
`RFBConnection.m:939` is in `-reallyWriteBytes:length:` — read lines 935-945 and apply the same reasoning; `write(2)`'s `ssize_t` result is bounded by the `length` argument, which is already `unsigned int`.

- [ ] **Step 4: Cast the zlib and JPEG length sites, with a comment**

`TightEncodingReader.m:272` (`JpegSetSrcManager(..., [data length])`), `TightEncodingReader.m:300` (`stream->avail_in = [data length]`), `ZlibHexEncodingReader.m:83` (`encodedStream.avail_in = [data length]`), `ZlibHexEncodingReader.m:111`, and `ZRLEEncodingReader.m:37` (`int length = [nsData length]`) all feed 32-bit APIs.

zlib's `avail_in` is a `uInt` by definition — the truncation is inherent to the API, not to this code. Add explicit casts and one comment per file explaining the bound:
```objc
	// avail_in is a 32-bit uInt by zlib's API. The data length comes from a
	// CARD32 read off the wire, so it cannot exceed 32 bits.
	stream->avail_in = (uInt)[data length];
```

Before writing that comment, **verify the claim** for each reader — trace where the `NSData` is constructed and confirm its length derives from a `CARD32` or smaller field in `rfbproto.h`. If any path can produce a length not bounded by the protocol, add a guard like Step 1 instead of a bare cast.

- [ ] **Step 5: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 10; `-Wshorten-64-to-32` reaches 0 (all of Tasks 13, 14, 15 complete) except for the 8 sites in `KeyChain.m`, which Task 16 handles.

- [ ] **Step 6: Smoke-test every encoding and the clipboard**

Connect to a server and, via Preferences → Profiles, force each encoding in turn: Raw, CopyRect, RRE, CoRRE, Hextile, Tight, Zlib, ZlibHex, ZRLE. For each: confirm the screen draws correctly, including after a window resize (which exercises the framebuffer clipping path). Then test the clipboard in both directions — copy text on the remote side and paste locally, and copy locally and paste remotely. Include a large clipboard payload (a few hundred KB of text) to exercise the compression path.

- [ ] **Step 7: Commit**

```bash
git add cotvnc/Source/RFBConnection.m cotvnc/Source/TightEncodingReader.m \
        cotvnc/Source/ZlibHexEncodingReader.m cotvnc/Source/ZRLEEncodingReader.m
git commit -m "guard clipboard length arithmetic, cast wire-derived lengths

The clipboard send path computed a 32-bit buffer size from a 64-bit
length, which could wrap and under-allocate. Remaining sites feed
inherently-32-bit APIs (zlib uInt, RFB CARD32) and take explicit casts."
```

---

## Task 16: Truncating casts — `KeyChain.m` (8 sites)

`KeyChain.m` passes `[string length]` and `strlen` results (`NSUInteger`/`size_t`) to `SecKeychain*` parameters typed `UInt32`, at lines 47, 51 (×2), 52 (×2), 73 (×2), 105 (×2). Do this before the `SecItem` migration in Task 26 so that task starts from a clean file.

**Files:**
- Modify: `cotvnc/Source/KeyChain.m` — lines 47, 51, 52, 73, 105

- [ ] **Step 1: Read the whole file — it is small**

Run:
```bash
cd cotvnc && cat -n Source/KeyChain.m
```

- [ ] **Step 2: Cast each length argument to `UInt32`**

Every one of these is a service name, account name, or password length. Passwords and hostnames cannot approach 4 GB. Example at line 51:
```objc
	status = SecKeychainAddGenericPassword(NULL, (UInt32)strlen(serviceName), serviceName,
	                                       (UInt32)strlen(accountName), accountName,
	                                       (UInt32)strlen(password), password, NULL);
```
Apply the same pattern at each site. Do not restructure the calls — Task 26 replaces them wholesale.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 8; `-Wshorten-64-to-32` reaches **0**. The `-Wdeprecated-declarations` warnings in `KeyChain.m` remain — Task 26.

- [ ] **Step 4: Smoke-test password storage**

Connect to a password-protected server with "remember password" checked. Quit and relaunch; the password must be filled in. Then verify it in Keychain Access.app — search for the server name and confirm the item exists. Finally, uncheck "remember password" for that server and confirm the item is deleted.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/KeyChain.m
git commit -m "cast keychain length arguments to UInt32"
```

---

# Phase 3 — Drop-in deprecation replacements

Every replacement here exists in macOS 11.0 and preserves behavior. Stop before Phase 4 if you want the low-risk subset.

## Task 17: `+[NSBundle loadNibNamed:owner:]` → `-loadNibNamed:owner:topLevelObjects:`

Deprecated in 10.8. Four sites: `AuthPrompt.m:28`, `PrefController_private.m:118`, `ServerDataViewController.m:44`, `Session.m:84`.

**This is the one deprecation with a memory-management trap.** The old class method leaked top-level objects by design under manual retain/release, and this codebase has no ARC. The replacement returns top-level objects in an **autoreleased** array, so objects the nib owner does not retain will be deallocated at the end of the current run loop. Every site must retain what it needs.

**Files:**
- Modify: `cotvnc/Source/AuthPrompt.m:28`
- Modify: `cotvnc/Source/PrefController_private.m:118`
- Modify: `cotvnc/Source/ServerDataViewController.m:44`
- Modify: `cotvnc/Source/Session.m:84`

- [ ] **Step 1: For each site, determine what holds the top-level objects**

Run:
```bash
cd cotvnc && grep -n "loadNibNamed" Source/*.m
```
Then, for each, read the surrounding method and the class's ivars. The question to answer per site: **is every top-level object in the nib connected to a retained `IBOutlet`, or does something rely on the nib's implicit retain?**

For `AuthPrompt.m:28`, the owner is `self` and the top-level object is the `panel` outlet:
```bash
cd cotvnc && grep -n "panel" Source/AuthPrompt.h Source/AuthPrompt.m
```
If `panel` is a plain (non-retained) `IBOutlet` ivar — the norm in this codebase — it must be retained explicitly after the change.

- [ ] **Step 2: Convert `AuthPrompt.m:28`**

From:
```objc
        [NSBundle loadNibNamed:@"AuthPrompt" owner:self];
```
To:
```objc
        NSArray *topLevelObjects = nil;
        if (![[NSBundle mainBundle] loadNibNamed:@"AuthPrompt"
                                           owner:self
                                 topLevelObjects:&topLevelObjects]) {
            NSLog(@"Failed to load AuthPrompt nib");
            [self release];
            return nil;
        }
        /* topLevelObjects is autoreleased; retain the panel so it outlives
         * this run loop iteration. Balanced by -release in -dealloc. */
        [panel retain];
```

Then add the balancing release to `-dealloc`. If `AuthPrompt` has no `-dealloc`, add one:
```objc
- (void)dealloc
{
    [panel release];
    [super dealloc];
}
```
Check first whether `-dealloc` already exists and whether it already releases `panel`.

- [ ] **Step 3: Convert the remaining three sites the same way**

`PrefController_private.m:118`, `ServerDataViewController.m:44` and `Session.m:84` each need the same treatment: replace the call, check the failure return, and retain the top-level objects the class keeps a pointer to. For each, read the class's `-dealloc` and add the balancing release.

`Session.m:84` is the highest-risk of the four — the session window itself comes from that nib. Read `Session.m:80-95` and the `-dealloc` carefully. If retaining individual outlets is awkward, retaining the whole `topLevelObjects` array into an ivar and releasing it in `-dealloc` is a valid and simpler alternative:
```objc
    _nibTopLevelObjects = [topLevelObjects retain];
```

- [ ] **Step 4: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 4.

- [ ] **Step 5: Smoke-test with zombies enabled**

Over-releasing here produces a crash on a later window operation, not at load time. `VNCViewer_main.m` has a `DEBUG_MEMORY` block that enables zombies — enable it, rebuild, and exercise every affected nib:
- The auth prompt (connect to an SSH-tunnelled server that asks for a password).
- Preferences (`PrefController`).
- The connection dialog (`ServerDataViewController`).
- A session window: open it, resize it, close it, open another.

Any `message sent to deallocated instance` means a missing retain. Turn `DEBUG_MEMORY` back off before committing.

- [ ] **Step 6: Commit**

```bash
git add cotvnc/Source/AuthPrompt.m cotvnc/Source/PrefController_private.m \
        cotvnc/Source/ServerDataViewController.m cotvnc/Source/Session.m
git commit -m "replace deprecated +loadNibNamed:owner: with the instance method

The replacement returns top-level objects autoreleased, so each site now
retains what it keeps and releases it in -dealloc."
```

---

## Task 18: `NSFilenamesPboardType` → `NSPasteboardTypeFileURL`

Deprecated in 10.14. Two sites: `RFBConnection.m:700` and `Session.m:85`. The old type carries an array of path strings; the replacement carries one file-URL item per file, so the read side changes shape.

**Files:**
- Modify: `cotvnc/Source/RFBConnection.m:700`
- Modify: `cotvnc/Source/Session.m:85`

- [ ] **Step 1: Read both sites**

Run:
```bash
cd cotvnc && sed -n '695,715p' Source/RFBConnection.m && echo "--- session ---" && sed -n '82,90p' Source/Session.m
```
`Session.m:85` is a `registerForDraggedTypes:` call; `RFBConnection.m:700` reads the dropped data. They must change together.

- [ ] **Step 2: Update the registration in `Session.m:85`**

Change the registered type from `NSFilenamesPboardType` to `NSPasteboardTypeFileURL`, keeping any other registered types in the array.

- [ ] **Step 3: Update the read in `RFBConnection.m:700`**

The old shape:
```objc
    NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
```
The replacement reads URL objects instead:
```objc
    NSArray *urls = [pboard readObjectsForClasses:@[[NSURL class]]
                                          options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
```
Then convert to paths where the existing code expects them: `[[url path] ...]` per element. Read the rest of the method to see what it does with the file list and adapt the loop body — do not assume; the drop handler may send filenames to the server as text.

- [ ] **Step 4: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 2.

- [ ] **Step 5: Smoke-test file drop**

Connect to a server. Drag a file from Finder onto the session window. The behavior must match what it did before the change — check `git show HEAD:cotvnc/Source/RFBConnection.m | sed -n '690,720p'` if you are unsure what it was supposed to do. Test with one file and with several selected at once.

- [ ] **Step 6: Commit**

```bash
git add cotvnc/Source/RFBConnection.m cotvnc/Source/Session.m
git commit -m "replace NSFilenamesPboardType with NSPasteboardTypeFileURL"
```

---

## Task 19: `-convertScreenToBase:` → `-convertPointFromScreen:`

Deprecated in 10.7. Two sites: `EventFilter.m:203` and `EventFilter.m:834`.

**Files:**
- Modify: `cotvnc/Source/EventFilter.m:203`, `:834`

- [ ] **Step 1: Read both sites**

Run:
```bash
cd cotvnc && sed -n '198,208p' Source/EventFilter.m && echo "---" && sed -n '829,839p' Source/EventFilter.m
```

- [ ] **Step 2: Convert both**

`-[NSWindow convertScreenToBase:]` takes an `NSPoint` in screen coordinates and returns window-base coordinates. The direct replacement is `-[NSWindow convertPointFromScreen:]`, available since 10.12 — safely above the 11.0 deployment target.

```objc
	NSPoint windowPoint = [window convertPointFromScreen: screenPoint];
```

Both APIs return window coordinates, so no further adjustment is needed. Remember `RFBView` is unflipped — framebuffer y grows downward while view y grows upward — but that conversion happens elsewhere in the method and is unchanged by this swap. Do not touch it.

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 2.

- [ ] **Step 4: Smoke-test cursor positioning carefully**

A coordinate-conversion error here is subtle — the pointer lands slightly off, or is fine in one window position and wrong in another. Connect to a server and verify:
- Clicking a small target (a window close button on the remote desktop) hits it exactly.
- Move the local window to a different screen position and repeat — the offset must not drift.
- On a multi-monitor setup, move the window to a secondary display (especially one positioned above or to the left of the main display, giving negative screen coordinates) and repeat.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/EventFilter.m
git commit -m "replace deprecated -convertScreenToBase: with -convertPointFromScreen:"
```

---

## Task 20: `NSScrollView` geometry and `NSBox` border deprecations

Five sites: `Session.m:376`, `:386`, `:406` use `+frameSizeForContentSize:hasHorizontalScroller:hasVerticalScroller:borderType:` (deprecated 10.7); `Session.m:439` uses `-constrainScrollPoint:` (deprecated 10.10); `ServerDataViewController.m:50` uses `-setBorderType:` (deprecated 10.15).

**Files:**
- Modify: `cotvnc/Source/Session.m:376`, `:386`, `:406`, `:439`
- Modify: `cotvnc/Source/ServerDataViewController.m:50`

- [ ] **Step 1: Read all five sites**

Run:
```bash
cd cotvnc && sed -n '370,412p' Source/Session.m && echo "--- constrain ---" && sed -n '435,442p' Source/Session.m && echo "--- box ---" && sed -n '45,55p' Source/ServerDataViewController.m
```

- [ ] **Step 2: Replace the three `frameSizeForContentSize:` calls**

The replacement takes scroller classes instead of booleans:
```objc
	NSSize frameSize = [NSScrollView frameSizeForContentSize: contentSize
	                                horizontalScrollerClass: hasHorizontal ? [NSScroller class] : Nil
	                                  verticalScrollerClass: hasVertical ? [NSScroller class] : Nil
	                                             borderType: borderType
	                                            controlSize: NSControlSizeRegular
	                                          scrollerStyle: [NSScroller preferredScrollerStyle]];
```
Note `Nil` (capital N, the `Class` null) rather than `nil` for the no-scroller case. Read each of the three call sites for the actual boolean and border-type arguments in use and substitute them; do not copy the placeholder names above literally.

`[NSScroller preferredScrollerStyle]` reflects the user's "Show scroll bars" setting, which is what the old API used internally.

- [ ] **Step 3: Replace `-constrainScrollPoint:` at `Session.m:439`**

Current:
```objc
    [contentView scrollToPoint: [contentView constrainScrollPoint: NSMakePoint(0.0, _maxSize.height - [scrollView contentSize].height)]];
```
The replacement, `-constrainBoundsRect:`, takes and returns a rect rather than a point:
```objc
    NSRect desiredBounds = [contentView bounds];
    desiredBounds.origin = NSMakePoint(0.0, _maxSize.height - [scrollView contentSize].height);
    [contentView scrollToPoint: [contentView constrainBoundsRect: desiredBounds].origin];
```
This preserves the intent: pin the scroll origin to the bottom-left of the remote desktop, clamped to the legal range.

- [ ] **Step 4: Replace `-setBorderType:` at `ServerDataViewController.m:50`**

Read the current call to see which border type it sets. Per the deprecation note, `borderType` now only applies to the deprecated `NSBoxOldStyle`. If the code sets `NSNoBorder`, the replacement is:
```objc
	[box setTransparent: YES];
```
If it sets any other border type, the modern equivalent is `[box setBoxType: NSBoxPrimary]` (or the type matching the intended look) and deleting the `setBorderType:` call. Check the nib in `Resources/Base.lproj/` — if the box's appearance is already set there, the code call may be redundant and can simply be deleted. Compare the window's appearance before and after.

- [ ] **Step 5: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 5.

- [ ] **Step 6: Smoke-test window sizing and scrolling**

Window geometry bugs are visual, so compare against the previous build side by side if you can.
- Connect to a server whose desktop is **larger** than your screen: the window must size correctly, show scrollers, and start scrolled to the bottom-left.
- Connect to one **smaller** than your screen: no scrollers, no extra padding around the framebuffer.
- Resize the window in both directions and confirm the framebuffer and scrollers track it. This path is where the framebuffer clipping crash (fixed in 56d924e) lived — resize aggressively while connected.
- Toggle System Settings → Appearance → "Show scroll bars" between "Always" and "When scrolling" and confirm the window still sizes correctly.
- Open the connection dialog and confirm the server-details box looks unchanged.

- [ ] **Step 7: Commit**

```bash
git add cotvnc/Source/Session.m cotvnc/Source/ServerDataViewController.m
git commit -m "replace deprecated NSScrollView geometry and NSBox border APIs"
```

---

## Task 21: `NSKeyedArchiver` / `NSKeyedUnarchiver` secure-coding migration

Six sites: `Profile.m:232`, `:238`, `:411`, `:413`; `ServerDataManager.m:154`, `:163`. These read and write the user's saved profiles and server list.

**Compatibility is the whole risk here.** `+archivedDataWithRootObject:` produces an archive that the modern reader can still parse, but `+unarchivedObjectOfClass:fromData:error:` **requires secure coding**, and these classes almost certainly do not implement `NSSecureCoding`. Using it directly would fail to read every existing user's saved data. Use the instance-based API with `requiresSecureCoding = NO` instead, which reads existing archives unchanged.

**Files:**
- Modify: `cotvnc/Source/Profile.m:232`, `:238`, `:411`, `:413`
- Modify: `cotvnc/Source/ServerDataManager.m:154`, `:163`

- [ ] **Step 1: Back up real user data before touching anything**

```bash
defaults read com.geekspiff.chickenofthevnc > ~/chicken-prefs-backup-$(date +%Y%m%d).plist
ls -la ~/Library/Preferences/ | grep -i chicken
```
Confirm the bundle identifier from `Resources/Info.plist` first. If you have saved servers and profiles, this backup is how you recover from a mistake.

- [ ] **Step 2: Check whether the archived classes adopt `NSSecureCoding`**

```bash
cd cotvnc && grep -n "NSCoding\|NSSecureCoding\|supportsSecureCoding" Source/*.h Source/*.m
```
Expected: `NSCoding` only. That confirms the instance-based approach below is required.

- [ ] **Step 3: Replace the writes**

`Profile.m:411` and `:413`:
```objc
	NSData *data = [NSKeyedArchiver archivedDataWithRootObject: object];
```
becomes:
```objc
	NSError *archiveError = nil;
	NSData *data = [NSKeyedArchiver archivedDataWithRootObject: object
	                                    requiringSecureCoding: NO
	                                                    error: &archiveError];
	if (data == nil)
		NSLog(@"Failed to archive profile data: %@", archiveError);
```
`requiringSecureCoding: NO` produces an archive byte-compatible with what the old API wrote, so older builds can still read it.

- [ ] **Step 4: Replace the reads**

`Profile.m:232`, `:238` and `ServerDataManager.m:154`:
```objc
	id object = [NSKeyedUnarchiver unarchiveObjectWithData: data];
```
becomes:
```objc
	NSError *unarchiveError = nil;
	NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData: data
	                                                                            error: &unarchiveError];
	if (unarchiver == nil) {
		NSLog(@"Failed to open archive: %@", unarchiveError);
		return nil;
	}
	[unarchiver setRequiresSecureCoding: NO];
	id object = [unarchiver decodeTopLevelObjectForKey: NSKeyedArchiveRootObjectKey
	                                             error: &unarchiveError];
	[unarchiver finishDecoding];
	[unarchiver release];
	if (object == nil)
		NSLog(@"Failed to decode archived object: %@", unarchiveError);
```
Note the `[unarchiver release]` — no ARC. Adapt the `return nil` to each site's control flow; some of these are inside methods that return `void` or a different type.

- [ ] **Step 5: Replace the file read at `ServerDataManager.m:163`**

`+unarchiveObjectWithFile:` has no direct modern equivalent. Read the file first, then use the same unarchiver code as Step 4:
```objc
	NSError *readError = nil;
	NSData *fileData = [NSData dataWithContentsOfFile: path
	                                          options: 0
	                                            error: &readError];
	if (fileData == nil) {
		NSLog(@"Failed to read server data from %@: %@", path, readError);
		return nil;
	}
```
Then unarchive `fileData` exactly as in Step 4.

- [ ] **Step 6: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 6.

- [ ] **Step 7: Smoke-test round-tripping against *existing* data**

This is the test that matters, and it must run against data written by the **old** code:
- Launch the app **without** clearing preferences. Every saved server and profile from before this change must still appear, with all settings intact. If the list is empty, the read path is broken — revert and restore from the Step 1 backup.
- Now edit a profile and a server, quit, relaunch: the edits must persist.
- Finally, check backward compatibility: `git stash` the change, rebuild the old binary, and confirm it can still read the data the new code wrote. (`requiringSecureCoding: NO` should guarantee this, but verify rather than assume — this is user data.)

- [ ] **Step 8: Commit**

```bash
git add cotvnc/Source/Profile.m cotvnc/Source/ServerDataManager.m
git commit -m "migrate off deprecated NSKeyedArchiver convenience methods

Uses requiresSecureCoding = NO so existing saved profiles and servers
still load and archives stay readable by older builds."
```

---

## Task 22: `-controlTextDidChange:` deprecated-implementation warnings

Two sites: `ProfileManager.m:218` and `ServerDataViewController.m:325`. Both implement `-controlTextDidChange:`, which the compiler flags because the declaration they match is the deprecated informal-protocol version on `NSObject`, not the `NSControlTextEditingDelegate` protocol method.

**Files:**
- Modify: `cotvnc/Source/ProfileManager.h`, `cotvnc/Source/ServerDataViewController.h` (class declarations)

- [ ] **Step 1: Check what the classes currently declare**

Run:
```bash
cd cotvnc && grep -n "@interface" Source/ProfileManager.h Source/ServerDataViewController.h
```

- [ ] **Step 2: Adopt `NSControlTextEditingDelegate` explicitly**

Add the protocol to each class's `@interface` line. For example:
```objc
@interface ProfileManager : NSObject <NSControlTextEditingDelegate>
```
Preserve any protocols already listed, adding this one to the list. Once the class formally adopts the protocol, the implementation matches the non-deprecated protocol declaration and the warning goes away — no change to the method body.

If either class also acts as an `NSTableView` delegate/data source or a window delegate without declaring it, add those protocols at the same time; it costs nothing and improves type-checking. Check first:
```bash
cd cotvnc && grep -n "tableView:\|windowShould\|windowWill\|windowDid" Source/ProfileManager.m Source/ServerDataViewController.m | head
```

- [ ] **Step 3: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 2; `-Wdeprecated-implementations` reaches 0. Adding protocol conformance can surface new warnings if a required protocol method is missing — if the count does not drop by exactly 2, read the new warnings and resolve them here.

- [ ] **Step 4: Smoke-test live text validation**

`-controlTextDidChange:` drives live enabling of buttons as the user types. Open the Profile Manager and type in the profile name field — whatever button state it controls (`_updateBrowserButtons`) must still update on each keystroke. Same in the connection dialog's host field.

- [ ] **Step 5: Commit**

```bash
git add cotvnc/Source/ProfileManager.h cotvnc/Source/ServerDataViewController.h
git commit -m "adopt NSControlTextEditingDelegate explicitly"
```

---

# Phase 4 — Control-flow and user-data migrations

These change how code is structured, not just which API it calls. Each is independently reviewable; each can be skipped without blocking the others.

## Task 23: `ConnectionWaiter` alert migration

`ConnectionWaiter.m:300` uses `NSBeginAlertSheet` and `:305` uses `NSRunAlertPanel`, both deprecated in 10.10. Both funnel into `-errorDidEnd:returnCode:contextInfo:`, which ignores its arguments entirely and just calls `[delegate connectionFailed]` — which makes this the simplest of the alert migrations and the right one to do first.

**Files:**
- Modify: `cotvnc/Source/ConnectionWaiter.m:290-315`

- [ ] **Step 1: Read the whole error-reporting method and its callback**

Run:
```bash
cd cotvnc && sed -n '280,320p' Source/ConnectionWaiter.m && echo "--- callers ---" && grep -rn "errorDidEnd" Source/
```

- [ ] **Step 2: Replace both branches with a single `NSAlert`**

Current:
```objc
	NSString *ok = NSLocalizedString( @"Okay", nil );
    if (window)
        NSBeginAlertSheet(theAction, ok, nil, nil, window, self,
                @selector(errorDidEnd:returnCode:contextInfo:), NULL, NULL,
                @"%@", message);
    else {
        int ret;
        ret = NSRunAlertPanel(theAction, message, ok, NULL, NULL, NULL);
        [self errorDidEnd:nil returnCode:ret contextInfo:nil];
    }
```

Replacement:
```objc
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText: theAction];
    [alert setInformativeText: message];
    [alert addButtonWithTitle: NSLocalizedString( @"Okay", nil )];

    if (window) {
        [alert beginSheetModalForWindow: window
                      completionHandler: ^(NSModalResponse returnCode) {
            [delegate connectionFailed];
        }];
    } else {
        [alert runModal];
        [delegate connectionFailed];
    }
```

Two things to check before writing this:
- **`delegate` capture.** The block captures `delegate` (an ivar), which under manual retain/release implicitly captures `self`. The sheet completion handler runs later, so `self` must still be alive. If `ConnectionWaiter` can be released between showing the sheet and the user dismissing it, capture and retain explicitly:
  ```objc
  [self retain];
  [alert beginSheetModalForWindow: window
                completionHandler: ^(NSModalResponse returnCode) {
      [delegate connectionFailed];
      [self release];
  }];
  ```
  Read the object's lifecycle (`grep -n "ConnectionWaiter" Source/*.m`) and decide. When in doubt, retain — a leak is better than a use-after-free.
- **`-Wblock-capture-autoreleasing` is enabled** in this project. If the block captures an autoreleasing out-parameter you will get a new warning; there is none here, but check the count in Step 3.

- [ ] **Step 3: Delete the now-unused callback**

Once nothing references `-errorDidEnd:returnCode:contextInfo:`, delete the method. Re-run the grep from Step 1 to confirm it has no other callers — if `ConnectionWaiter.h` declares it, remove the declaration too.

- [ ] **Step 4: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 2 (the `NSRunAlertPanel` `-Wshorten-64-to-32` at `:305` was already resolved in Task 13; if Task 13 was skipped, this drops 3).

- [ ] **Step 5: Smoke-test both branches**

Both paths must be exercised — they are different code:
- **With a window:** start a connection from an open session window, to a host that will fail (`vnc://127.0.0.1:1` or an unroutable address). The error must appear as a sheet attached to the window, and dismissing it must return you to the connection dialog.
- **Without a window:** trigger a failure from the command line, where no window exists yet:
  ```bash
  cd cotvnc && ./build/Development/Chicken.app/Contents/MacOS/Chicken --Host 127.0.0.1 --Port 1
  ```
  The error must appear as a standalone modal panel, and dismissing it must not hang or crash.

Run both with zombies on (`DEBUG_MEMORY` in `VNCViewer_main.m`) to catch a block-capture lifetime bug.

- [ ] **Step 6: Commit**

```bash
git add cotvnc/Source/ConnectionWaiter.m cotvnc/Source/ConnectionWaiter.h
git commit -m "migrate ConnectionWaiter error reporting to NSAlert"
```

---

## Task 24: `Session` alert and reconnect-sheet migration

The largest control-flow change in this plan. `Session.m` uses `NSBeginAlertSheet` at `:226` and `:248`, checks `NSAlertDefaultReturn`/`NSAlertAlternateReturn` at `:183`/`:185`, and uses `-[NSApp beginSheet:modalForWindow:...]` at `:289` and `:705`. The callback `-connectionTerminatedSheetDidEnd:returnCode:contextInfo:` decides whether to reconnect, so getting the response codes wrong silently breaks reconnection.

**The response constants change meaning.** `NSAlertDefaultReturn` (1) and `NSAlertAlternateReturn` (0) map to `NSAlertFirstButtonReturn` (1000) and `NSAlertSecondButtonReturn` (1001). A partial migration that mixes the two families produces a sheet that appears to work but takes the wrong branch.

**Files:**
- Modify: `cotvnc/Source/Session.m:178-195`, `:220-255`, `:283-295`, `:700-712`
- Modify: `cotvnc/Source/Session.h` (remove callback declarations that become unused)

- [ ] **Step 1: Map every sheet and its callback before changing anything**

Run:
```bash
cd cotvnc && grep -n "NSBeginAlertSheet\|beginSheet:\|endSheet\|SheetDidEnd\|DidEnd:\|NSAlertDefaultReturn\|NSAlertAlternateReturn\|returnCode" Source/Session.m Source/Session.h
```
Write down, for each sheet: which method shows it, which callback it names, what each button does, and who calls `-[NSApp endSheet:]` on it. `Session.m:226` in particular is shown right after `[NSApp endSheet:passwordSheet]` — an interrupting sheet — which is the fiddliest interaction in this file.

- [ ] **Step 2: Migrate the connection-terminated alert at `:248` first (the simplest)**

Current:
```objc
				NSString *header = NSLocalizedString( @"ConnectionTerminated", nil );
				NSString *okayButton = NSLocalizedString( @"Okay", nil );
				NSString *reconnectButton =  NSLocalizedString( @"Reconnect", nil );
				NSBeginAlertSheet(header, okayButton, supportReconnect ? reconnectButton : nil, nil, window, self, @selector(connectionTerminatedSheetDidEnd:returnCode:contextInfo:), nil, nil, @"%@", aReason);
```

Replacement:
```objc
				NSAlert *alert = [[[NSAlert alloc] init] autorelease];
				[alert setMessageText: NSLocalizedString( @"ConnectionTerminated", nil )];
				[alert setInformativeText: aReason];
				[alert addButtonWithTitle: NSLocalizedString( @"Okay", nil )];
				if (supportReconnect)
					[alert addButtonWithTitle: NSLocalizedString( @"Reconnect", nil )];

				[self retain];
				[alert beginSheetModalForWindow: window
				              completionHandler: ^(NSModalResponse returnCode) {
					if (returnCode == NSAlertSecondButtonReturn)
						[self beginReconnect];
					[self release];
				}];
```

Note the button order is preserved: first button = Okay = dismiss, second button = Reconnect. The old code's `NSAlertDefaultReturn` was the first button (Okay, do nothing) and `NSAlertAlternateReturn` the second (Reconnect) — confirm that against `-connectionTerminatedSheetDidEnd:` at `Session.m:180-190` before you rely on it, because getting it backwards means the app reconnects when the user asked it not to.

The `[self retain]`/`[self release]` pair matters: the session can be torn down while the sheet is up (that is exactly what "connection terminated" means).

- [ ] **Step 3: Migrate the interrupting alert at `:226`**

This one fires while the password sheet is up and calls `[NSApp endSheet:passwordSheet]` first. Apply the same `NSAlert` conversion, but sequence it carefully: the new sheet can only be presented after the password sheet has finished dismissing. If `-beginSheetModalForWindow:completionHandler:` is called synchronously after `endSheet:`, AppKit may drop it. Present the alert from the password sheet's own completion handler, or via `dispatch_async(dispatch_get_main_queue(), ^{ ... })`, and verify the sheet actually appears in Step 6.

- [ ] **Step 4: Migrate the two `-[NSApp beginSheet:modalForWindow:...]` calls**

`Session.m:289` (`-displayPasswordSheet`) and `Session.m:705` (`-createReconnectSheet:`) present nib-loaded panels, not alerts, so the replacement is `-[NSWindow beginSheet:completionHandler:]`:
```objc
    [window beginSheet: passwordSheet completionHandler: ^(NSModalResponse returnCode) {
        /* body of -passwordEnteredFor:returnCode:contextInfo: goes here */
    }];
```
The matching `[NSApp endSheet:passwordSheet]` calls elsewhere in the file must become `[window endSheet: passwordSheet]`, or the completion handler never runs. Find them all:
```bash
cd cotvnc && grep -n "endSheet" Source/*.m
```
`AuthPrompt.m` and `RFBConnection.m` may also call `endSheet:` on sheets that `Session` owns — check before assuming the change is local to one file.

- [ ] **Step 5: Delete the now-unused `didEndSelector` callbacks**

Once each sheet's logic lives in its completion handler, delete `-connectionTerminatedSheetDidEnd:returnCode:contextInfo:`, `-passwordEnteredFor:returnCode:contextInfo:` and `-reconnectEnded:returnCode:contextInfo:` — but only after confirming nothing else calls them:
```bash
cd cotvnc && grep -rn "connectionTerminatedSheetDidEnd\|passwordEnteredFor\|reconnectEnded" Source/
```
Remove the matching declarations from `Session.h`. Note `AuthPrompt.m` has its **own** `-passwordEnteredFor:returnCode:contextInfo:` — do not delete that one; it belongs to Task 25.

- [ ] **Step 6: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 6 (`:183`, `:185`, `:226`, `:248`, `:289`, `:705`).

- [ ] **Step 7: Smoke-test every path, with zombies on**

Enable `DEBUG_MEMORY` in `VNCViewer_main.m` and rebuild. Then exercise all five flows — each one is a branch you just rewrote:
1. **Password sheet:** connect to a password-protected server. Enter the correct password → connects. Enter a wrong one → the sheet reappears or errors appropriately.
2. **"Remember password":** check the box, verify the password is stored (Task 16's keychain check).
3. **Connection terminated, reconnect supported:** connect, then kill the server. The sheet must offer both Okay and Reconnect. Click **Reconnect** → it reconnects. Repeat and click **Okay** → the window closes without reconnecting. **Verify both branches** — this is where a swapped button index hides.
4. **Connection terminated, reconnect not supported:** same, against a server where `[server_ doYouSupport:CONNECT]` is false. Only Okay appears.
5. **Terminated while the password sheet is up:** connect to a password-protected server, and kill the server while the password prompt is showing. The password sheet must dismiss and the termination alert must actually appear — this is the Step 3 sequencing hazard.
6. **Reconnect panel:** trigger an automatic reconnect (kill the server after the reconnect interval elapses) and confirm the progress panel appears, animates, and dismisses.

- [ ] **Step 8: Commit**

```bash
git add cotvnc/Source/Session.m cotvnc/Source/Session.h
git commit -m "migrate Session sheets to completion-handler APIs

Response codes move from NSAlertDefaultReturn/AlternateReturn to
NSAlertFirstButtonReturn/SecondButtonReturn; verified both reconnect
branches take the correct action."
```

---

## Task 25: `AuthPrompt`, `SshWaiter` and `RFBConnection` sheet migration

The remaining sheet deprecations: `AuthPrompt.m:35` (`-[NSApp beginSheet:modalForWindow:...]`), `SshWaiter.m:102` (`-[NSAlert beginSheetModalForWindow:modalDelegate:...]`), and `RFBConnection.m:912` (`NSAlertDefaultReturn` in `-pasteConfirmation:returnCode:contextInfo:`).

**Files:**
- Modify: `cotvnc/Source/AuthPrompt.m:33-60`
- Modify: `cotvnc/Source/SshWaiter.m:95-115`
- Modify: `cotvnc/Source/RFBConnection.m:905-920` and the alert that invokes that callback

- [ ] **Step 1: Read all three, plus the alert that feeds `RFBConnection.m:912`**

Run:
```bash
cd cotvnc && sed -n '30,65p' Source/AuthPrompt.m && \
  echo "--- ssh ---" && sed -n '90,120p' Source/SshWaiter.m && \
  echo "--- paste ---" && sed -n '875,925p' Source/RFBConnection.m && \
  grep -n "pasteConfirmation\|PasteConversion" Source/RFBConnection.m
```
`RFBConnection.m:912` reads a `returnCode` but the alert that produces it is above line 890, inside an `#if`-guarded block — find it before editing the callback.

- [ ] **Step 2: Migrate `AuthPrompt`**

`AuthPrompt` retains itself in `-runSheetOnWindow:` (`[self retain]` at line 39) and releases in its `didEndSelector`. Replace:
```objc
- (void)runSheetOnWindow:(NSWindow *)window
{
    [NSApp beginSheet:panel modalForWindow:window modalDelegate:self
        didEndSelector:@selector(passwordEnteredFor:returnCode:contextInfo:)
        contextInfo:nil];
    [self retain];
}
```
with:
```objc
- (void)runSheetOnWindow:(NSWindow *)window
{
    [self retain];
    [window beginSheet:panel completionHandler:^(NSModalResponse returnCode) {
        /* body of -passwordEnteredFor:returnCode:contextInfo: */
        [self release];
    }];
}
```
`-stopSheet`, `-enterPassword:` and `-cancel:` all call `[NSApp endSheet:panel]`; change each to `[[panel sheetParent] endSheet:panel]`. `-sheetParent` returns the window the sheet is attached to; if it is `nil` (the sheet was never presented) the call is a safe no-op. Then delete `-passwordEnteredFor:returnCode:contextInfo:` and its declaration in `AuthPrompt.h`.

Read the existing callback body before moving it — the `[self release]` placement must match what the old code did, or `AuthPrompt` leaks or double-frees.

- [ ] **Step 3: Migrate `SshWaiter`**

`SshWaiter.m:102` uses the `NSAlert` variant. Replace:
```objc
    [alert beginSheetModalForWindow:window modalDelegate:self
                     didEndSelector:@selector(firstTime:returnCode:contextInfo:)
                        contextInfo:NULL];
```
with:
```objc
    [self retain];
    [alert beginSheetModalForWindow:window
                  completionHandler:^(NSModalResponse returnCode) {
        /* body of -firstTime:returnCode:contextInfo: */
        [self release];
    }];
```
The existing `-firstTime:returnCode:contextInfo:` already tests `retCode == NSAlertFirstButtonReturn`, so the response constants need no change — the alert was already built with `addButtonWithTitle:`. Move the body in and delete the callback.

- [ ] **Step 4: Migrate the paste-confirmation alert in `RFBConnection`**

`-pasteConfirmation:returnCode:contextInfo:` tests `code == NSAlertDefaultReturn` and releases a retained `NSString` context. Convert the presenting alert to `NSAlert` with `-beginSheetModalForWindow:completionHandler:`, change the test to `NSAlertFirstButtonReturn`, and capture the string in the block instead of passing it through `contextInfo` — which also removes the manual `[str release]`:
```objc
    NSString *pasteString = [theString retain];
    [alert beginSheetModalForWindow: window
                  completionHandler: ^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            NSData *data = [pasteString dataUsingEncoding: NSISOLatin1StringEncoding
                                     allowLossyConversion: YES];
            [self sendStringToServersClipboard: [data bytes] length: (unsigned)[data length]];
        }
        [pasteString release];
    }];
```
Keep whatever `#if` guard surrounds the current code. If Task 15 added a length guard to `-sendStringToServersClipboard:length:` callers, apply it here too.

- [ ] **Step 5: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 3. `-Wdeprecated-declarations` should now be down to just the `KeyChain.m` entries.

- [ ] **Step 6: Smoke-test all three, with zombies on**

1. **SSH first-connect:** connect to a server through an SSH tunnel you have never connected to before (clear the relevant `known_hosts` entry first). The fingerprint sheet must appear; test **both** Connect and Cancel.
2. **SSH password prompt:** connect through a tunnel that requires a password. The `AuthPrompt` sheet must appear; test entering a password, and test Cancel.
3. **Paste conversion:** copy text containing characters outside ISO Latin-1 (e.g. `日本語` or an emoji) and paste into the remote desktop. The confirmation sheet must appear; test **both** buttons and confirm the correct one sends the lossy-converted text.

- [ ] **Step 7: Commit**

```bash
git add cotvnc/Source/AuthPrompt.m cotvnc/Source/AuthPrompt.h \
        cotvnc/Source/SshWaiter.m cotvnc/Source/RFBConnection.m
git commit -m "migrate remaining sheets to completion-handler APIs"
```

---

## Task 26: `SecKeychain` → `SecItem` migration

The last six deprecation warnings, all in `KeyChain.m`: `SecKeychainItemModifyContent` (`:47`), `SecKeychainAddGenericPassword` (`:51`), `SecKeychainFindGenericPassword` (`:73`, `:105`), `SecKeychainItemFreeContent` (`:82`), `SecKeychainItemDelete` (`:92`). The entire `SecKeychain` family is deprecated in favour of `SecItem*`.

**This touches saved passwords.** A mistake means users lose stored credentials or the app stops finding them. The saving grace: generic passwords written by `SecKeychainAddGenericPassword` are the *same keychain items* that `SecItemCopyMatching` finds with `kSecClassGenericPassword`, provided the service and account attributes match exactly. Existing items remain readable — but only if the attribute mapping is right.

Do this task last, and consider doing it in a worktree so you can abandon it without disturbing the rest of the cleanup.

**Files:**
- Modify: `cotvnc/Source/KeyChain.m` (entire file)

- [ ] **Step 1: Back up the keychain and record what is there**

```bash
security dump-keychain | grep -A5 -i chicken | head -40
cp ~/Library/Keychains/login.keychain-db ~/login.keychain-db.backup-$(date +%Y%m%d)
```
Note the exact `svce` (service) and `acct` (account) attribute values the current code writes. The migration must produce byte-identical values or existing items become invisible.

- [ ] **Step 2: Read the whole file and note each function's contract**

```bash
cd cotvnc && cat -n Source/KeyChain.m && echo "--- header ---" && cat -n Source/KeyChain.h
```
There are four operations: store (add or update), retrieve, delete, and free. Write down each one's parameters and return values — the public interface in `KeyChain.h` must not change, only the implementation.

- [ ] **Step 3: Rewrite retrieval**

`SecKeychainFindGenericPassword` becomes `SecItemCopyMatching`:
```objc
	NSDictionary *query = @{
		(__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService:      service,
		(__bridge id)kSecAttrAccount:      account,
		(__bridge id)kSecReturnData:       @YES,
		(__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitOne,
	};

	CFDataRef passwordData = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query,
	                                      (CFTypeRef *)&passwordData);
	if (status != errSecSuccess)
		return nil;

	NSString *password = [[[NSString alloc] initWithData: (__bridge NSData *)passwordData
	                                            encoding: NSUTF8StringEncoding] autorelease];
	CFRelease(passwordData);
	return password;
```

`__bridge` casts are ARC syntax but are accepted and are no-ops under manual retain/release; if the compiler objects, drop them and use plain `(id)` casts. Note `SecItemCopyMatching` returns a **retained** `CFDataRef` — the `CFRelease` is required, and replaces the old `SecKeychainItemFreeContent` call at `:82`.

Check what encoding the old code used to build the `NSString` from the raw bytes. If it used `NSUTF8StringEncoding`, match it; if it used something else, match that instead — changing it silently corrupts non-ASCII passwords.

- [ ] **Step 4: Rewrite store (add-or-update)**

The old code tried `SecKeychainItemModifyContent` and fell back to `SecKeychainAddGenericPassword`. The `SecItem` equivalent is `SecItemUpdate` falling back to `SecItemAdd`:
```objc
	NSDictionary *query = @{
		(__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService: service,
		(__bridge id)kSecAttrAccount: account,
	};
	NSDictionary *attributesToUpdate = @{
		(__bridge id)kSecValueData: [password dataUsingEncoding: NSUTF8StringEncoding],
	};

	OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
	                                (__bridge CFDictionaryRef)attributesToUpdate);
	if (status == errSecItemNotFound) {
		NSMutableDictionary *newItem = [[query mutableCopy] autorelease];
		[newItem addEntriesFromDictionary: attributesToUpdate];
		status = SecItemAdd((__bridge CFDictionaryRef)newItem, NULL);
	}
	if (status != errSecSuccess)
		NSLog(@"Failed to store keychain password: %d", (int)status);
```

- [ ] **Step 5: Rewrite delete**

`SecKeychainItemDelete` becomes `SecItemDelete` with the same query dictionary as Step 3 (minus the return/limit keys):
```objc
	OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
	if (status != errSecSuccess && status != errSecItemNotFound)
		NSLog(@"Failed to delete keychain password: %d", (int)status);
```
Treating `errSecItemNotFound` as success matches the old behavior of deleting something that may not exist.

- [ ] **Step 6: Build and verify**

Run:
```bash
cd cotvnc && ./Tests/count_warnings.sh <baseline>
```
Expected: total drops by 6, and **`-Wdeprecated-declarations` reaches 0**. Combined with all earlier tasks, the `TOTAL:` line should now read **0**.

- [ ] **Step 7: Smoke-test against passwords saved by the OLD code**

This is the whole risk of the task. The keychain items in your login keychain right now were written by `SecKeychainAddGenericPassword`; the new code must find them.

1. **Before rebuilding**, use the current release build to save a password for a test server with "remember password" checked. Confirm it appears in Keychain Access.app.
2. **Now build with the migration** and launch. Connect to that same server. The password must be filled in automatically. **If it is not, the attribute mapping is wrong** — compare the `svce`/`acct` values in `security dump-keychain` against what your query dictionary sends. Do not proceed until it reads existing items.
3. Save a password for a *new* server with the new code. Quit, relaunch, confirm it is found.
4. Uncheck "remember password" and confirm the item disappears from Keychain Access.
5. Change an existing saved password and confirm the update path (not a duplicate item) — Keychain Access must show one item, not two.
6. Test a password with non-ASCII characters to confirm the encoding round-trips.

- [ ] **Step 8: Commit**

```bash
git add cotvnc/Source/KeyChain.m
git commit -m "migrate KeyChain from deprecated SecKeychain to SecItem API

Generic-password items written by the old API are found unchanged by the
new queries; verified against passwords saved by the previous build."
```

---

## Final verification

- [ ] **Step 1: Full clean build from a clean tree**

```bash
cd cotvnc && ./Tests/count_warnings.sh 0
```
Expected: `TOTAL: 0 unique warning sites` and exit 0. If the count is not zero, the remaining sites are listed under `=== Sites ===` — each belongs to a task above.

- [ ] **Step 2: Confirm the analyzer is clean**

```bash
cd cotvnc && xcodebuild clean build analyze -scheme Chicken \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" 2>&1 | tail -20
```
Expected: `** ANALYZE SUCCEEDED **` with **no** trailing "The following commands produced analyzer issues:" block. At baseline that block listed `vncauth.c`, `PrefController.m` and `KeyEquivalentScenario.m`.

- [ ] **Step 3: Run the standalone tests**

```bash
cd cotvnc && ./Tests/run_tests.sh
```
Expected: `all tests passed`. Nothing in this plan touches `FrameBufferClip.h`, so a failure here means something unexpected happened.

- [ ] **Step 4: Verify the Deployment configuration also builds clean**

CI and `count_warnings.sh` both use the Development configuration. Confirm the release path is clean too:
```bash
cd cotvnc && xcodebuild clean build -scheme Chicken -configuration Deployment \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" 2>&1 | grep -cE "warning:"
```
Expected: `0`. Optimization settings differ between configurations, so Deployment can surface warnings Development does not.

- [ ] **Step 5: Full manual regression pass**

Connect to a real VNC server and exercise, in one session: authentication, all nine encodings, window resize, clipboard both directions, file drop, every modifier key, mouse-button emulation, saved-password recall, server list persistence, profile editing, reconnect after the server dies, and SSH tunnelling. Every one of these was touched by some task in this plan.

- [ ] **Step 6: Note the unrelated version discrepancy**

`CLAUDE.md` records that `Resources/Info.plist` says 2026.7 while the `_CHICKEN_VERSION_` build setting says 2026.6. That is **out of scope** for this plan — it is not a warning and no task touches it. Raise it separately rather than folding a version bump into a warning-cleanup branch.

---

## Summary of expected warning reduction

Counts are **unique sites**, matching the `TOTAL:` line from `count_warnings.sh`.

| Phase | Tasks | Sites resolved | Cumulative remaining |
|---|---|---|---|
| Baseline | — | — | **117** |
| Phase 1 — real defects | 1–10 | 17 (13 compiler + 4 analyzer) | 100 |
| Phase 2 — mechanical | 11–16 | 62 | 38 |
| Phase 3 — drop-in deprecations | 17–22 | 21 | 17 |
| Phase 4 — migrations | 23–26 | 17 | **0** |

Per-task expected reductions:

| Task | Sites | Task | Sites |
|---|---|---|---|
| 1 `--FullScreen` crash | 1 | 14 `EventFilter` casts | 8 |
| 2 `DockConnection` import | 3 | 15 wire-length casts | 10 |
| 3 `Session.h` declarations | 3 | 16 `KeyChain` casts | 8 |
| 4 duplicate declaration | 1 (12 lines) | 17 nib loading | 4 |
| 5 `vncauth.c` leaks | 2 | 18 pasteboard type | 2 |
| 6 `-initFromMainMenu` | 1 | 19 screen conversion | 2 |
| 7 dead store | 1 | 20 scroll/box geometry | 5 |
| 8 `NSClipView` cast | 1 | 21 archiver | 6 |
| 9 parameter types | 3 | 22 text-editing delegate | 2 |
| 10 table drag-and-drop | 1 | 23 `ConnectionWaiter` alerts | 2 |
| 11 `d3des.c` prototypes | 8 | 24 `Session` sheets | 6 |
| 12 unused variable | 1 | 25 remaining sheets | 3 |
| 13 UI casts | 27 | 26 `SecItem` migration | 6 |

Phase 1 resolves 13 compiler sites plus all 4 analyzer findings. Task 4 removes 12 warning *lines* but only 1 site, which is why the raw line count (128) falls faster than the site count (117).
