using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Xml.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace ChtrFmtr.Avalonia;

public sealed class CheatEntry
{
    public string BaseDesc { get; set; } = "";
    public string Format { get; set; } = "";
    public List<string> Codes { get; set; } = new();
    public double Health { get; set; } = 1.0;
    public bool IsHeading { get; set; }
    public int AccumulatedRawLength { get; set; }
    public int AccumulatedMatchLength { get; set; }
}

public sealed class ParseResult
{
    public string Code { get; init; } = "";
    public string Format { get; init; } = "";
    public int MatchLength { get; init; }
}

public sealed class ParsedCodes
{
    public List<string> Codes { get; init; } = new();
    public int RawLength { get; init; }
    public int MatchLength { get; init; }
}

public sealed class InputModule
{
    public string Name { get; init; } = "";
    public string Filter { get; init; } = "";
    public Func<string, string, object?> Parse { get; init; } = (_, _) => null;
    public Func<string, string, Func<string, string, object?>, Task> Import { get; init; } = (_, _, _) => Task.CompletedTask;
}

public sealed class OutputModule
{
    public string Name { get; init; } = "";
    public string Filter { get; init; } = "";
    public Func<string, Task> Export { get; init; } = _ => Task.CompletedTask;
}

public sealed class MainWindow : Window
{
    // =========================================================================
    // GLOBAL DATA & STATE
    // =========================================================================
    readonly Dictionary<string, CheatEntry> CheatDatabase = new(StringComparer.Ordinal);
    readonly Dictionary<string, InputModule> InputModules = new(StringComparer.Ordinal);
    readonly Dictionary<string, OutputModule> OutputModules = new(StringComparer.Ordinal);

    readonly Dictionary<string, string> SystemKeyMap = new()
    {
        ["Nintendo NES"] = "NES",
        ["Super Nintendo / SNES"] = "SNES",
        ["Game Boy / GBC"] = "GBC",
        ["Game Boy Advance / GBA"] = "GBA",
        ["Nintendo DS"] = "NDS",
        ["Sega Master System / SMS"] = "SMS",
        ["Sega Mega Drive / MD"] = "MD",
        ["Sega Saturn"] = "Saturn",
        ["Sony PlayStation / PSX (PCSXR)"] = "PCSXR",
        ["Sony PlayStation / PSX (ePSXe)"] = "ePSXe"
    };

    readonly Dictionary<string, List<(string Key, Regex Regex)>> SystemCodePatterns = new();
    readonly Dictionary<string, string> ModuleOutputMap = new()
    {
        ["Game Boy / GBC"] = "GBC.emu (.gbcht)",
        ["Game Boy Advance / GBA"] = "VBA-M (.clt)",
        ["Super Nintendo / SNES"] = "Snes9x (.cht)",
        ["Nintendo DS"] = "melonDS (.mch)",
        ["Nintendo NES"] = "nes.emu (.cht)",
        ["Sega Master System / SMS"] = "md.emu SMS (.pat)",
        ["Sega Mega Drive / MD"] = "md.emu MD (.pat)",
        ["Sega Saturn"] = "Kronos (.yct)",
        ["Sony PlayStation / PSX (PCSXR)"] = "PCSXR (.cht)",
        ["Sony PlayStation / PSX (ePSXe)"] = "ePSXe (.txt)"
    };

    bool IsDirty;
    int LastSelectedIndex = -1;
    bool SuppressEvents;
    string LastDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
    const double HealthThreshold = 0.80;
    readonly Encoding Utf8Encoding = new UTF8Encoding(false);

    // =========================================================================
    // UI
    // =========================================================================
    const double FormWidth = 812;
    const double FormHeight = 585;
    const double FormMinWidth = 676;
    const double FormMinHeight = 500;
    const double ControlHeight = 29;
    const double ComboWidth = 210;
    const double ButtonHeight = ControlHeight + 4;
    const double ActionBtnWidth = 32;
    const double AddBtnWidth = 44;
    const double SaveBtnWidth = 380;
    const double TopRowHeight = 40;
    const double ActionRowHeight = 35;
    const double LogHeaderHeight = 20;
    const double LogHeight = 70;

    readonly ComboBox cmbInputModule = new() { Width = ComboWidth };
    readonly ComboBox cmbTargetRegex = new() { Width = ComboWidth };
    readonly ComboBox cmbOutputModule = new() { Width = ComboWidth };
    readonly Button btnImport = new() { Content = "Import File", Width = 95, Height = ControlHeight };
    readonly Button btnExport = new() { Content = "Export File", Width = 95, Height = ControlHeight };
    readonly Button btnNewGroup = new() { Content = "Add", Width = AddBtnWidth, Height = ButtonHeight };
    readonly Button btnMoveUp = new() { Content = "▲", Width = ActionBtnWidth, Height = ButtonHeight, IsEnabled = false };
    readonly Button btnMoveDown = new() { Content = "▼", Width = ActionBtnWidth, Height = ButtonHeight, IsEnabled = false };
    readonly Button btnDeleteGroup = new() { Content = "❌", Width = ActionBtnWidth, Height = ButtonHeight, IsEnabled = false };
    readonly Button btnSaveGroup = new() { Content = "Update Current Modifications", Width = SaveBtnWidth, Height = ButtonHeight, IsEnabled = false };
    readonly TextBox txtNewGroup = new() { Text = "New group name", Height = ControlHeight };
    readonly ListBox lstCheats = new();
    readonly TextBox txtEditor = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
    readonly TextBox txtStatusLog = new() { AcceptsReturn = true, IsReadOnly = true, TextWrapping = TextWrapping.NoWrap };
    readonly TextBlock lblTargetRegex = new() { Text = "Target System Regex:", IsVisible = false };
    readonly TextBlock lblInput = new() { Text = "Input Module:" };
    readonly TextBlock lblOutput = new() { Text = "Export To:" };

    bool placeholderActive = true;

    public MainWindow()
    {
        Title = "Multi-Emulator Cheat Reformatter";
        Width = FormWidth;
        Height = FormHeight;
        MinWidth = FormMinWidth;
        MinHeight = FormMinHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        BuildPatternLibrary();
        RegisterModules();
        BuildUi();
        WireEvents();
        UpdateOutputModuleChoices();

        if (cmbInputModule.ItemCount > 0)
            cmbInputModule.SelectedIndex = 0;

        UpdateOutputModuleChoices();
        WriteLog("Application initialized.");
    }

