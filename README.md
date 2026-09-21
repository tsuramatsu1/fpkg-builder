# PS5 Backport Update Tool

Builds a small **update package** that installs on top of an already-installed
base game and replaces only the backport files. The base game stays where it is;
nothing else in the title is touched.

For Syphon Filter (PPSA06323) the update is ~69 MB against a 2.4 GB game, and
carries 7 MB of payload: `eboot.bin`, `sce_module/libc.prx` and three `fakelib`
libraries. Confirmed installing and merging on firmware 12.00.

## Requirements

* Windows with PowerShell 5.1 and Python 3.
* The plaintext publishing toolkit — the folder containing
  `scripts/create-gp5-from-folder.py` and `toolchain/prospero-pub-cmd.exe`. It
  ships large non-redistributable SDK binaries, so it is **not** part of this
  repo.

The toolkit is discovered at run time, in this order: the `-ToolkitRoot`
parameter, the `PS5_FPKG_TOOLKIT` environment variable, the folder holding this
script, a `fpkg converter` folder beside it, then `Documents\PS5JB\fpkg converter`.
Set it once if yours lives elsewhere:

```powershell
setx PS5_FPKG_TOOLKIT "D:\path\to\fpkg converter"
```

## Creating the backport files

If you have the game's **decrypted** binaries but no backport yet,
`build-backport-files.ps1` produces one:

```powershell
.\build-backport-files.ps1 `
    -DecryptedFolder .\PPSA12345-app\decrypted `
    -OutputFolder    .\my-backport `
    -TargetFirmware  4.03 `
    -SourceFirmware  10.01
```

Three stages, run against a copy so your tree is never modified:

1. **SDK downgrade** — rewrites the SDK version fields so an older firmware accepts
   the binaries. The target firmware's major version picks the SDK pair (`4.03` →
   `--sdk 4`). It never *raises* a version: a binary already built against an older
   SDK is left alone, because bumping one to match the target is a regression.
2. **fakelib** — resolves every import against the target firmware and copies the
   smallest closed set of libraries from a newer firmware that covers what is
   missing. Omit `-SourceFirmware` to search for the earliest firmware that works;
   fewer and older sideloaded libraries mean fewer of their own imports to satisfy.
3. **fake-sign** — wraps each patched ELF in a PS5 SELF container (`54 14 F5 EE`),
   which is what shipped backports use. Signing runs after the downgrade, since it
   wraps the ELF and the SDK fields sit in segment data copied through untouched.

This needs the **ps5-backport** repo for its scripts, import/export databases and
`unp/` firmware trees. It is several GB and not redistributable, so it is not part
of this repo; it is found via `-BackportRepo`, `PS5_BACKPORT_REPO`, a sibling
`ps5-backport` folder, or `Documents\Repos\ps5-backport`.

### Two things it cannot do for you

**It needs real ELFs.** Every binary in a dump root is a SELF (`54 14 F5 EE`);
these tools need `7F 45 4C 46`, which dumps normally carry in a `decrypted/`
subfolder. The script checks and refuses rather than producing an empty result.

**It does not produce `sce_module/libc.prx`.** A real backport *substitutes* the
target SDK's build of libc — a different file, not a re-stamped one. libc is an SDK
module, so it is not in any firmware tree. Copy it from a released backport of a
comparable title.

### The library list is a superset

The analyzer names every library that could cover a missing import. A shipped 4.xx
backport of a comparable title needs two (`libSceAgc` + `libSceAgcDriver`) where the
analyzer named eight. Start with the Agc pair and add only what the klog demands —
every sideloaded library downgrades a working system library.

## Running it

```bat
backport-gui.bat
```

Or from the command line:

```powershell
.\build-backport-update.ps1 `
    -BackportFolder   '.\syphon backport files' `
    -ReferencePackage .\siphon-base.pkg `
    -OutputPackage    .\syphon-backport-4xx.pkg
