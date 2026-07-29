# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ForkOfTheChickenOfTheVNC (FotCotVNC) — a native macOS VNC client forked from Chicken of the VNC. Objective-C against Cocoa, **no ARC** (manual `retain`/`release`/`autorelease`; match the surrounding memory-management style). Everything lives under `cotvnc/`; the repo root holds only README and license.

## Commands

All commands run from `cotvnc/`.

```bash
./build_release.sh                                   # xcodebuild -configuration Deployment (also builds a .dmg)
xcodebuild -scheme Chicken -configuration Development build
xcodebuild clean build analyze -scheme Chicken       # what CI runs
./Tests/run_tests.sh                                 # all standalone tests
```

Build configurations: `Development`, `Deployment`, `Universal Fast Development`, `Default`. Deployment target is macOS 11.0 and `ONLY_ACTIVE_ARCH = NO`, so every configuration produces a universal (arm64 + x86_64) binary.

Where products land depends on how you invoke xcodebuild. Target-based builds (`build_release.sh`, no `-scheme`) write to `cotvnc/build/<Configuration>/Chicken.app`, a symlink into `build/UninstalledProducts/macosx/`. Passing `-scheme Chicken` instead writes to DerivedData. `xcodebuild clean` follows the same split, so clean the same way you build or the stale tree survives.

The Deployment build has a shell build phase that packages `Chicken_${_CHICKEN_VERSION_}.dmg` next to the products.

The project is set to sign with an "Apple Development" identity under team 4X5WA3953A. Without that certificate the build fails at `GatherProvisioningInputs`; append `CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""` to sign ad hoc and run locally.

### Tests

There is no Xcode test target. `Tests/run_tests.sh` compiles each `Tests/test_*.m` as a standalone Foundation program with `-Wall -Werror -ISource` and runs it; a non-zero exit means failure. To run one test directly:

```bash
clang -Wall -Werror -framework Foundation -ISource Tests/test_fbclip.m -o /tmp/t && /tmp/t
```

Because tests link only Foundation, they can cover only logic reachable without the app — in practice the header-only inline functions (`FrameBufferClip.h`). Pulling logic into such a header is the established way to make it testable.

## Architecture

### Reader chain — the protocol state machine

`RFBConnection` owns the socket (`NSFileHandle`) and a single `currentReader`. Incoming bytes go to `-[ByteReader readBytes:length:]`, which returns how many it consumed; when a reader has all it needs it fires its target/action. Advancing the protocol means calling `-[RFBConnection setReader:]` with the next reader. Nothing is parsed inline — to add or change a message, add a reader and swap it in.

Layers, in order:

1. `RFBHandshaker` — version, auth-type negotiation, VNC challenge (`vncauth.c`, `d3des.c`), `RFBServerInitReader`.
2. `RFBProtocol` — reads a message-type byte, then dispatches through `msgTypeReader[]`, indexed by RFB message type (`FrameBufferUpdateReader`, `SetColorMapEntriesReader`, `ServerCutTextReader`; `rfbBell` is handled inline).
3. `FrameBufferUpdateReader` — per-rectangle dispatch to one long-lived reader per encoding (`Raw`, `CopyRectangle`, `RRE`, `CoRRE`, `Hextile`, `Tight`, `Zlib`, `ZlibHex`, `ZRLE`) plus pseudo-encodings (`CursorPseudoEncodingReader`, `DesktopNameEncodingReader`).

Primitive readers (`CARD8Reader`, `CARD16Reader`, `CARD32Reader`, `ByteBlockReader`, `RFBStringReader`, `ZlibStreamReader`) compose into the larger ones. `rfbproto.h` holds the wire-format structs.

### Framebuffer and drawing

`FrameBuffer` is abstract; `LowColorFrameBuffer`, `HighColorFrameBuffer`, `TrueColorFrameBuffer`, and `GrayScaleFrameBuffer` each `#define` their pixel type and then `#include "FrameBufferDrawing.h"`. **That header is a template, not a normal header** — one edit to it recompiles into all four subclasses, so changes must hold for every pixel depth.

`FrameBufferClip.h` encodes two hard-won invariants; read its comments before touching drawing or allocation:

- `FrameBufferPixelCapacity(size)` — every subclass must `calloc` this, not `width * height`. `-drawRect:at:` hands `NSDrawBitmap` the full framebuffer stride while pointing at the buffer's interior, and `NSBitmapImageRep` copies `bytesPerRow * pixelsHigh` contiguous bytes, reading the final row's trailing padding. The spare row covers that read.
- `FrameBufferClipRect()` — the view and the framebuffer are sized by different asynchronous sources (the window follows the user; the framebuffer is reallocated only when the server acknowledges a resize), so incoming rects can fall outside the buffer entirely. `Tests/test_fbclip.m` replicates the old crashing logic to prove the bug stays fixed.

### View and input

`Session` owns the window, the `RFBView`, resize and reconnect handling, and the password/options sheets. `RFBView` is unflipped, so framebuffer y grows downward while view y grows upward — mind the conversion. `EventFilter` sits between `RFBView`'s responder events and the server: it queues events, sends them only on a "definitive" event, and uses that queue to emulate multi-button mice and intercept menu key equivalents (its header documents the emulation scenarios). `Keymap` and `KeyEquivalentManager`/`KeyEquivalentScenario` implement per-profile keyboard mapping.

### Servers, profiles, preferences

`IServerData` abstracts a connection target; implementations are `ServerFromPrefs` (saved), `ServerFromRendezvous` (Bonjour), `ServerFromConnection` (incoming listener), and `ServerStandAlone` (command line / URL). `ServerDataManager` is the singleton store, persisting to `NSUserDefaults`; passwords go through `KeyChain`. `Profile`/`ProfileManager`/`ProfileDataManager` hold per-connection settings (encodings, color depth, emulation); `PrefController` drives the preferences UI.

### Entry points

`VNCViewer_main.m` calls `NSApplicationMain`. `MyApp` (an `NSApplication` subclass), `AppDelegate`, and the `RFBConnectionManager` singleton run the connection dialog and own live connections. Alternate entries: `CommandLineConnection`, `URLHandlerCommand` (`vnc://` URLs and the AppleScript suite in `Resources/CotVNC.scriptSuite`), `ListenerController` (reverse connections), `DockConnection`.

`SshTunnel` shells out through `Resources/ssh-helper.sh`; `ConnectionWaiter`/`SshWaiter` perform the connect asynchronously and call back into `Session`.

### Vendored code

`libjpeg-turbo/` ships prebuilt headers and `libturbojpeg.a`, used only by the Tight encoding reader.

## Conventions and gotchas

- UI lives in nibs under `Resources/Base.lproj/`; user-facing strings in `Resources/Localizable.xcstrings`.
- The version appears twice: `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`, and the `_CHICKEN_VERSION_` build setting (used for the .dmg filename) in all four configurations of `Chicken.xcodeproj`. Both currently say 2026.7. Nothing derives one from the other, so bump all five sites together or the .dmg filename and the bundle version drift apart.
- Development happens on `moe`; the GitHub Actions workflow builds and analyzes only that branch and its PRs.
- `debug.h` provides `FULLDebug`, a no-op unless `FULL_DEBUG` is defined; `VNCViewer_main.m` has a `DEBUG_MEMORY` block that enables zombies.