    // =========================================================================
    // REGEX MASTER LIBRARY / SYSTEM PATTERNS
    // =========================================================================
    void BuildPatternLibrary()
    {
        Regex R(string p) => new(p, RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        SystemCodePatterns["NES"] = new()
        {
            ("68gg", R(@"(?<![0-9A-Z])([AEGIKLN-PS-VX-Z]{6}|[AEGIKLN-PS-VX-Z]{8})(?![0-9A-Z])")),
            ("422hex", R(@"((?<![0-9A-F])[0-9A-F]{4}([\p{P}\p{S}\p{Z}][0-9A-F]{2}){1,2}(?![0-9A-F]))"))
        };
        SystemCodePatterns["SNES"] = new()
        {
            ("44hex", R(@"((?<![0-9A-F])[0-9A-F]{4}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))")),
            ("8hex", R(@"((?<![0-9A-F])[0-9A-F]{8}(?![0-9A-F]))"))
        };
        SystemCodePatterns["GBC"] = new()
        {
            ("8hex", R(@"((?<![0-9A-F])[0-9A-F]{8}(?![0-9A-F]))")),
            ("333gg", R(@"((?<![0-9A-F])[0-9A-F]{3}([\p{P}\p{S}\p{Z}][0-9A-F]{3}){2}(?![0-9A-F]))"))
        };
        SystemCodePatterns["GBA"] = new()
        {
            ("84hex", R(@"((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))"))
        };
        SystemCodePatterns["NDS"] = new()
        {
            ("88hex", R(@"((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{8}(?![0-9A-F]))"))
        };
        SystemCodePatterns["SMS"] = new()
        {
            ("333gg", R(@"((?<![0-9A-F])[0-9A-F]{3}([\p{P}\p{S}\p{Z}][0-9A-F]{3}){2}(?![0-9A-F]))"))
        };
        SystemCodePatterns["MD"] = new()
        {
            ("64hex", R(@"((?<![0-9A-F])[0-9A-F]{6}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))")),
            ("44hex", R(@"((?<![0-9A-F])[0-9A-F]{4}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))"))
        };
        SystemCodePatterns["Saturn"] = new()
        {
            ("84hex", R(@"((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))"))
        };
        SystemCodePatterns["ePSXe"] = new()
        {
            ("848hex", R(@"((?<![0-9A-F])[0-9A-F]{8})[\p{P}\p{S}\p{Z}]([0-9A-F]{4,8}(?![0-9A-F]))"))
        };
        SystemCodePatterns["PCSXR"] = new()
        {
            ("848hex", R(@"((?<![0-9A-F])[0-9A-F]{8})[\p{P}\p{S}\p{Z}]([0-9A-F]{4,8}(?![0-9A-F]))"))
        };
    }

    string SystemKey(string profile) => SystemKeyMap.TryGetValue(profile, out var key) ? key : profile;

    ParseResult? InvokeSystemParser(string systemName, string? rawLine)
    {
        if (string.IsNullOrWhiteSpace(rawLine)) return null;
        var clean = Regex.Replace(rawLine.Trim(), @"^[*\t\s#]+", "");
        if (!SystemCodePatterns.TryGetValue(systemName, out var patterns)) return null;

        foreach (var p in patterns)
        {
            var m = p.Regex.Match(clean);
            if (m.Success)
                return new ParseResult { Code = m.Value.ToUpperInvariant().Trim(), Format = p.Key, MatchLength = m.Value.Length };
        }
        return null;
    }

    // =========================================================================
    // HELPER METHOD (PREVENTS ACCIDENTAL DISCARD DIALOGS)
    // =========================================================================
    void SetEditorText(string text)
    {
        SuppressEvents = true;
        txtEditor.Text = text;
        IsDirty = false;
        SuppressEvents = false;
    }

    // =========================================================================
    // DATABASE
    // =========================================================================
    void AddCheatToDatabase(string description, IEnumerable<string> codes, string? systemName = null,
        string? formatOverride = null, int rawLength = 0, int matchLength = 0)
    {
        var codeList = codes?.ToList() ?? new();
        bool isHeading = rawLength == 0 && codeList.Count == 0;
        double health = rawLength > 0 ? (double)matchLength / rawLength : 1.0;

        if (!isHeading && health < HealthThreshold)
        {
            WriteLog($"Discarded entry group '{description}' due to health failure ({health * 100:0.0}% score falls below required {HealthThreshold * 100:0.0}% threshold).", "WARN");
            return;
        }

        var grouped = new Dictionary<string, List<string>>();
        foreach (var code in codeList)
        {
            var format = formatOverride ?? "Unknown";
            var cleanCode = code.Trim().ToUpperInvariant();
            if (formatOverride is null && !string.IsNullOrEmpty(systemName))
            {
                var parsed = InvokeSystemParser(systemName, cleanCode);
                if (parsed != null)
                {
                    format = parsed.Format;
                    cleanCode = parsed.Code;
                }
            }
            if (!grouped.TryGetValue(format, out var list))
                grouped[format] = list = new List<string>();
            list.Add(cleanCode);
        }

        if (isHeading)
            grouped["Heading"] = new List<string>();

        foreach (var pair in grouped)
        {
            var key = $"{description}:::{pair.Key}";
            if (!CheatDatabase.TryGetValue(key, out var entry))
            {
                CheatDatabase[key] = new CheatEntry
                {
                    BaseDesc = description,
                    Format = pair.Key,
                    Codes = new List<string>(pair.Value),
                    Health = health,
                    IsHeading = isHeading,
                    AccumulatedRawLength = rawLength,
                    AccumulatedMatchLength = matchLength
                };
            }
            else
            {
                entry.Codes.AddRange(pair.Value);
                entry.AccumulatedRawLength += rawLength;
                entry.AccumulatedMatchLength += matchLength;
                if (entry.AccumulatedRawLength > 0)
                    entry.Health = (double)entry.AccumulatedMatchLength / entry.AccumulatedRawLength;
            }
        }
    }

    IEnumerable<KeyValuePair<string, CheatEntry>> VisibleEntries() =>
        CheatDatabase.Where(kv => kv.Value.Format != "Heading");

    // =========================================================================
    // UNIVERSAL PIPELINE
    // =========================================================================
    async Task InvokeUnifiedCheatEngineAsync(
        string[] lines, string systemName, string layoutType,
        string? nameHeaderRegex = null, string? codeHeaderRegex = null,
        string? delimiter = null, Func<string, string, object?>? parseFunc = null)
    {
        if (lines.Length == 0) return;
        var systemKey = SystemKey(systemName);
        var metrics = new Metrics();

        async Task<bool> CheckLine(string chkLine, bool isDescription)
        {
            metrics.LinesProcessed++;
            if (isDescription) metrics.CodeNamesFound++;

            if (InvokeSystemParser(systemKey, chkLine) != null)
                metrics.CodesFound++;

            if (metrics.LinesProcessed == 50)
            {
                var density = metrics.CodesFound / 50.0;
                if (density < 0.04 || metrics.CodeNamesFound == 0)
                {
                    WriteLog($"File verification failed at line 50: Density={density * 100:0.0}% (min 4%), Names Found={metrics.CodeNamesFound} (min 1%).", "WARN");
                    await Dialogs.Message(this,
                        "File verification failed: Content density or naming structure does not match the selected Input Module schema.",
                        "Verification Guard Warning", DialogButtons.Ok, DialogIcon.Warning);
                    CheatDatabase.Clear();
                    return false;
                }
            }
            return true;
        }

        string rollingParentCategory = "Unassigned Code Block";
        bool hasPromptedForMerge = false;
        bool mergeCategories = false;

        if (layoutType == "1to1")
        {
            foreach (var line in lines)
            {
                var trimmed = line.Trim();
                if (string.IsNullOrWhiteSpace(trimmed) || trimmed.StartsWith('#')) continue;

                string rawCode = "", rawDesc = "Unassigned Code Block";
                bool isDescription = false;

                if (!string.IsNullOrEmpty(delimiter))
                {
                    var parts = trimmed.Split(new[] { delimiter }, 2, StringSplitOptions.None);
                    rawCode = parts.Length > 1 ? parts[0].Trim() : trimmed;
                    rawDesc = parts.Length > 1 ? parts[1].Replace("'", "").Trim() : "Unassigned Code Block";
                    isDescription = parts.Length > 1 && !string.IsNullOrWhiteSpace(rawDesc);
                }
                else if (!string.IsNullOrEmpty(nameHeaderRegex) && !string.IsNullOrEmpty(codeHeaderRegex))
                {
                    var nm = Regex.Match(trimmed, nameHeaderRegex);
                    if (nm.Success) { rawDesc = nm.Groups[1].Value.Replace("'", "").Trim(); isDescription = true; }
                    var cm = Regex.Match(trimmed, codeHeaderRegex);
                    if (cm.Success) rawCode = cm.Groups[1].Value.Trim();
                }
                else rawCode = trimmed;

                if (!await CheckLine(rawCode, isDescription)) return;

                var parsed = InvokeSystemParser(systemKey, rawCode);
                var codeArray = parsed == null ? Array.Empty<string>() : new[] { parsed.Code };
                var matchLength = parsed?.MatchLength ?? 0;

                if (matchLength == 0 && rawCode.Length > 0)
                {
                    rollingParentCategory = rawDesc;
                    AddCheatToDatabase(rawDesc, Array.Empty<string>(), systemKey);
                    continue;
                }

                var finalTitle = mergeCategories && rollingParentCategory != "Unassigned Code Block"
                    ? $"{rollingParentCategory} - {rawDesc}" : rawDesc;
                AddCheatToDatabase(finalTitle, codeArray, systemKey, rawLength: rawCode.Length, matchLength: matchLength);
            }
        }
        else if (layoutType == "1few")
        {
            string currentHeader = "Unassigned Code Block";
            var currentCodes = new List<string>();
            int totalRawLength = 0, totalMatchLength = 0;

            void CommitBlock()
            {
                if (currentCodes.Count == 0) return;
                var finalTitle = mergeCategories && rollingParentCategory != "Unassigned Code Block"
                    ? $"{rollingParentCategory} - {currentHeader}" : currentHeader;
                AddCheatToDatabase(finalTitle, currentCodes, systemKey, rawLength: totalRawLength, matchLength: totalMatchLength);
                currentCodes.Clear();
            }

            foreach (var line in lines)
            {
                var trimmed = line.Trim();
                if (string.IsNullOrWhiteSpace(trimmed)) continue;

                bool isDescription = false;
                var chkLine = trimmed;
                var nm = !string.IsNullOrEmpty(nameHeaderRegex) ? Regex.Match(trimmed, nameHeaderRegex) : Match.Empty;
                if (nm.Success)
                {
                    isDescription = true;
                    chkLine = nm.Groups[1].Value.Trim();
                    if (!await CheckLine(chkLine, isDescription)) return;

                    CommitBlock();
                    currentHeader = nm.Groups.Count > 1 ? nm.Groups[1].Value.Replace("'", "").Trim() : "Unassigned Code Block";
                    if (string.IsNullOrWhiteSpace(currentHeader)) currentHeader = "Unassigned Code Block";
                    rollingParentCategory = currentHeader;
                    AddCheatToDatabase(currentHeader, Array.Empty<string>(), systemKey);
                    totalRawLength = 0;
                    totalMatchLength = 0;
                }
                else
                {
                    var cleanCodeLine = Regex.Replace(trimmed, @"^[*\t\s#]+", "");
                    if (!string.IsNullOrEmpty(codeHeaderRegex))
                    {
                        var cm = Regex.Match(trimmed, codeHeaderRegex);
                        if (cm.Success) cleanCodeLine = cm.Groups[1].Value.Trim();
                    }
                    chkLine = cleanCodeLine;
                    if (!await CheckLine(chkLine, isDescription)) return;

                    totalRawLength += cleanCodeLine.Length;
                    var parsed = InvokeSystemParser(systemKey, cleanCodeLine);
                    if (parsed != null)
                    {
                        currentCodes.Add(parsed.Code);
                        totalMatchLength += parsed.MatchLength;
                    }
                }
            }
            CommitBlock();
        }
        else if (layoutType == "few1")
        {
            if (parseFunc == null || string.IsNullOrEmpty(nameHeaderRegex) || string.IsNullOrEmpty(codeHeaderRegex)) return;

            var descMap = new Dictionary<string, string>();
            var codeMap = new Dictionary<string, string>();

            foreach (var line in lines)
            {
                bool isDescription = false;
                string chkLine = line;

                var dm = Regex.Match(line, nameHeaderRegex);
                if (dm.Success)
                {
                    descMap[dm.Groups[1].Value] = dm.Groups[2].Value.Trim();
                    isDescription = true;
                    chkLine = dm.Groups[2].Value.Trim();
                }
                else
                {
                    var cm = Regex.Match(line, codeHeaderRegex);
                    if (cm.Success)
                    {
                        codeMap[cm.Groups[1].Value] = cm.Groups[2].Value.Trim();
                        chkLine = cm.Groups[2].Value.Trim();
                    }
                }

                if (!await CheckLine(chkLine, isDescription)) return;
            }

            foreach (var pair in descMap)
            {
                var key = pair.Key;
                var descText = pair.Value;
                if (!codeMap.ContainsKey(key))
                {
                    if (!hasPromptedForMerge)
                    {
                        hasPromptedForMerge = true;
                        mergeCategories = await Dialogs.Message(this,
                            "Merge structural parent categories into code description naming blocks?",
                            "Universal Category Layout Manager", DialogButtons.YesNo, DialogIcon.Question) == DialogResult.Yes;
                    }
                    rollingParentCategory = descText;
                    AddCheatToDatabase(descText, Array.Empty<string>(), systemKey);
                    continue;
                }

                var result = parseFunc(codeMap[key], systemName);
                if (result == null) continue;

                List<string> cleanCodes;
                int rawLen = 0, matchLen = 0;
                if (result is ParsedCodes pc)
                {
                    cleanCodes = pc.Codes;
                    rawLen = pc.RawLength;
                    matchLen = pc.MatchLength;
                }
                else if (result is string s)
                {
                    cleanCodes = new List<string> { s };
                }
                else if (result is IEnumerable<string> ss)
                {
                    cleanCodes = ss.ToList();
                }
                else continue;

                if (cleanCodes.Count == 0) continue;
                var finalTitle = mergeCategories && rollingParentCategory != "Unassigned Code Block"
                    ? $"{rollingParentCategory} - {descText}" : descText;
                finalTitle = finalTitle.Replace("'", "").Trim();
                if (string.IsNullOrWhiteSpace(finalTitle)) finalTitle = "Unassigned Code Block";
                AddCheatToDatabase(finalTitle, cleanCodes, systemKey, rawLength: rawLen, matchLength: matchLen);
            }
        }

        if (metrics.CodeNamesFound == 0)
        {
            var stagedCount = VisibleEntries().Count();
            if (metrics.CodesFound > 0 && stagedCount == 0)
            {
                WriteLog($"File verification failed: Matching codes detected ({metrics.CodesFound}), but zero valid naming blocks or cheats could be structured.", "WARN");
                await Dialogs.Message(this,
                    "File verification failed: Matching codes were detected, but no valid cheat names could be parsed under the selected module rules.",
                    "Name Extraction Failure", DialogButtons.Ok, DialogIcon.Warning);
                CheatDatabase.Clear();
                return;
            }
            if (stagedCount > 0) metrics.CodeNamesFound = stagedCount;
        }

        CheatDatabase[":::_METRICS:::Global"] = new CheatEntry
        {
            BaseDesc = "File Metrics Metadata Summary Record Instance",
            Format = "Heading",
            IsHeading = true
        };
        WriteLog($"File parsing complete. Summary Metrics -> Total Lines Processed: {metrics.LinesProcessed} | Unique Naming Elements Identified: {metrics.CodeNamesFound} | Format Match Codes Found: {metrics.CodesFound}");
    }

    sealed class Metrics
    {
        public int LinesProcessed;
        public int CodeNamesFound;
        public int CodesFound;
    }

    // =========================================================================
    // SHARED IMPORT ENGINES
    // =========================================================================
    string[] ReadAllLines(string path) => File.ReadAllLines(path, Utf8Encoding);

    async Task ImportRetroArchChtEngine(string filePath, string systemProfile, Func<string, string, object?> parseFunc)
    {
        await InvokeUnifiedCheatEngineAsync(ReadAllLines(filePath), systemProfile, "few1",
            @"^cheat(\d+)_desc\s*=\s*""(.*)""",
            @"^cheat(\d+)_code\s*=\s*""(.*)""", parseFunc: parseFunc);
    }

    void ImportVbaCltEngine(string filePath)
    {
        using var fs = File.OpenRead(filePath);
        using var br = new BinaryReader(fs);
        if (fs.Length < 12) return;

        fs.Position = 8;
        int totalRecords = br.ReadInt32();
        long remaining = fs.Length - 12;
        int stride = 84;
        if (totalRecords > 0 && remaining / totalRecords == 80) stride = 80;

        var pre = new List<string>();
        for (int i = 0; i < totalRecords; i++)
        {
            long recordStart = 12L + i * stride;
            if (recordStart + stride > fs.Length) break;
            long codeOffset = recordStart + (stride == 80 ? 28 : 32);
            long descOffset = recordStart + (stride == 80 ? 48 : 52);
            fs.Position = codeOffset;
            var rawCode = ReadNullTerminated(br.ReadBytes(20), Encoding.ASCII);
            fs.Position = descOffset;
            var rawDesc = ReadNullTerminated(br.ReadBytes(32), Encoding.ASCII);
            if (string.IsNullOrWhiteSpace(rawDesc)) rawDesc = "Unassigned Code Block";
            if (!string.IsNullOrWhiteSpace(rawCode)) pre.Add($"{rawCode}\t{rawDesc}");
        }

        if (pre.Count > 0)
            InvokeUnifiedCheatEngineAsync(pre.ToArray(), "GBA", "1to1", delimiter: "\t").GetAwaiter().GetResult();
    }

    async Task ImportMyBoyChtEngine(string filePath)
    {
        try
        {
            var doc = XDocument.Load(filePath, LoadOptions.PreserveWhitespace);
            var lines = new List<string>();
            foreach (var cheat in doc.Descendants("cheat").Where(x => (string?)x.Attribute("type") == "cb"))
            {
                var rawName = (string?)cheat.Attribute("name") ?? (string?)cheat.Element("name") ?? "";
                var name = rawName.Replace("'", "").Trim();
                if (string.IsNullOrWhiteSpace(name)) name = "Unassigned Code Block";
                lines.Add($"[NAME] {name}");
                foreach (var c in cheat.Descendants("code"))
                {
                    var raw = c.Value;
                    if (!string.IsNullOrWhiteSpace(raw)) lines.Add(raw.Trim());
                }
            }
            if (lines.Count > 0)
                await InvokeUnifiedCheatEngineAsync(lines.ToArray(), "GBA", "1few", @"^\[NAME\]\s*(.*)");
        }
        catch (Exception ex)
        {
            throw new InvalidDataException($"Failed parsing MyBoy XML target: {ex.Message}", ex);
        }
    }

    void ImportKronosYctEngine(string filePath)
    {
        using var fs = File.OpenRead(filePath);
        using var br = new BinaryReader(fs);
        if (fs.Length < 8) return;
        var magic = Encoding.ASCII.GetString(br.ReadBytes(4));
        if (magic != "YCHT") return;
        fs.Position = 7;
        int total = br.ReadByte();
        var pre = new List<string>();

        for (int i = 0; i < total; i++)
        {
            if (fs.Position + 13 > fs.Length) break;
            var typeBytes = br.ReadBytes(4);
            byte typeByte = typeBytes[3];
            string prefix = typeByte switch { 0x02 => "3", 0x03 => "1", _ => "D" };
            var addr = br.ReadBytes(4);
            if (addr.Length < 4) break;
            string fullAddr = prefix + (addr[0] & 0x0F).ToString("X") +
                              addr[1].ToString("X2") + addr[2].ToString("X2") + addr[3].ToString("X2");
            br.ReadBytes(2);
            var val = br.ReadBytes(2);
            if (val.Length < 2) break;
            string rawCode = $"{fullAddr} {val[0]:X2}{val[1]:X2}";
            int nameLength = Math.Max(1, br.ReadByte() - 1);
            if (fs.Position + nameLength + 5 > fs.Length) break;
            string desc = ReadNullTerminated(br.ReadBytes(nameLength), Encoding.ASCII).Trim();
            br.ReadBytes(5);
            if (string.IsNullOrWhiteSpace(desc)) desc = "Unassigned Code Block";
            pre.Add($"{rawCode}\t{desc}");
        }

        if (pre.Count > 0)
            InvokeUnifiedCheatEngineAsync(pre.ToArray(), "Saturn", "1to1", delimiter: "\t").GetAwaiter().GetResult();
    }

    void ImportNesChtEngine(string filePath, Func<string, string, object?> parseFunc)
    {
        var pre = new List<string>();
        foreach (var line in ReadAllLines(filePath))
        {
            var trimmed = line.Trim();
            if (string.IsNullOrWhiteSpace(trimmed) || trimmed.StartsWith("#")) continue;
            var active = trimmed.TrimStart(':');
            var parts = active.Split(':');
            if (parts.Length < 2) continue;

            int addrIndex = 0;
            string prefix = "";
            if (parts[0] is "S" or "SC" or "C") { prefix = parts[0]; addrIndex = 1; }
            if (parts.Length - addrIndex < 2) continue;

            string addressHex = parts[addrIndex];
            string val1 = parts[addrIndex + 1];
            string? compareValue = null;
            string description;
            if (parts.Length == addrIndex + 4)
            {
                compareValue = parts[addrIndex + 2];
                description = parts[addrIndex + 3];
            }
            else if (parts.Length > addrIndex + 4)
            {
                compareValue = parts[addrIndex + 2];
                description = string.Join(':', parts.Skip(addrIndex + 3));
            }
            else if (parts.Length == addrIndex + 3)
                description = parts[addrIndex + 2];
            else description = "Unassigned Code Block";

            var cleanDesc = description.Replace("'", "").Trim();
            if (string.IsNullOrWhiteSpace(cleanDesc)) cleanDesc = "Unassigned Code Block";

            var codeList = new List<string>();
            if (Regex.IsMatch(addressHex, @"^[0-9A-Fa-f]{4}$"))
            {
                int addressVal = Convert.ToInt32(addressHex, 16);
                if (addressVal >= 0x8000)
                {
                    var rawSegment = $"{addressHex}:{val1}" + (compareValue != null ? $":{compareValue}" : "");
                    var encoded = InvokeGameGenieEncodeNES(rawSegment);
                    if (!string.IsNullOrEmpty(encoded)) codeList.Add(encoded);
                }
            }

            if (codeList.Count == 0)
            {
                var rawSegment = string.IsNullOrEmpty(prefix) ? $"{addressHex}:{val1}" : $"{prefix}:{addressHex}:{val1}";
                var parsed = InvokeSystemParser("NES", rawSegment);
                if (parsed != null) codeList.Add(parsed.Code);
                else
                {
                    var fallback = parseFunc($"{addressHex} {val1}", "NES");
                    if (fallback is ParsedCodes pc) codeList.AddRange(pc.Codes);
                    else if (fallback is string s && !string.IsNullOrEmpty(s)) codeList.Add(s);
                    else if (fallback is IEnumerable<string> ss) codeList.AddRange(ss);
                }
            }

            foreach (var code in codeList) pre.Add($"{code}\t{cleanDesc}");
        }

        if (pre.Count > 0)
            InvokeUnifiedCheatEngineAsync(pre.ToArray(), "NES", "1to1", delimiter: "\t").GetAwaiter().GetResult();
    }

    static string ReadNullTerminated(byte[] bytes, Encoding enc)
    {
        var zero = Array.IndexOf(bytes, (byte)0);
        if (zero < 0) zero = bytes.Length;
        return enc.GetString(bytes, 0, zero);
    }

    // =========================================================================
    // MODULE REGISTRATION
    // =========================================================================
    void RegisterInput(string name, string filter,
        Func<string, string, object?> parse,
        Func<string, string, Func<string, string, object?>, Task> import) =>
        InputModules[name] = new InputModule { Name = name, Filter = filter, Parse = parse, Import = import };

    void RegisterOutput(string name, string filter, Func<string, Task> export) =>
        OutputModules[name] = new OutputModule { Name = name, Filter = filter, Export = export };

    void RegisterModules()
    {
        Func<string, string, object?> SimpleParser(string system) => (input, _) =>
        {
            var r = InvokeSystemParser(system, input);
            return r?.Code;
        };

        RegisterInput("Sega Saturn", "Saturn Cheat Files (*.yct)|*.yct",
            SimpleParser("Saturn"),
            async (path, profile, parse) =>
            {
                var sniff = string.Join(" ", ReadAllLines(path).Take(3)).Trim();
                if (Regex.IsMatch(sniff, @"^cheats\s*=") || Regex.IsMatch(sniff, @"^cheat\d+_"))
                    await ImportRetroArchChtEngine(path, profile, parse);
                else
                    ImportKronosYctEngine(path);
            });
        RegisterOutput("Kronos (.yct)", "Kronos Cheat Files (*.yct)|*.yct", path => { ExportKronos(path); return Task.CompletedTask; });

        RegisterInput("Game Boy Advance / GBA", "GBA Cheat Files (*.cht;*.clt)|*.cht;*.clt",
            SimpleParser("GBA"),
            async (path, profile, parse) =>
            {
                var sniff = string.Join(" ", ReadAllLines(path).Take(3)).Trim();
                if (Regex.IsMatch(sniff, @"^cheats\s*=") || Regex.IsMatch(sniff, @"^cheat\d+_"))
                    await ImportRetroArchChtEngine(path, profile, parse);
                else if (sniff.Contains("<?xml", StringComparison.OrdinalIgnoreCase) && sniff.Contains("<cheats>", StringComparison.OrdinalIgnoreCase))
                    await ImportMyBoyChtEngine(path);
                else
                {
                    byte[] buffer;
                    using (var fs = File.OpenRead(path))
                    {
                        buffer = new byte[12];
                        int read = fs.Read(buffer, 0, 12);
                        if (read < 12) throw new InvalidDataException("File is too small to contain a valid binary cheat header.");
                    }
                    var sig = BitConverter.ToString(buffer);
                    if (Regex.IsMatch(sig, @"^01-00-00-00-(01|00)-00-00-00-[0-9A-Fa-f]{2}-00-00-00$", RegexOptions.IgnoreCase))
                        ImportVbaCltEngine(path);
                    else throw new InvalidDataException("Unknown or invalid binary cheat file format signature.");
                }
            });
        RegisterOutput("VBA-M (.clt)", "VBA Cheat Files (*.clt)|*.clt", path => { ExportVbaClt(path); return Task.CompletedTask; });

        RegisterInput("Super Nintendo / SNES", "SNES Cheat Files (*.cht)|*.cht",
            SimpleParser("SNES"),
            (path, profile, parse) =>
            {
                var pre = new List<string>();
                string? current = null;
                foreach (var line in ReadAllLines(path))
                {
                    var trimmed = line.Trim();
                    var nm = Regex.Match(trimmed, @"^name:\s*(.*)");
                    var cm = Regex.Match(trimmed, @"^code:\s*(.*)");
                    if (nm.Success) current = nm.Groups[1].Value.Trim();
                    else if (cm.Success && current != null)
                    {
                        var code = cm.Groups[1].Value.Trim().Replace("=", "");
                        pre.Add($"{code}\t{current}");
                        current = null;
                    }
                }
                return InvokeUnifiedCheatEngineAsync(pre.ToArray(), "SNES", "1to1", delimiter: "\t");
            });
        RegisterOutput("Snes9x (.cht)", "Snes9x Cheat Files (*.cht)|*.cht", path => { ExportSnes(path); return Task.CompletedTask; });

        RegisterInput("Sega Master System / SMS", "Master System Cheats (*.pat)|*.pat",
            SimpleParser("SMS"),
            (path, profile, parse) => InvokeUnifiedCheatEngineAsync(ReadAllLines(path), "SMS", "1to1", delimiter: "\t"));
        RegisterOutput("md.emu SMS (.pat)", "md.emu Cheat Files (*.pat)|*.pat", path => { ExportTabDelimited(path); return Task.CompletedTask; });

        RegisterInput("Sony PlayStation / PSX (PCSXR)", "PCSXR Cheat Files (*.cht)|*.cht",
            SimpleParser("PCSXR"),
            (path, profile, parse) => InvokeUnifiedCheatEngineAsync(ReadAllLines(path), "PCSXR", "1few", @"^\[(.*)\]"));
        RegisterInput("Sony PlayStation / PSX (ePSXe)", "ePSXe Cheat Files (*.txt)|*.txt",
            SimpleParser("ePSXe"),
            (path, profile, parse) => InvokeUnifiedCheatEngineAsync(ReadAllLines(path), "ePSXe", "1few", @"^#(.*)"));
        RegisterOutput("PCSXR (.cht)", "PCSXR Cheat Files (*.cht)|*.cht", path => { ExportPcsxr(path); return Task.CompletedTask; });
        RegisterOutput("ePSXe (.txt)", "ePSXe Cheat Files (*.txt)|*.txt", path => { ExportEpsxe(path); return Task.CompletedTask; });

        RegisterInput("Game Boy / GBC", "GBC Cheat Files (*.gbcht)|*.gbcht",
            SimpleParser("GBC"),
            (path, profile, parse) =>
            {
                using var fs = File.OpenRead(path);
                using var br = new BinaryReader(fs);
                if (fs.Length < 4) return Task.CompletedTask;
                fs.Position = 1;
                int total = br.ReadByte();
                fs.Position = 3;
                var pre = new List<string>();
                for (int i = 0; i < total; i++)
                {
                    if (fs.Position + 3 > fs.Length) break;
                    br.ReadByte();
                    int descLen = br.ReadByte();
                    br.ReadByte();
                    if (fs.Position + descLen > fs.Length) break;
                    var desc = Encoding.ASCII.GetString(br.ReadBytes(descLen)).Trim();
                    if (fs.Position + 1 > fs.Length) break;
                    int codeLen = br.ReadByte() == 0x0b ? 11 : 8;
                    if (fs.Position + codeLen > fs.Length) break;
                    var code = Encoding.ASCII.GetString(br.ReadBytes(codeLen)).Trim();
                    if (string.IsNullOrWhiteSpace(desc)) desc = "Unassigned Code Block";
                    if (!string.IsNullOrWhiteSpace(code)) pre.Add($"{code}\t{desc}");
                }
                return InvokeUnifiedCheatEngineAsync(pre.ToArray(), "GBC", "1to1", delimiter: "\t");
            });
        RegisterOutput("GBC.emu (.gbcht)", "GBC Cheat Files (*.gbcht)|*.gbcht", path => { ExportGbc(path); return Task.CompletedTask; });

        RegisterInput("Sega Mega Drive / MD", "MD Cheats (*.pat)|*.pat",
            SimpleParser("MD"),
            (path, profile, parse) => InvokeUnifiedCheatEngineAsync(ReadAllLines(path), "MD", "1to1", delimiter: "\t"));
        RegisterOutput("md.emu MD (.pat)", "md.emu Cheat Files (*.pat)|*.pat", path => { ExportTabDelimited(path); return Task.CompletedTask; });

        RegisterInput("Nintendo DS", "NDS Cheat Files (*.mch)|*.mch",
            SimpleParser("NDS"),
            (path, profile, parse) => InvokeUnifiedCheatEngineAsync(ReadAllLines(path), "NDS", "1few", @"^CODE\s+\d+\s*(.*)"));
        RegisterOutput("melonDS (.mch)", "melonDS Cheat Files (*.mch)|*.mch", path => { ExportMch(path); return Task.CompletedTask; });

        RegisterInput("Nintendo NES", "NES Cheat Files (*.cht)|*.cht",
            (input, _) =>
            {
                if (string.IsNullOrEmpty(input)) return null;
                var res = InvokeSystemParser("NES", input);
                if (res == null) return null;
                var m = Regex.Match(res.Code, @"^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$");
                if (m.Success && Convert.ToInt32(m.Groups[1].Value, 16) >= 0x8000)
                    return InvokeGameGenieEncodeNES(res.Code);
                return res.Code;
            },
            async (path, profile, parse) =>
            {
                var sniff = string.Join(" ", ReadAllLines(path).Take(3)).Trim();
                if (Regex.IsMatch(sniff, @"^cheats\s*=") || Regex.IsMatch(sniff, @"^cheat\d+_"))
                    await ImportRetroArchChtEngine(path, profile, parse);
                else
                    ImportNesChtEngine(path, parse);
            });
        RegisterOutput("nes.emu (.cht)", "nes.emu Cheat Files (*.cht)|*.cht", path => { ExportNes(path); return Task.CompletedTask; });

        RegisterInput("RetroArch (Global)", "RetroArch Cheat Files (*.cht)|*.cht",
            (input, target) =>
            {
                if (string.IsNullOrEmpty(target)) return null;
                var system = SystemKey(target);
                if (!SystemCodePatterns.TryGetValue(system, out var patterns)) return null;
                var results = new List<string>();
                int matchLen = 0;
                var sanitized = input.Replace("+", " ");
                foreach (var p in patterns)
                {
                    foreach (Match m in p.Regex.Matches(sanitized))
                    {
                        var c = m.Value.ToUpperInvariant().Trim();
                        if (c.Length > 0) { results.Add(c); matchLen += m.Value.Length; }
                    }
                }
                return new ParsedCodes { Codes = results, RawLength = input.Length, MatchLength = matchLen };
            },
            (path, profile, parse) => ImportRetroArchChtEngine(path, profile, parse));
        RegisterOutput("RetroArch (.cht)", "RetroArch Cheat Files (*.cht)|*.cht", path => { ExportRetroArch(path); return Task.CompletedTask; });
    }

    // =========================================================================
    // GAME GENIE NES
    // =========================================================================
    static int UnmapNesChar(char c) => char.ToUpperInvariant(c) switch
    {
        'A' => 0, 'P' => 1, 'Z' => 2, 'L' => 3,
        'G' => 4, 'I' => 5, 'T' => 6, 'Y' => 7,
        'E' => 8, 'O' => 9, 'X' => 10, 'U' => 11,
        'K' => 12, 'S' => 13, 'V' => 14, 'N' => 15,
        _ => 0
    };

    static char MapNesChar(int v) => v switch
    {
        0 => 'A', 1 => 'P', 2 => 'Z', 3 => 'L',
        4 => 'G', 5 => 'I', 6 => 'T', 7 => 'Y',
        8 => 'E', 9 => 'O', 10 => 'X', 11 => 'U',
        12 => 'K', 13 => 'S', 14 => 'V', 15 => 'N',
        _ => '?'
    };

    static string? InvokeGameGenieDecodeNES(string gg)
    {
        gg = gg.Trim().ToUpperInvariant();
        if (gg.Length != 6 && gg.Length != 8) return null;
        var data = new int[8];
        for (int i = 0; i < gg.Length; i++) data[i] = UnmapNesChar(gg[i]);

        int address = 0x8000;
        address |= (data[1] & 8) << 4;
        address |= (data[2] & 7) << 4;
        address |= (data[3] & 7) << 12;
        address |= (data[3] & 8);
        address |= (data[4] & 7);
        address |= (data[4] & 8) << 8;
        address |= (data[5] & 7) << 8;

        int value = 0, check = 0;
        if (gg.Length == 8)
        {
            value |= data[0] & 7;
            value |= (data[0] & 8) << 4;
            value |= (data[1] & 7) << 4;
            value |= data[7] & 8;
            check |= data[5] & 8;
            check |= data[6] & 7;
            check |= (data[6] & 8) << 4;
            check |= (data[7] & 7) << 4;
            return $"{address:X4}:{value:X2}:{check:X2}";
        }

        value |= data[0] & 7;
        value |= (data[0] & 8) << 4;
        value |= (data[1] & 7) << 4;
        value |= data[5] & 8;
        return $"{address:X4}:{value:X2}";
    }

    static string? InvokeGameGenieEncodeNES(string raw)
    {
        try
        {
            var parts = raw.Split(':');
            if (parts.Length < 2) return null;
            int address = Convert.ToInt32(parts[0], 16);
            int value = Convert.ToInt32(parts[1], 16);
            int check = 0;
            bool haveCheck = parts.Length == 3;
            if (haveCheck) check = Convert.ToInt32(parts[2], 16);

            var data = new int[8];
            data[1] |= ((address >> 4) & 8);
            data[2] |= ((address >> 4) & 7);
            data[3] |= ((address >> 12) & 7);
            data[3] |= ((address >> 0) & 8);
            data[4] |= ((address >> 0) & 7);
            data[4] |= ((address >> 8) & 8);
            data[5] |= ((address >> 8) & 7);

            if (haveCheck)
            {
                data[0] |= (value >> 0) & 7;
                data[0] |= (value >> 4) & 8;
                data[1] |= (value >> 4) & 7;
                data[2] |= 8;
                data[7] |= (value >> 0) & 8;
                data[5] |= (check >> 0) & 8;
                data[6] |= (check >> 0) & 7;
                data[6] |= (check >> 4) & 8;
                data[7] |= (check >> 4) & 7;
            }
            else
            {
                data[0] |= (value >> 0) & 7;
                data[0] |= (value >> 4) & 8;
                data[1] |= (value >> 4) & 7;
                data[5] |= (value >> 0) & 8;
            }

            int len = haveCheck ? 8 : 6;
            var sb = new StringBuilder(len);
            for (int i = 0; i < len; i++) sb.Append(MapNesChar(data[i]));
            return sb.ToString();
        }
        catch { return null; }
    }

    // =========================================================================
    // EXPORTERS
    // =========================================================================
    void ExportKronos(string path)
    {
        using var fs = File.Create(path);
        using var w = new BinaryWriter(fs);
        w.Write(new byte[] { 0x59, 0x43, 0x48, 0x54, 0, 0, 0 });

        int total = CheatDatabase.Values.SelectMany(x => x.Codes).Count(c => Regex.IsMatch(c, @"^[Dd13][0-9A-Fa-f]{7}"));
        w.Write((byte)Math.Min(total, 255));

        foreach (var entry in VisibleEntries().Select(x => x.Value))
        {
            var name = Regex.Replace(entry.BaseDesc, @"[^\x20-\x7E]", "");
            if (name.Length > 255) name = name[..255];
            byte nameCount = (byte)(name.Length + 1);
            var nameBytes = Encoding.ASCII.GetBytes(name);

            foreach (var code in entry.Codes)
            {
                var parts = Regex.Split(code, @"\s+");
                if (parts.Length < 2) continue;
                var part1 = parts[0].ToUpperInvariant().PadRight(8, '0')[..8];
                var part2 = parts[1].ToUpperInvariant().PadRight(4, '0')[..4];
                var type = part1[0];
                if (type is not ('D' or '1' or '3')) continue;
                string typeStr = type switch { '3' => "02", '1' => "03", _ => "01" };
                string hex = "000000" + typeStr + "0" + part1[1..8] + "0000" + part2;
                var chunk = new byte[12];
                for (int i = 0; i < 12; i++) chunk[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
                w.Write(chunk);
                w.Write(nameCount);
                w.Write(nameBytes);
                w.Write(new byte[5]);
            }
        }
    }

    void ExportVbaClt(string path)
    {
        using var fs = File.Create(path);
        using var w = new BinaryWriter(fs);
        var maskMap = new Dictionary<char, byte>
        {
            ['0']=0xFF,['1']=0x70,['2']=0x21,['3']=0x00,['4']=0x09,['5']=0x24,['6']=0x0B,['7']=0x08,
            ['8']=0x01,['9']=0xFF,['A']=0x0A,['B']=0x23,['C']=0x22,['D']=0x07,['E']=0x20,['F']=0x32
        };
        int total = VisibleEntries().Sum(x => x.Value.Codes.Count);
        w.Write(1); w.Write(1); w.Write(total);

        foreach (var entry in VisibleEntries().Select(x => x.Value))
        {
            var safe = Regex.Replace(entry.BaseDesc, @"[^\x20-\x7E]", "");
            var descBytes = Encoding.ASCII.GetBytes(safe.PadRight(32, '\0')[..32]);
            int dataLinesRemaining = 0;
            bool slideNext = false;

            foreach (var codeItem in entry.Codes)
            {
                var parts = Regex.Split(codeItem, @"\s+");
                if (parts.Length < 2) continue;
                var part1 = parts[0].ToUpperInvariant().PadRight(8, '0')[..8];
                var part2 = parts[1].ToUpperInvariant().PadRight(4, '0')[..4];
                char ctyp = part1[0];

                var cd8Bytes = BitConverter.GetBytes(Convert.ToUInt32(part1, 16));
                var cd8zBytes = BitConverter.GetBytes(Convert.ToUInt32("0" + part1[1..], 16));
                var cd4Bytes = BitConverter.GetBytes(Convert.ToUInt16(part2, 16));

                bool multi = false;
                if (dataLinesRemaining > 0) { multi = true; dataLinesRemaining--; }
                else if (slideNext) { multi = true; slideNext = false; }

                byte mask = multi ? (byte)0xFF : maskMap.GetValueOrDefault(ctyp, (byte)0);
                if (mask == 0xFF) cd8zBytes = cd8Bytes;

                var codeBytes = Encoding.ASCII.GetBytes(codeItem.PadRight(20, '\0')[..20]);
                w.Write(new byte[] { 0, 2, 0, 0 });
                if (multi || ctyp is '0' or '9') w.Write(new byte[] { 0xFF, 0xFF, 0xFF, 0xFF });
                else { w.Write(mask); w.Write(new byte[] { 0, 0, 0 }); }
                w.Write(0); w.Write(0);
                w.Write(cd8Bytes); w.Write(cd8zBytes); w.Write(cd4Bytes);
                w.Write(new byte[6]); w.Write(codeBytes); w.Write(descBytes);

                if (!multi)
                {
                    if (ctyp == '5')
                    {
                        int halfwordCount = Convert.ToInt32(part2, 16);
                        dataLinesRemaining = (int)(Math.Floor(((halfwordCount - 1) & 0xFFFF) / 3.0) + 1);
                    }
                    else if (ctyp == '4') slideNext = true;
                }
            }
        }
    }

    void ExportSnes(string path)
    {
        var sb = new StringBuilder();
        foreach (var entry in VisibleEntries().Select(x => x.Value))
            foreach (var code in entry.Codes)
            {
                var output = code;
                if (output.Length == 8 && !output.Contains('-'))
                    output = output[..6] + "=" + output[6..8];
                sb.AppendLine($"cheat\n  name: {entry.BaseDesc}\n  code: {output}\n");
            }
        File.WriteAllText(path, sb.ToString(), Utf8Encoding);
    }

    void ExportTabDelimited(string path)
    {
        var sb = new StringBuilder();
        foreach (var entry in VisibleEntries().Select(x => x.Value))
            foreach (var code in entry.Codes)
                sb.AppendLine($"{code}\t{entry.BaseDesc}");
        File.WriteAllText(path, sb.ToString(), Utf8Encoding);
    }

    void ExportPcsxr(string path)
    {
        var sb = new StringBuilder();
        foreach (var entry in VisibleEntries().Select(x => x.Value))
        {
            if (entry.Codes.Count == 0) continue;
            sb.AppendLine($"[{entry.BaseDesc}]");
            foreach (var code in entry.Codes) sb.AppendLine(code);
        }
        File.WriteAllText(path, sb.ToString(), Utf8Encoding);
    }

    void ExportEpsxe(string path)
    {
        var sb = new StringBuilder();
        foreach (var entry in VisibleEntries().Select(x => x.Value))
        {
            if (entry.Codes.Count == 0) continue;
            sb.AppendLine($"#{entry.BaseDesc}");
            foreach (var code in entry.Codes) sb.AppendLine(code);
        }
        File.WriteAllText(path, sb.ToString(), Utf8Encoding);
    }

    void ExportGbc(string path)
    {
        using var fs = File.Create(path);
        using var w = new BinaryWriter(fs);
        int total = VisibleEntries().Sum(x => x.Value.Codes.Count);
        w.Write((byte)0); w.Write((byte)Math.Min(total, 255)); w.Write((byte)0);
        int processed = 0;

        foreach (var entry in VisibleEntries().Select(x => x.Value))
        {
            if (processed >= 255) break;
            var desc = Regex.Replace(entry.BaseDesc, @"[^\x20-\x7E]", "");
            var descBytes = Encoding.ASCII.GetBytes(desc);
            foreach (var code in entry.Codes)
            {
                if (processed >= 255) break;
                byte prefix = code.Contains('-') ? (byte)0x0b : (byte)0x08;
                var codeBytes = Encoding.ASCII.GetBytes(code);
                w.Write((byte)0); w.Write((byte)descBytes.Length); w.Write((byte)0);
                w.Write(descBytes); w.Write(prefix); w.Write(codeBytes);
                processed++;
            }
        }
    }

    void ExportMch(string path)
    {
        var sb = new StringBuilder("CAT Cheats\n");
        foreach (var entry in VisibleEntries().Select(x => x.Value))
        {
            sb.AppendLine($"CODE 0 {entry.BaseDesc}");
            foreach (var code in entry.Codes) sb.AppendLine(code);
        }
        File.WriteAllText(path, sb.ToString(), Utf8Encoding);
    }

    void ExportNes(string path)
    {
        var sb = new StringBuilder();
        foreach (var entry in VisibleEntries().Select(x => x.Value))
        {
            var cleanDesc = entry.BaseDesc.Trim();
            foreach (var codeItem in entry.Codes)
            {
                foreach (var subCode in codeItem.Split('+', StringSplitOptions.RemoveEmptyEntries))
                {
                    var raw = subCode.Trim().TrimStart(':');
                    if (raw.Length == 9 && Regex.IsMatch(raw, @"^[A-Z]{9}$")) raw = raw[1..];
                    if (Regex.IsMatch(raw, @"^[A-Z]{6}$|^[A-Z]{8}$"))
                        raw = InvokeGameGenieDecodeNES(raw) ?? raw;

                    var m = Regex.Match(raw, @"^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$");
                    if (m.Success)
                    {
                        string addr = m.Groups[1].Value, val = m.Groups[2].Value, cmp = m.Groups[3].Value;
                        bool high = Convert.ToInt32(addr, 16) >= 0x8000;
                        bool hasCompare = !string.IsNullOrEmpty(cmp);
                        string prefix = high ? (hasCompare ? "SC:" : "S:") : (hasCompare ? "C:" : ":");
                        string body = hasCompare ? $"{addr}:{val}:{cmp}" : $"{addr}:{val}";
                        sb.AppendLine($"{prefix}{body}:{cleanDesc}");
                    }
                    else
                    {
                        var fallback = raw.StartsWith(':') ? raw : ":" + raw;
                        sb.AppendLine($"{fallback}:{cleanDesc}");
                    }
                }
            }
        }
        File.WriteAllText(path, sb.ToString(), Utf8Encoding);
    }

    void ExportRetroArch(string path)
    {
        var entries = VisibleEntries().Select(x => x.Value).ToList();
        var sb = new StringBuilder();
        sb.AppendLine($"cheats = {entries.Count}");
        sb.AppendLine();
        for (int i = 0; i < entries.Count; i++)
        {
            var e = entries[i];
            sb.AppendLine($"cheat{i}_desc = \"{e.BaseDesc}\"");
            sb.AppendLine($"cheat{i}_code = \"{string.Join("+", e.Codes)}\"");
            sb.AppendLine($"cheat{i}_enable = false");
            sb.AppendLine();
        }
        File.WriteAllText(path, sb.ToString(), Utf8Encoding);
    }

    // =========================================================================
    // UI
    // =========================================================================
void BuildUi()
{
    var main = new Grid
    {
        RowDefinitions = new RowDefinitions($"{TopRowHeight},*,{TopRowHeight},{LogHeaderHeight},{LogHeight}"),
        Margin = new Thickness(14)
    };

    // --- Top Control Panel Bar ---
    // Ensure controls match height and vertical alignment explicitly
    cmbInputModule.Height = ControlHeight;
    cmbInputModule.VerticalAlignment = VerticalAlignment.Center;

    cmbTargetRegex.Height = ControlHeight;
    cmbTargetRegex.VerticalAlignment = VerticalAlignment.Center;

    btnImport.Height = ButtonHeight;
    btnImport.VerticalAlignment = VerticalAlignment.Center;
    btnImport.VerticalContentAlignment = VerticalAlignment.Center;

    var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    top.Children.Add(lblInput);
    top.Children.Add(cmbInputModule);
    top.Children.Add(btnImport);
    top.Children.Add(lblTargetRegex);
    top.Children.Add(cmbTargetRegex);
    Grid.SetRow(top, 0);
    main.Children.Add(top);

    // --- Middle Workspace (Split into Elevated Cards - 50/50 Split) ---
    var mid = new Grid
    {
        ColumnDefinitions = new ColumnDefinitions("*,12,*"),
        RowDefinitions = new RowDefinitions("Auto,*,42")
    };

    var leftHeader = new TextBlock { Text = "Grouped Cheat Descriptions:", FontWeight = FontWeight.SemiBold, Margin = new Thickness(2, 0, 0, 6) };
    var rightHeader = new TextBlock { Text = "Codes in Selected Group (One per line):", FontWeight = FontWeight.SemiBold, Margin = new Thickness(2, 0, 0, 6) };
    Grid.SetColumn(leftHeader, 0); Grid.SetRow(leftHeader, 0); mid.Children.Add(leftHeader);
    Grid.SetColumn(rightHeader, 2); Grid.SetRow(rightHeader, 0); mid.Children.Add(rightHeader);

    // Left Card Elevation
    lstCheats.SelectionMode = SelectionMode.Single;
    lstCheats.BorderThickness = new Thickness(0);
    lstCheats.Background = Brushes.Transparent;

    var leftCard = new Border
    {
        Background = Brushes.White,
        CornerRadius = new CornerRadius(6),
        BorderBrush = SolidColorBrush.Parse("#E0E0E0"),
        BorderThickness = new Thickness(1),
        BoxShadow = BoxShadows.Parse("0 4 12 0 #1A000000"),
        Padding = new Thickness(4),
        Child = lstCheats
    };
    Grid.SetColumn(leftCard, 0); Grid.SetRow(leftCard, 1); mid.Children.Add(leftCard);

    // Right Card Elevation
    txtEditor.AcceptsReturn = true;
    txtEditor.BorderThickness = new Thickness(0);
    txtEditor.Background = Brushes.Transparent;
    txtEditor.FontFamily = new FontFamily("monospace");
    txtEditor.FontSize = 13;
    ScrollViewer.SetVerticalScrollBarVisibility(txtEditor, ScrollBarVisibility.Auto);
    ScrollViewer.SetHorizontalScrollBarVisibility(txtEditor, ScrollBarVisibility.Auto);

    var rightCard = new Border
    {
        Background = Brushes.White,
        CornerRadius = new CornerRadius(6),
        BorderBrush = SolidColorBrush.Parse("#E0E0E0"),
        BorderThickness = new Thickness(1),
        BoxShadow = BoxShadows.Parse("0 4 12 0 #1A000000"),
        Padding = new Thickness(4),
        Child = txtEditor
    };
    Grid.SetColumn(rightCard, 2); Grid.SetRow(rightCard, 1); mid.Children.Add(rightCard);

    // Left Action Bar Controls
    var leftActions = new Grid
    {
        ColumnDefinitions = new ColumnDefinitions("*,44,32,32,32"),
        VerticalAlignment = VerticalAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Margin = new Thickness(0, 6, 0, 0)
    };
    txtNewGroup.HorizontalAlignment = HorizontalAlignment.Stretch;
    leftActions.Children.Add(txtNewGroup);
    Grid.SetColumn(btnNewGroup, 1); leftActions.Children.Add(btnNewGroup);
    Grid.SetColumn(btnMoveUp, 2); leftActions.Children.Add(btnMoveUp);
    Grid.SetColumn(btnMoveDown, 3); leftActions.Children.Add(btnMoveDown);
    Grid.SetColumn(btnDeleteGroup, 4); leftActions.Children.Add(btnDeleteGroup);
    Grid.SetColumn(leftActions, 0); Grid.SetRow(leftActions, 2); mid.Children.Add(leftActions);

    // Right Action Bar Controls
    btnSaveGroup.HorizontalAlignment = HorizontalAlignment.Stretch;
    btnSaveGroup.Width = double.NaN; // Matches rightCard width
    btnSaveGroup.Margin = new Thickness(0, 6, 0, 0);
    Grid.SetColumn(btnSaveGroup, 2); Grid.SetRow(btnSaveGroup, 2); mid.Children.Add(btnSaveGroup);

    Grid.SetRow(mid, 1); main.Children.Add(mid);

    // --- Export Row ---
    // Enforce matching height and alignment for btnExport and cmbOutputModule
    cmbOutputModule.Height = ControlHeight;
    cmbOutputModule.VerticalAlignment = VerticalAlignment.Center;

    btnExport.Height = ButtonHeight;
    btnExport.VerticalAlignment = VerticalAlignment.Center;
    btnExport.VerticalContentAlignment = VerticalAlignment.Center;

    var export = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    export.Children.Add(lblOutput);
    export.Children.Add(cmbOutputModule);
    export.Children.Add(btnExport);
    Grid.SetRow(export, 2); main.Children.Add(export);

    // --- Status Log Setup ---
    var logHeader = new TextBlock { Text = "System Activity Log:", FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    Grid.SetRow(logHeader, 3); main.Children.Add(logHeader);

    txtStatusLog.FontFamily = new FontFamily("monospace");
    txtStatusLog.FontSize = 11;
    txtStatusLog.TextWrapping = TextWrapping.Wrap;
    ScrollViewer.SetHorizontalScrollBarVisibility(txtStatusLog, ScrollBarVisibility.Disabled);
    ScrollViewer.SetVerticalScrollBarVisibility(txtStatusLog, ScrollBarVisibility.Auto);

    var logCard = new Border
    {
        Background = Brushes.White,
        CornerRadius = new CornerRadius(4),
        BorderBrush = SolidColorBrush.Parse("#E0E0E0"),
        BorderThickness = new Thickness(1),
        BoxShadow = BoxShadows.Parse("0 2 6 0 #0D000000"),
        Child = txtStatusLog
    };
    Grid.SetRow(logCard, 4); main.Children.Add(logCard);

    Content = main;

    foreach (var key in InputModules.Keys) cmbInputModule.Items.Add(key);
    foreach (var key in InputModules.Keys.Where(k => k != "RetroArch (Global)")) cmbTargetRegex.Items.Add(key);
    cmbTargetRegex.SelectedIndex = cmbTargetRegex.ItemCount > 0 ? 0 : -1;

    txtNewGroup.Foreground = Brushes.Gray;
    txtNewGroup.Watermark = "";
    cmbInputModule.VerticalContentAlignment = VerticalAlignment.Center;
    cmbTargetRegex.VerticalContentAlignment = VerticalAlignment.Center;
    cmbOutputModule.VerticalContentAlignment = VerticalAlignment.Center;
}

    void WireEvents()
    {
        cmbInputModule.SelectionChanged += (_, _) => UpdateOutputModuleChoices();
        cmbTargetRegex.SelectionChanged += (_, _) => UpdateOutputModuleChoices();

        txtEditor.TextChanged += (_, _) =>
        {
            if (!SuppressEvents) IsDirty = true;
        };

        txtNewGroup.GotFocus += (_, _) =>
        {
            if (placeholderActive)
            {
                placeholderActive = false;
                txtNewGroup.Text = "";
                txtNewGroup.Foreground = Brushes.Black;
            }
        };
        txtNewGroup.LostFocus += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(txtNewGroup.Text))
            {
                placeholderActive = true;
                txtNewGroup.Text = "New group name";
                txtNewGroup.Foreground = Brushes.Gray;
            }
        };
        txtNewGroup.KeyDown += async (_, e) =>
        {
            if (e.Key == Key.Enter)
            {
                e.Handled = true;
                await NewGroupAsync();
            }
        };

        lstCheats.SelectionChanged += async (_, _) => await ListSelectionChangedAsync();
        btnImport.Click += async (_, _) => await ImportClickedAsync();
        btnExport.Click += async (_, _) => await ExportClickedAsync();
        btnSaveGroup.Click += async (_, _) => await SaveCurrentGroupAsync(false);
        btnNewGroup.Click += async (_, _) => await NewGroupAsync();
        btnDeleteGroup.Click += async (_, _) => await DeleteGroupAsync();
        btnMoveUp.Click += async (_, _) => await MoveCheatGroupAsync(-1);
        btnMoveDown.Click += async (_, _) => await MoveCheatGroupAsync(1);
    }

    void UpdateOutputModuleChoices()
    {
        if (cmbInputModule.SelectedItem is not string selectedInput) return;
        cmbOutputModule.Items.Clear();

        const string retroArch = "RetroArch (.cht)";
        if (selectedInput == "RetroArch (Global)")
        {
            lblTargetRegex.IsVisible = true;
            cmbTargetRegex.IsVisible = true;
            cmbTargetRegex.IsEnabled = true;

            if (cmbTargetRegex.SelectedItem is string target &&
                ModuleOutputMap.TryGetValue(target, out var mapped) &&
                OutputModules.ContainsKey(mapped))
                cmbOutputModule.Items.Add(mapped);

            if (OutputModules.ContainsKey(retroArch) && !cmbOutputModule.Items.Contains(retroArch))
                cmbOutputModule.Items.Add(retroArch);

            cmbOutputModule.IsEnabled = true;
        }
        else
        {
            if (OutputModules.ContainsKey(retroArch)) cmbOutputModule.Items.Add(retroArch);
            if (ModuleOutputMap.TryGetValue(selectedInput, out var mapped) &&
                OutputModules.ContainsKey(mapped) && !cmbOutputModule.Items.Contains(mapped))
                cmbOutputModule.Items.Add(mapped);

            cmbOutputModule.IsEnabled = cmbOutputModule.ItemCount > 1;
            lblTargetRegex.IsVisible = false;
            cmbTargetRegex.IsVisible = false;
            cmbTargetRegex.IsEnabled = false;
        }

        if (cmbOutputModule.ItemCount > 0) cmbOutputModule.SelectedIndex = 0;
    }

    async Task ImportClickedAsync()
    {
        if (IsDirty)
        {
            var choice = await Dialogs.Message(this, "Discard unsaved changes?", "Unsaved Progress", DialogButtons.YesNo, DialogIcon.Warning);
            if (choice == DialogResult.No) return;
        }

        if (cmbInputModule.SelectedItem is not string selectedModule ||
            !InputModules.TryGetValue(selectedModule, out var module)) return;

        var openOptions = new FilePickerOpenOptions
        {
            Title = "Import Cheat File",
            AllowMultiple = false,
            FileTypeFilter = new[] { ToFileType(module.Filter, module.Name) }
        };
        if (Directory.Exists(LastDirectory))
            openOptions.SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(LastDirectory);
        var files = await StorageProvider.OpenFilePickerAsync(openOptions);
        if (files.Count == 0) return;

        var path = files[0].TryGetLocalPath();
        if (string.IsNullOrEmpty(path))
        {
            WriteLog("The selected file is not accessible as a local filesystem path.", "ERROR");
            return;
        }

        LastDirectory = Path.GetDirectoryName(path) ?? LastDirectory;
        try
        {
            CheatDatabase.Clear();
            string targetProfile = selectedModule == "RetroArch (Global)"
                ? cmbTargetRegex.SelectedItem?.ToString() ?? ""
                : selectedModule;

            Func<string, string, object?> parse = selectedModule == "RetroArch (Global)"
                ? (text, _) => module.Parse(text, targetProfile)
                : module.Parse;

            await module.Import(path, targetProfile, parse);
            RefreshCheatList();
            placeholderActive = true;
            txtNewGroup.Text = "New group name";
            txtNewGroup.Foreground = Brushes.Gray;
            WriteLog("Import operation finalized.");
        }
        catch (Exception ex)
        {
            WriteLog($"Parsing error encountered: {ex.Message}", "ERROR");
        }
    }

    async Task ExportClickedAsync()
    {
        if (CheatDatabase.Count == 0)
        {
            WriteLog("No structural configuration items inside current registry matrix to process.", "WARN");
            return;
        }
        if (cmbOutputModule.SelectedItem is not string selected || !OutputModules.TryGetValue(selected, out var module)) return;

        var fileType = ToFileType(module.Filter, module.Name);
        var suggested = "cheats" + SuggestedExtension(module.Filter);
        var saveOptions = new FilePickerSaveOptions
        {
            Title = "Export Cheat File",
            SuggestedFileName = suggested,
            FileTypeChoices = new[] { fileType },
            ShowOverwritePrompt = true
        };
        if (Directory.Exists(LastDirectory))
            saveOptions.SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(LastDirectory);
        var result = await StorageProvider.SaveFilePickerAsync(saveOptions);
        if (result == null) return;

        var path = result.TryGetLocalPath();
        if (string.IsNullOrEmpty(path))
        {
            WriteLog("The selected save location is not accessible as a local filesystem path.", "ERROR");
            return;
        }

        LastDirectory = Path.GetDirectoryName(path) ?? LastDirectory;
        try
        {
            await module.Export(path);
            WriteLog("Export operation executed successfully.");
        }
        catch (Exception ex)
        {
            WriteLog($"Export operational crash footprint: {ex.Message}", "ERROR");
        }
    }

    async Task<bool> SaveCurrentSelectionIfDirtyAsync()
    {
        if (!IsDirty || LastSelectedIndex < 0 || LastSelectedIndex >= lstCheats.ItemCount) return true;

        var choice = await Dialogs.Message(this,
            "Save changes to the current group before proceeding?",
            "Unsaved Progress", DialogButtons.YesNoCancel, DialogIcon.Warning);
        if (choice == DialogResult.Cancel) return false;

        if (choice == DialogResult.Yes)
            await SaveCurrentGroupAsync(true);
        else
            IsDirty = false;

        return true;
    }

    async Task ListSelectionChangedAsync()
    {
        if (SuppressEvents) return;
        int newIndex = lstCheats.SelectedIndex;
        if (newIndex == LastSelectedIndex) return;

        if (IsDirty && LastSelectedIndex >= 0 && LastSelectedIndex < lstCheats.ItemCount)
        {
            var choice = await Dialogs.Message(this, "Discard unsaved group modifications?", "Unsaved Progress",
                DialogButtons.YesNo, DialogIcon.Warning);
            if (choice == DialogResult.No)
            {
                SuppressEvents = true;
                lstCheats.SelectedIndex = LastSelectedIndex;
                SuppressEvents = false;
                return;
            }
        }

        if (newIndex < 0) return;
        LastSelectedIndex = newIndex;
        var entry = VisibleEntries().ElementAtOrDefault(newIndex).Value;
        if (entry == null) return;

        SuppressEvents = true;
        txtEditor.Text = string.Join(Environment.NewLine, entry.Codes);
        IsDirty = false;
        SuppressEvents = false;
    }

    async Task SaveCurrentGroupAsync(bool fromPrompt)
    {
        int idx = lstCheats.SelectedIndex;
        if (idx < 0) return;

        var entries = VisibleEntries().ToList();
        if (idx >= entries.Count) return;
        var targetKey = entries[idx].Key;
        var entry = entries[idx].Value;

        if (fromPrompt)
        {
            var rawLines = txtEditor.Text.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.RemoveEmptyEntries);
            entry.Codes = rawLines.Select(x => x.Trim().ToUpperInvariant()).ToList();
            CheatDatabase[targetKey] = entry;
            IsDirty = false;
            return;
        }

        string selectedInput = cmbInputModule.SelectedItem?.ToString() ?? "";
        string sysName = selectedInput == "RetroArch (Global)" ? cmbTargetRegex.SelectedItem?.ToString() ?? "" : selectedInput;
        string systemKey = SystemKey(sysName);

        var lines = txtEditor.Text.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.RemoveEmptyEntries);
        var updated = new List<string>();
        bool invalid = false;
        string? lockedFormat = null;

