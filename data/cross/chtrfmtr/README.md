# Multi-Emulator Cheat Reformatter — Avalonia / .NET 10

This is a cross-platform C# / Avalonia port of the supplied `chtrfmtr.ps1`.

The port deliberately keeps the application **monolithic**: the parser/database logic, all format modules, exporters, UI, dialogs, and application startup live in one `Program.cs`. That makes it easier to hand the project back to a non-programmer tester without having to manage a large source tree.

## What was ported

The original PowerShell architecture and behavior were retained as closely as practical:

- centralized system regex patterns
- health threshold of 80%
- midpoint verification guard at line 50
- `1to1`, `1few`, and `few1` parsing layouts
- grouped cheat database with `Name:::Format` composite keys
- dirty/unsaved editing behavior
- group add/delete/move-up/move-down
- format isolation when manually updating a group
- RetroArch global input with target-system selection
- NES Game Genie encode/decode
- binary and text import/export modules from the script
- UTF-8 text I/O without a BOM
- activity log
- native cross-platform file pickers
- a small self-contained Avalonia message dialog so no third-party message-box package is required

The source UI was WinForms-heavy, so the UI has been rebuilt with Avalonia controls rather than attempting a fake WinForms compatibility layer. The overall layout remains the same: 780×585 default window, 650×500 minimum, left/right editor area, and the existing 5% narrower design measurements from the supplied script.

## Supported input modules

- Nintendo NES
- Super Nintendo / SNES
- Game Boy / GBC
- Game Boy Advance / GBA
- Nintendo DS
- Sega Master System / SMS
- Sega Mega Drive / MD
- Sega Saturn
- Sony PlayStation / PSX (PCSXR)
- Sony PlayStation / PSX (ePSXe)
- RetroArch (Global)

## Supported output modules

- nes.emu (.cht)
- Snes9x (.cht)
- GBC.emu (.gbcht)
- VBA-M (.clt)
- melonDS (.mch)
- md.emu SMS (.pat)
- md.emu MD (.pat)
- Kronos (.yct)
- PCSXR (.cht)
- ePSXe (.txt)
- RetroArch (.cht)

## Requirements

Install the **.NET 10 SDK** on the computer where you will build/test the application.

The project uses:

- Target framework: `net10.0`
- Avalonia: `11.3.18`
- Avalonia.Desktop: `11.3.18`

Avalonia 11.3.18 is compatible with .NET 10, and Avalonia Desktop supplies the desktop platform backends used by the application.

## Build on Windows

Open PowerShell in this project folder:

```powershell
dotnet restore
dotnet build -c Release
dotnet run -c Release
```

The compiled application will be under:

```text
bin\Release\net10.0\
```

For a standalone Windows executable that does not require the .NET runtime to already be installed:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true
```

The publish folder will be:

```text
bin\Release\net10.0\win-x64\publish\
```

## Build on Linux

Open a terminal in this project folder:

```bash
dotnet restore
dotnet build -c Release
dotnet run -c Release
```

For a standalone 64-bit Linux build:

```bash
dotnet publish -c Release -r linux-x64 --self-contained true
```

The publish folder will be:

```text
bin/Release/net10.0/linux-x64/publish/
```

Make the executable runnable if necessary:

```bash
chmod +x bin/Release/net10.0/linux-x64/publish/ChtrFmtr.Avalonia
```

Then launch it:

```bash
./bin/Release/net10.0/linux-x64/publish/ChtrFmtr.Avalonia
```

### Important Linux note

Because this is Avalonia, **Wine is not required for the Linux build**. Avalonia uses the native Linux desktop backend. The old PowerShell/Wine requirement was a consequence of the WinForms-based implementation.

## If you are using Visual Studio

1. Open `ChtrFmtr.Avalonia.csproj`.
2. Let NuGet restore the two Avalonia packages.
3. Build the project.
4. Press Run.

There is intentionally no XAML file and no MVVM framework in this port. The entire program is in `Program.cs`.

## Testing approach

Because this is a port rather than a redesign, test it against the same cheat files you currently use with the PowerShell version.

A good first pass is:

1. Select the matching **Input Module**.
2. Import one known-good file.
3. Confirm the grouped descriptions appear.
4. Click a group and verify its codes appear in the editor.
5. Change one code and click **Update Current Modifications**.
6. Add a group, move it up/down, and delete it.
7. Export to the matching target format.
8. Compare the exported file with one produced by the PowerShell version.
9. Test RetroArch separately, because it has the additional target-system selection.

## Source-of-truth note

The supplied PowerShell file was used as the behavioral source for this port. The WinForms-specific pieces were replaced with their Avalonia equivalents rather than preserving WinForms types.

No PowerShell runtime is required by the resulting application.
