# PS5 Backport Builder

Turns a game dump and a backport file set into installable PS5 packages:

* a **base package** of the plain game, when you do not already have one, and
* a **backport update package** — a small delta that installs on top of it and
  replaces only the backport files, leaving the rest of the game in place.

Syphon Filter: a 69 MB update against a 2.4 GB game, carrying 7 MB — `eboot.bin`,
`sce_module/libc.prx` and three `fakelib` libraries. Confirmed installing on
firmware 12.00.

## You need

* Windows, PowerShell 5.1, Python 3.
* The plaintext publishing toolkit — the folder with
  `scripts/create-gp5-from-folder.py` and `toolchain/prospero-pub-cmd.exe`. Not
  part of this repo. Found automatically in `Documents\PS5JB\fpkg converter`, or
  set `PS5_FPKG_TOOLKIT` / pass `-ToolkitRoot`.
* The backport files.
* **The base package the console installed** — or a game dump, and the tool builds
  the base for you. See the rule below.

## Run it

```bat
backport-builder.bat
```

Two flows, depending on whether you already have the base package:

```powershell
# you have the base package
.\build-backport.ps1 `
    -BackportFolder   ".\my backport files" `
    -ReferencePackage ".\game.pkg" `
    -OutputPackage    ".\game-backport.pkg"

# you have only a game dump: builds the base, then the update
.\build-backport.ps1 `
    -GameFolder       ".\PPSA12345-app" `
    -BackportFolder   ".\my backport files" `
    -CreateBase `
    -OutputPackage    ".\game-backport.pkg"
```

In the GUI these are the **Build update** and **Build base + update** buttons.
`-CreateBase` builds the base from the **unmodified** game folder — the backport is
overlaid afterwards, into a work tree — so the base is the plain game and the update
carries the backport. It is opt-in: with a base package in hand, nothing large is
built.

| Parameter | |
| --- | --- |
| `-BackportFolder` | The backport files, laid out as they sit in the game root. |
| `-ReferencePackage` | The exact `.pkg` the console installed. Required unless `-CreateBase`. |
| `-OutputPackage` | Where to write the update. |
| `-GameFolder` | The game dump. Required with `-CreateBase`; otherwise optional, and saves unpacking the reference. |
| `-CreateBase` | Build the base package from the game folder first. |
| `-BasePackage` | Where to write it (default: `<output>-base.pkg`). |
| `-ContentVersion` | Optional. Defaults to the base version, bumped. |
| `-CompressionLevel` | `-4`..`9`, default `7`. |
| `-WorkFolder` | Optional scratch location. |
| `-KeepWork` | Keep the work folder. |
| `-Force` | Overwrite the output. |

Install the base package on the console, then the update over it.

## The one rule

**The reference must be the exact package the console installed.**

An update is not a copy of the backport files — it is mostly *block references*
into one specific package image, and the console checks that image's digest
before merging. Point it at a different build of the same game and the install
fails with `CE-107891-6`:

```
[0x80b21165][DigestErr]
   {0CC38CC3…}  ← what the console has
   {4206B0C8…}  ← what the update expects
```

Builds are **not reproducible**: rebuilding "the same" package from the same
folder gives a different digest. So keep the package you installed, and ship the
base and the update together as a pair.

No base package means no update — only a full app package, which *replaces* the
whole game.

## Reading the result

Judge an update by its payload, not its file size — most of a delta is metadata
for the whole title:

```
eboot.bin                      replaced   3,785,778
fakelib/libScePsml.sprx        new        1,524,286
sce_module/libc.prx            replaced   1,285,274
fakelib/libSceAgc.sprx         new          326,617
fakelib/libSceAgcDriver.sprx   new          122,383
payload total                              7,051,326
referenced from base: 107   deleted: 0
```

Again later: `python .\scripts\pkg-metric.py .\game-backport.pkg.naps_metric.json`

## Notes

* `-GameFolder` on the same drive as `-WorkFolder` is **hard-linked**, not copied.
  Without it the reference is unpacked instead, which needs roughly the
  uncompressed game size in scratch space.
* `.esbak` files are skipped — they are the backport applier's own backups.
* Anything under `sce_sys/about/` is dropped: a reserved node the SDK regenerates.
* `requiredSystemSoftwareVersion` is rewritten to `0x0500000000000000` by the
  publisher and cannot be overridden.
* The tool does nothing over the network. Getting the base package off the console
  and installing the result are yours to do.

## Helper scripts

| | |
| --- | --- |
| `scripts/pkg-info.py` | Container kind, digest and `param.json` of a package. |
| `scripts/pkg-metric.py` | What a built package actually carries. |