        foreach (var line in lines)
        {
            var clean = line.Trim().ToUpperInvariant();
            var parsed = InvokeSystemParser(systemKey, clean);
            if (parsed != null)
            {
                lockedFormat ??= parsed.Format;
                if (parsed.Format == lockedFormat) updated.Add(parsed.Code);
                else
                {
                    invalid = true;
                    WriteLog($"Line '{line}' rejected. Block locked to structure protocol dynamic rules.", "ERROR");
                }
            }
            else
            {
                invalid = true;
                WriteLog($"Line '{line}' tracking metric failure. Block syntax rejected.", "ERROR");
            }
        }

        lockedFormat ??= entry.Format;
        entry.Codes = updated;
        entry.Format = lockedFormat;
        var newKey = $"{entry.BaseDesc}:::{lockedFormat}";

        if (targetKey != newKey)
        {
            var ordered = CheatDatabase.ToList();
            CheatDatabase.Clear();
            foreach (var kv in ordered)
                CheatDatabase[kv.Key == targetKey ? newKey : kv.Key] = kv.Value;
        }
        else CheatDatabase[targetKey] = entry;

        SuppressEvents = true;
        txtEditor.Text = string.Join(Environment.NewLine, updated);
        SuppressEvents = false;
        IsDirty = false;
        RefreshCheatList(preserveIndex: idx);

