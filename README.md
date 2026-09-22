# fPKG Builder

Turns a game dump and a backport file set into installable PS5 packages:

* a **base package** of the plain game, when you do not already have one, and
* a **backport update package** — a small delta that installs on top of it and
  replaces only the backport files, leaving the rest of the game in place.

## You need

* Windows, PowerShell 5.1, Python 3.
* A game dump.
* The backport files — optional, if the dump does not already include them.

Everything else runs from this folder. The SDK binaries live in `toolchain/`:

```
toolchain/prospero-pub-cmd.exe     builds the package
toolchain/libScePubTools.dll
toolchain/prospero-dds2png.exe     only for a dump whose sce_sys/pic*.dds has no PNG
toolchain/ext/                     helpers the publisher loads
```

Nothing outside this folder is ever searched. A second copy of the toolchain
elsewhere is almost certainly a different SDK build, and since the console checks
the package digest, quietly falling back to one would be worse than failing. To
keep the binaries out of the checkout, point `-ToolkitRoot` or `PS5_FPKG_TOOLKIT`
at a folder holding `toolchain/` instead.

`toolchain/` is in `.gitignore`: the SDK binaries are not redistributable, so they
stay in your working copy and are not committed. A fresh clone needs them copied
in before it will build.

## Run it

```bat
fpkg-builder.bat
```

Both packages go to **one output folder**, named from the title:

```
<TITLEID>.pkg            the base game
<TITLEID>-backport.pkg   the update
```

The base is built from the game folder when it is not there yet, and reused when it
is — so a backport built in a later run references the very package the tool made.
The backport step is optional: a dump that already has it merged in needs only the
base package.

```powershell
# 1. base package only
.\build-fpkg.ps1 -GameFolder .\PPSA12345-app -OutputFolder .\out

# 2. later, the update - into the same folder, against that same base
.\build-fpkg.ps1 `
    -GameFolder     .\PPSA12345-app `
    -BackportFolder '.\my backport files' `
    -OutputFolder   .\out
```

| Parameter | |
| --- | --- |
| `-OutputFolder` | **Required.** Where both packages are written. |
| `-GameFolder` | The game dump. Required when the base package has to be built. |
| `-BackportFolder` | Optional. Omit it to build only the base package. |
| `-Name` | Package name stem. Defaults to the title id from `param.json`. |
| `-RebuildBase` | Rebuild the base package even if it already exists. |
| `-ContentVersion` | Optional. Defaults to the base version, bumped. |
| `-CompressionLevel` | `-4`..`9`, default `7`. |
| `-WorkFolder` | Optional scratch location. |
| `-KeepWork` | Keep the work folder. |
| `-Force` | Overwrite the output. |

Install the base package on the console, then the update over it.