```

**You do not need the game files.** The base package already contains every file
the GP5 has to describe, so when `-GameFolder` is omitted the builder unpacks the
reference package and uses that as the build tree. All you need is the base
package and the backport file set. Supplying `-GameFolder` just skips the unpack.

| Parameter | Meaning |
| --- | --- |
| `-GameFolder` | Optional. The game dump, if you have it; otherwise the base package is unpacked. |
| `-BackportFolder` | The backport file set, laid out as it sits in the game root. |
| `-ReferencePackage` | **The exact `.pkg` the console installed.** See below. |
| `-OutputPackage` | Where to write the update. |
| `-ContentVersion` | Optional; defaults to the base version with the last field bumped. |
| `-CompressionLevel` | `-4`..`9`, default `7`. |
| `-WorkFolder` | Optional; defaults to a temp folder that is removed afterwards. |
| `-KeepWork` | Keep the work folder for inspection. |

## The reference package is the thing to get right

A delta records the digest of the package it was built against (FIH header
`+0x30`), and an installed `app.pkg` keeps its source package's digest in the
same place. The console compares the two before merging. If they differ the
install fails:

```
CE-107891-6
[PlayGoCore][DbgInstall][ERROR] [0x80b21165][DigestErr]
   {0CC38CC3…, 00.000.000}    <- what the console has
   {4206B0C8…, 01.000.003}    <- what the update expects
```

**Toolkit output is not reproducible.** Rebuilding "the same" base package from
the same folder with the same tools produces a *different* digest, so you cannot
recreate a reference after the fact — you must use the real file.

For distribution this means shipping the base package and the update as a
matched pair. An update built against your base will not apply to somebody
else's separately-built copy of the same game.

If you no longer have the base package you cannot rebuild it: the publisher's
output is not reproducible, so a fresh build of the same folder has a different
digest. Keep the base package you installed alongside the update.

## What the builder handles for you

* Copies the game folder — or unpacks the base package when no folder is given —
  and overlays the backport onto that copy; your source tree is never modified.
* Removes `playgo-languages/` from the build tree. It generates those payloads
  itself, and a copy carried in from an unpacked package collides with the
  generated one: `invalid attribute value dst_path="playgo-languages/..."`.
* Skips `.esbak` files — those are the backport applier's own backups of the
  files it replaced, not content to ship.
* Drops anything under `sce_sys/about/`. That is a reserved node: the publisher
  refuses a GP5 containing it and regenerates `right.sprx` itself. A backport's
  own `right.sprx` cannot ship, and it never needs to — it is SDK 1.00 already.
* Sets `contentVersion` above the base's, which the publisher requires.
* Verifies the finished package is a delta container and that it references the
  reference digest, before you spend an install attempt on it.
* Deletes the multi-GB `.remastered.pkg` companion the publisher emits.

## Reading the result

The build prints what the update actually carries. Judge it by that, not by file
size — most of a delta is PFS and PlayGo metadata for the whole title:

```
eboot.bin                          replaced      3,785,778
fakelib/libScePsml.sprx            new           1,524,286
sce_module/libc.prx                replaced      1,285,274
fakelib/libSceAgc.sprx             new             326,617
fakelib/libSceAgcDriver.sprx       new             122,383
payload total                                    7,051,326
referenced from base: 107   deleted: 0
```

To re-read it later:

```powershell
python .\scripts\pkg-metric.py .\syphon-backport-4xx.pkg.naps_metric.json
```

## Confirming a merge actually took

Scanning the installed `app.pkg` for filenames is useless — real directories
such as `sce_module` produce zero hits. Compare content instead: take a 64-byte
slice unique to the backport binary and another unique to the retail one, then
scan. Backport slice present plus retail slice absent means the merge took. A
slice from a wholly new file confirms additions.

After a successful merge on PPSA06323, `app.pkg` grew from 2,442,133,504 to
2,444,230,656 bytes — still the full game, plus 2 MiB for the new libraries.

## Helper scripts

| Script | Purpose |
| --- | --- |
| `scripts/pkg-info.py` | Container kind, digest and `param.json` of a package. |
| `scripts/pkg-metric.py` | What a built package carries, from its metric file. |
| `build-backport-files.ps1` | Create a backport file set from decrypted binaries. |

## Limits

* There is no patch volume in this publisher. The five it accepts are
  `prospero_app`, `prospero_ac`, `prospero_al`, `prospero_il` and `prospero_fc`.
  This tool therefore builds an app volume against a reference, which is what
  produces a delta.
* `requiredSystemSoftwareVersion` is rewritten to `0x0500000000000000` by the
  publisher and cannot be overridden from `param.json`.
* A package built *without* a reference installs as a full application and
  replaces the whole title. That is why `-ReferencePackage` is mandatory here.