        if (invalid)
            await Dialogs.Message(this,
                "Mismatched or invalid codes were detected and removed. A single block cannot mix different formats.",
                "Format Isolation Rule", DialogButtons.Ok, DialogIcon.Warning);
        else
            WriteLog($"Group '{entry.BaseDesc}' successfully updated as uniform '{lockedFormat}' format.");
    }

    async Task NewGroupAsync()
    {
        var newTitle = txtNewGroup.Text.Trim();
        if (string.IsNullOrWhiteSpace(newTitle) || newTitle == "New group name") return;
        if (!await SaveCurrentSelectionIfDirtyAsync()) return;

        string selectedInput = cmbInputModule.SelectedItem?.ToString() ?? "";
        string sysName = selectedInput == "RetroArch (Global)" ? cmbTargetRegex.SelectedItem?.ToString() ?? "" : selectedInput;
        string systemKey = SystemKey(sysName);

        string inherited = "Unknown";
        if (SystemCodePatterns.TryGetValue(systemKey, out var patterns) && patterns.Count > 0)
            inherited = patterns[0].Key;

        var key = $"{newTitle}:::{inherited}";
        if (!CheatDatabase.ContainsKey(key))
            CheatDatabase[key] = new CheatEntry { BaseDesc = newTitle, Format = inherited, Health = 1.0 };

        placeholderActive = true;
        txtNewGroup.Text = "New group name";
        txtNewGroup.Foreground = Brushes.Gray;

        RefreshCheatList();
        lstCheats.SelectedIndex = lstCheats.ItemCount - 1;
        LastSelectedIndex = lstCheats.SelectedIndex;
        SuppressEvents = true;
        txtEditor.Text = "";
        IsDirty = false;
        SuppressEvents = false;
        WriteLog($"Added new group '{newTitle}' with inherited format standard '{inherited}'.");
    }

    async Task DeleteGroupAsync()
    {
        int idx = lstCheats.SelectedIndex;
        if (idx < 0) return;
        var entries = VisibleEntries().ToList();
        if (idx >= entries.Count) return;

        var key = entries[idx].Key;
        var title = entries[idx].Value.BaseDesc;
        var choice = await Dialogs.Message(this, $"Delete group '{title}'?", "Confirm", DialogButtons.YesNo, DialogIcon.Warning);
        if (choice == DialogResult.No) return;

        CheatDatabase.Remove(key);
        IsDirty = false;
        RefreshCheatList(preserveIndex: Math.Min(idx, Math.Max(0, VisibleEntries().Count() - 1)));
        WriteLog($"Deleted group '{title}'.");
    }

    async Task MoveCheatGroupAsync(int direction)
    {
        int idx = lstCheats.SelectedIndex;
        if (idx < 0) return;
        int targetIdx = idx + direction;
        if (targetIdx < 0 || targetIdx >= lstCheats.ItemCount) return;
        if (!await SaveCurrentSelectionIfDirtyAsync()) return;

        var visible = VisibleEntries().ToList();
        if (idx >= visible.Count || targetIdx >= visible.Count) return;
        string k1 = visible[idx].Key, k2 = visible[targetIdx].Key;

        var all = CheatDatabase.ToList();
        int i1 = all.FindIndex(x => x.Key == k1), i2 = all.FindIndex(x => x.Key == k2);
        (all[i1], all[i2]) = (all[i2], all[i1]);

        CheatDatabase.Clear();
        foreach (var kv in all) CheatDatabase[kv.Key] = kv.Value;

        RefreshCheatList(preserveIndex: targetIdx);
    }

    void RefreshCheatList(int? preserveIndex = null)
    {
        SuppressEvents = true;
        lstCheats.Items.Clear();
        foreach (var kv in VisibleEntries()) lstCheats.Items.Add(kv.Value.BaseDesc);
        IsDirty = false;

        if (lstCheats.ItemCount > 0)
        {
            int idx = preserveIndex.HasValue ? Math.Clamp(preserveIndex.Value, 0, lstCheats.ItemCount - 1) : 0;
            LastSelectedIndex = idx;
            lstCheats.SelectedIndex = idx;
            var entry = VisibleEntries().ElementAt(idx).Value;
            txtEditor.Text = string.Join(Environment.NewLine, entry.Codes);
        }
        else
        {
            LastSelectedIndex = -1;
            txtEditor.Clear();
        }
        SuppressEvents = false;
        UpdateUiState();
    }

    void UpdateUiState()
    {
        bool has = lstCheats.ItemCount > 0;
        btnMoveUp.IsEnabled = has;
        btnMoveDown.IsEnabled = has;
        btnDeleteGroup.IsEnabled = has;
        btnSaveGroup.IsEnabled = has;
    }

    void WriteLog(string message, string level = "INFO")
    {
        var entry = $"[{DateTime.Now:HH:mm:ss}] [{level}] {message}";
        txtStatusLog.Text += entry + Environment.NewLine;
        txtStatusLog.CaretIndex = txtStatusLog.Text?.Length ?? 0;
    }

    static FilePickerFileType ToFileType(string filter, string name) =>
        new(name) { Patterns = ExtractPatterns(filter) };

    static string[] ExtractPatterns(string filter)
    {
        var parts = filter.Split('|');
        if (parts.Length < 2) return Array.Empty<string>();
        return parts[1].Split(';', StringSplitOptions.RemoveEmptyEntries);
    }

    static string SuggestedExtension(string filter)
    {
        var p = ExtractPatterns(filter).FirstOrDefault() ?? "";
        var dot = p.LastIndexOf('.');
        return dot >= 0 ? p[dot..] : "";
    }
}

// =============================================================================
// SIMPLE, SELF-CONTAINED AVALONIA MESSAGE BOX
// =============================================================================
public enum DialogButtons { Ok, YesNo, YesNoCancel }
public enum DialogResult { None, Ok, Yes, No, Cancel }
public enum DialogIcon { None, Question, Warning }

public static class Dialogs
{
    public static async Task<DialogResult> Message(Window owner, string message, string title,
        DialogButtons buttons, DialogIcon icon)
    {
        var win = new Window
        {
            Title = title,
            Width = 430,
            Height = buttons == DialogButtons.YesNoCancel ? 190 : 165,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
            ShowInTaskbar = false
        };

        var root = new Grid
        {
            RowDefinitions = new RowDefinitions("*,Auto"),
            Margin = new Thickness(18)
        };

        var text = new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetRow(text, 0);
        root.Children.Add(text);

        var buttonsPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8
        };

        DialogResult result = DialogResult.None;
        void Add(string caption, DialogResult r)
        {
            var b = new Button { Content = caption, MinWidth = 78, Height = 30 };
            b.Click += (_, _) => { result = r; win.Close(); };
            buttonsPanel.Children.Add(b);
        }

        if (buttons == DialogButtons.Ok) Add("OK", DialogResult.Ok);
        else
        {
            Add("Yes", DialogResult.Yes);
            Add("No", DialogResult.No);
            if (buttons == DialogButtons.YesNoCancel) Add("Cancel", DialogResult.Cancel);
        }

        Grid.SetRow(buttonsPanel, 1);
        root.Children.Add(buttonsPanel);
        win.Content = root;

        await win.ShowDialog(owner);
        return result;
    }
}

public sealed class App : Application
{
    public override void Initialize()
    {
        Styles.Add(new FluentTheme());

        // Target the internal Border inside the Button control template
        var buttonBorderStyle = new Style(x => x.OfType<Button>().Template().OfType<Border>());
        buttonBorderStyle.Setters.Add(new Setter(Border.CornerRadiusProperty, new CornerRadius(5)));
        buttonBorderStyle.Setters.Add(new Setter(Border.BoxShadowProperty, BoxShadows.Parse("0 2 4 0 #1A000000")));

        var hoverBorderStyle = new Style(x => x.OfType<Button>().Class(":pointerover").Template().OfType<Border>());
        hoverBorderStyle.Setters.Add(new Setter(Border.BoxShadowProperty, BoxShadows.Parse("0 4 8 0 #26000000")));

        var pressedBorderStyle = new Style(x => x.OfType<Button>().Class(":pressed").Template().OfType<Border>());
        pressedBorderStyle.Setters.Add(new Setter(Border.BoxShadowProperty, BoxShadows.Parse("0 1 2 0 #10000000")));

        // --- NEW: Disabled Button Border Styling (removes shadow when disabled) ---
        var disabledBorderStyle = new Style(x => x.OfType<Button>().Class(":disabled").Template().OfType<Border>());
        disabledBorderStyle.Setters.Add(new Setter(Border.BoxShadowProperty, new BoxShadows()));

        // Button surface styling
        var buttonStyle = new Style(x => x.OfType<Button>());
        buttonStyle.Setters.Add(new Setter(Button.BackgroundProperty, SolidColorBrush.Parse("#FAFAFA")));
        buttonStyle.Setters.Add(new Setter(Button.BorderBrushProperty, SolidColorBrush.Parse("#CCCCCC")));
        buttonStyle.Setters.Add(new Setter(Button.BorderThicknessProperty, new Thickness(1)));

        // --- NEW: Disabled Button Surface Styling (muted grey + flat transparency) ---
        var disabledButtonStyle = new Style(x => x.OfType<Button>().Class(":disabled"));
        disabledButtonStyle.Setters.Add(new Setter(Button.BackgroundProperty, SolidColorBrush.Parse("#EFEFEF")));
        disabledButtonStyle.Setters.Add(new Setter(Button.BorderBrushProperty, SolidColorBrush.Parse("#E0E0E0")));
        disabledButtonStyle.Setters.Add(new Setter(Button.ForegroundProperty, SolidColorBrush.Parse("#A0A0A0")));
        disabledButtonStyle.Setters.Add(new Setter(Button.OpacityProperty, 0.55));

        Styles.Add(buttonStyle);
        Styles.Add(buttonBorderStyle);
        Styles.Add(hoverBorderStyle);
        Styles.Add(pressedBorderStyle);
        Styles.Add(disabledButtonStyle);
        Styles.Add(disabledBorderStyle);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.MainWindow = new MainWindow();
        base.OnFrameworkInitializationCompleted();
    }
}

public static class Program
{
    [STAThread]
    public static void Main(string[] args) =>
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .LogToTrace();
}
