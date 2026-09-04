# wstart.nim
# Complete Nim port of wstart.py with Elastic Anchor Architecture & Behavioral Parity

# ==============================================================================
# WSTART ARCHITECTURAL INVARIANTS (DO NOT MODIFY)
# ==============================================================================
# 1. NATIVE EXECUTION WITH JIT PATH RESOLUTION:
#    External commands are launched directly with osproc.startProcess. For a
#    logical command name, the constructed child PATH is installed in the parent
#    process only for the duration of findExe(), then the resolved absolute path
#    is passed to startProcess. The caller's PATH is restored immediately after
#    resolution. Do not replace logical Wine/Proton command names in the engine.
#
# 2. SIGNATURE-BASED ANCHOR DISCOVERY:
#    xnexe() searches for the literal `wine` signature and derives xnbin from
#    the containing tree.  xnpfx is similarly derived from `system.reg`.
#    Once xnbin is established, PATH is constructed from xnbin/bin and
#    runtime tools such as `wine`, `wineserver`, and `winetricks` remain
#    logical command names so the engine resolves them through that PATH.
#    Explicit paths are used only where the Python reference explicitly
#    constructs one (for example the Proton runner and winecfg creation).
# ==============================================================================

import std/[algorithm, httpclient, json, os, osproc, posix, re, sequtils, sets, strtabs, strutils, tables, uri]
import pefile

const ForbiddenEnvVars = [
  "WINEARCH", "WINEDLLPATH", "WINEPREFIX",
  "STEAM_COMPAT_CLIENT_INSTALL_PATH", "STEAM_COMPAT_DATA_PATH"
]

proc homeDir(): string =
  getHomeDir().strip(leading = false, trailing = true, chars = {DirSep, AltSep})

proc expandHome(p: string): string =
  if p == "~": return homeDir()
  if p.startsWith("~/") or p.startsWith("~\\"):
    return homeDir() / p[2..^1]
  result = p

proc pathExists(p: string): bool =
  fileExists(p) or dirExists(p) or symlinkExists(p)

proc resolvePath(p: string): string =
  if p.len == 0: return ""
  let expanded = expandHome(p)
  try:
    result = normalizedPath(absolutePath(expanded))
  except CatchableError:
    result = expanded

proc physicalPath(p: string): string =
  result = resolvePath(p)
  if result.len == 0: return
  for _ in 0..<64:
    var probe = result
    var suffix: seq[string] = @[]
    var foundLink = false

    while true:
      if symlinkExists(probe):
        try:
          let target = expandSymlink(probe)
          var base = if isAbsolute(target): target else: parentDir(probe) / target
          base = normalizedPath(absolutePath(base))
          for part in reversed(suffix):
            base = base / part
          result = normalizedPath(base)
          foundLink = true
        except CatchableError:
          return
        break

      let parent = parentDir(probe)
      if parent == probe:
        break
      let name = extractFilename(probe)
      if name.len > 0:
        suffix.add(name)
      probe = parent

    if not foundLink:
      break

proc explicitExecutable(root, rel: string): string =
  result = root / rel

proc readText(path: string): string =
  try: result = readFile(path)
  except CatchableError: result = ""

proc jsonString(n: JsonNode; key, defaultValue: string): string =
  if n.kind == JObject and n.hasKey(key) and n[key].kind == JString:
    return n[key].getStr()
  defaultValue

proc jsonBool(n: JsonNode; key: string; defaultValue: bool): bool =
  if n.kind == JObject and n.hasKey(key) and n[key].kind == JBool:
    return n[key].getBool()
  defaultValue

proc jsonStringSeq(n: JsonNode; key: string): seq[string] =
  result = @[]
  if n.kind == JObject and n.hasKey(key):
    let a = n[key]
    if a.kind == JArray:
      for v in a.items:
        if v.kind == JString: result.add(v.getStr())

proc loadJson(path: string; defaultValue: JsonNode): JsonNode =
  if not fileExists(path):
    createDir(parentDir(path))
    try: writeFile(path, pretty(defaultValue))
    except CatchableError: discard
    return defaultValue
  try:
    result = parseJson(readFile(path))
    if result.kind == JObject and defaultValue.kind == JObject:
      for k, v in defaultValue.pairs:
        if not result.hasKey(k): result[k] = v
  except CatchableError:
    result = defaultValue

proc saveJson(path: string; data: JsonNode) =
  createDir(parentDir(path))
  try: writeFile(path, pretty(data))
  except CatchableError: discard

proc resolveArrayPaths(val: JsonNode): seq[string] =
  result = @[]
  if val.kind == JString:
    result.add(resolvePath(val.getStr()))
  elif val.kind == JArray:
    for p in val.items:
      if p.kind == JString: result.add(resolvePath(p.getStr()))

proc isFuseFs(path: string): bool =
  let mounts = "/proc/mounts"
  if not fileExists(mounts): return false
  let p = resolvePath(path)
  try:
    for line in readFile(mounts).splitLines():
      let parts = line.splitWhitespace()
      if parts.len >= 3 and parts[2].toLowerAscii().contains("fuse"):
        if p.startsWith(parts[1]): return true
  except CatchableError: discard
  false

proc mergedEnv(extra: Table[string, string]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  for k, v in extra:
    result[k] = v

proc parseAcfField(text, field: string): string =
  let pattern = re("""(?i)"$1"[ \t]+"([^"]+)""" % field)
  var matches: array[1, string]
  if text.find(pattern, matches) != -1:
    return matches[0]
  ""

type
  SlotConfig = object
    bin: string
    pfx: string
    args: seq[string]
    useWineLoader: bool
    hasWineLoader: bool
    cmd: string
    hasCmd: bool

  WStart = ref object
    cfg: JsonNode
    pmenu: seq[(string, string)]
    slots: Table[string, SlotConfig]
    arg1: string
    clprm: seq[string]
    mode: string
    slotNum: int
    hasSlot: bool
    xarg: string
    pntop: string
    pnapp: string
    xnbinList: seq[string]
    xnpfxList: seq[string]
    wnbin: string
    pnbin: string
    wnpfx: string
    pnpfx: string
    xnbin: string
    xnpfx: string
    dpth: (int, int)
    xstrt: string
    xnldl: string
    xndll: string
    xcmd: seq[string]
    env: Table[string, string]
    pedir: string
    xmrtn: string
    xflt: string
    hasTarget: bool
    useWineLoader: bool
    hasWineLoader: bool
    cachedCmd: string
    hasCachedCmd: bool

let configDir = homeDir() / ".config" / "wstart"
let configFile = configDir / "config.json"
let slotsFile = configDir / "slots.json"

proc defaultConfig(): JsonNode =
  %*{
    "wnbin": ["/usr", homeDir() / ".local" / "opt"],
    "wnpfx": [homeDir(), homeDir() / ".wineprefixes"],
    "pntop": homeDir() / ".steam",
    "pnapp": homeDir() / ".steam" / "steam" / "steamapps",
    "pnbin": [homeDir() / ".steam" / "steam" / "steamapps" / "common",
              homeDir() / ".local" / "share" / "Steam" / "steamapps" / "common"],
    "pnpfx": [homeDir() / ".steam" / "steam" / "steamapps" / "compatdata",
              homeDir() / ".local" / "share" / "Steam" / "steamapps" / "compatdata"],
    "pnpge": homeDir() / ".steam" / "root" / "compatibilitytools.d",
    "progs": "drive_c/Program Files",
    "stcmn": "Steam/steamapps/common",
    "desk": homeDir() / "Desktop",
    "icon": "applications-other",
    "temp": homeDir() / "Downloads",
    "pmenu": [["Command Prompt", "wineconsole.exe"],
              ["Control Panel", "control.exe"],
              ["Registry Editor", "regedit.exe"],
              ["Task Manager", "taskmgr.exe"],
              ["Windows Explorer", "explorer.exe"],
              ["Wine Configuration", "winecfg.exe"]]
  }

proc slotFromJson(n: JsonNode): SlotConfig =
  result.bin = jsonString(n, "bin", "")
  result.pfx = jsonString(n, "pfx", "")
  result.args = jsonStringSeq(n, "args")
  result.hasWineLoader = n.kind == JObject and n.hasKey("use_wine_loader")
  if result.hasWineLoader: result.useWineLoader = jsonBool(n, "use_wine_loader", false)
  result.hasCmd = n.kind == JObject and n.hasKey("cmd")
  if result.hasCmd: result.cmd = jsonString(n, "cmd", "")

proc slotToJson(s: SlotConfig): JsonNode =
  result = %*{"bin": s.bin, "pfx": s.pfx, "args": s.args}
  if s.hasWineLoader: result["use_wine_loader"] = newJBool(s.useWineLoader)
  if s.hasCmd: result["cmd"] = %s.cmd

proc saveSlots(w: WStart) =
  var o = newJObject()
  for k, v in w.slots: o[k] = slotToJson(v)
  saveJson(slotsFile, o)

proc clearScreen(w: WStart) =
  if execShellCmd("clear") != 0:
    stdout.write("\e[2J\e[3J\e[H")
    flushFile(stdout)

proc promptInput(w: WStart; p: string): string =
  try:
    stdout.write(p); flushFile(stdout)
    result = stdin.readLine().strip()
  except CatchableError:
    echo "\nExiting."
    quit(0)

proc resolveJitExecutable(executable: string; env: StringTableRef): (string, bool) =
  ## Resolve logical command names against the JIT-constructed PATH.
  if isAbsolute(executable) or executable.find(DirSep) >= 0 or executable.find(AltSep) >= 0:
    return (executable, fileExists(executable))

  let originalPath = getEnv("PATH")
  let hadPath = existsEnv("PATH")
  let childPath = env.getOrDefault("PATH", originalPath)

  try:
    putEnv("PATH", childPath)
    let resolved = findExe(executable)
    if resolved.len > 0:
      return (resolved, true)
    return (executable, false)
  finally:
    if hadPath:
      putEnv("PATH", originalPath)
    else:
      delEnv("PATH")

proc safeStart(w: WStart; cmd: seq[string]; env: StringTableRef; wait=false; quiet=false): bool =
  ## Start a command using Nim's normal process launcher.
  ## When `quiet` is true, output is temporarily redirected to /dev/null.
  if cmd.len == 0: return false

  let (executable, resolved) = resolveJitExecutable(cmd[0], env)
  if not resolved:
    stderr.writeLine("Command not found in constructed PATH: ", cmd[0])
    return false

  var args: seq[string] = @[]
  if cmd.len > 1:
    args = cmd[1..^1]

  var nullFd, savedStdout, savedStderr: cint = -1
  if quiet:
    nullFd = posix.open("/dev/null", O_WRONLY)
    if nullFd >= 0:
      savedStdout = posix.dup(1.cint)
      savedStderr = posix.dup(2.cint)
      discard posix.dup2(nullFd, 1.cint)
      discard posix.dup2(nullFd, 2.cint)

  try:
    let p = startProcess(executable, args = args, env = env, options = {poParentStreams})
    if wait:
      discard p.waitForExit()
      p.close()
    return true
  except CatchableError as e:
    stderr.writeLine("Error launching command '", executable, "': ", e.msg)
    return false
  finally:
    if quiet and nullFd >= 0:
      if savedStdout >= 0:
        discard posix.dup2(savedStdout, 1.cint)
        discard posix.close(savedStdout)
      if savedStderr >= 0:
        discard posix.dup2(savedStderr, 2.cint)
        discard posix.close(savedStderr)
      discard posix.close(nullFd)

proc usage(w: WStart; errMsg="") =
  let prog = extractFilename(paramStr(0))
  if errMsg.len > 0: stderr.writeLine("\n", prog, ": ERROR - ", errMsg)
  stderr.writeLine("\nusage: ", prog,
    "\n [-?a,--?add] [-?b,--?bld] [-?c,--?cmd] [-?d,--?dsk]",
    "\n [-?i,--?inf] [-?k,--?kil] [-?o,--?ovr] [-?p,--?prg]",
    "\n [-?s,--?stm] [-?t,--?trk] [-?u,--?cut] [-?v,--?ver]",
    "\n\n[?] = (p)roton, (w)ine",
    "\n (add) exe path to reg, (bld) build prefix,",
    "\n (cmd) prog menu, (dsk) desktop, (inf) exe info,",
    "\n (kil) kill wine, (ovr) overrides, (prg) exe list,",
    "\n (stm) steam, (trk) winetricks, (cut) shortcut,",
    "\n (ver) wine version\n")
  quit(if errMsg.len > 0: 1 else: 0)

proc displayMenu(w: WStart; options: seq[string]): string =
  var opts = options
  if "quit" notin opts: opts.add("quit")
  while true:
    for i, opt in opts: echo i + 1, ") ", opt
    let choice = w.promptInput("Please enter your choice: ")
    try:
      let n = parseInt(choice)
      if n >= 1 and n <= opts.len:
        if opts[n-1] == "quit": quit(0)
        w.clearScreen()
        return opts[n-1]
    except ValueError: discard

proc getMergedEnv(w: WStart): StringTableRef = mergedEnv(w.env)

proc initWStart(): WStart =
  result = WStart()
  for v in ForbiddenEnvVars: putEnv(v, "")
  for v in ForbiddenEnvVars: delEnv(v)
  let def = defaultConfig()
  result.cfg = loadJson(configFile, def)
  result.pmenu = @[]
  if result.cfg.hasKey("pmenu"):
    for pair in result.cfg["pmenu"].items:
      if pair.kind == JArray and pair.len >= 2: result.pmenu.add((pair[0].getStr(), pair[1].getStr()))

  result.slots = initTable[string, SlotConfig]()
  let rawSlots = loadJson(slotsFile, newJObject())
  if rawSlots.kind == JObject:
    for k, v in rawSlots.pairs: result.slots[k] = slotFromJson(v)

  result.arg1 = if paramCount() >= 1: paramStr(1) else: ""
  result.clprm = @[]
  if paramCount() >= 2:
    for i in 2..paramCount(): result.clprm.add(paramStr(i))

  result.mode = ""
  for i in 0..<result.arg1.len-1:
    if result.arg1[i] == '-' and result.arg1[i+1].toLowerAscii() in {'w', 'p'}:
      result.mode = $result.arg1[i+1].toLowerAscii()
      break

  result.hasSlot = false
  result.slotNum = 0
  if result.mode.len > 0:
    var idx = 0
    while idx < result.arg1.len - 1:
      if result.arg1[idx] == '-' and $result.arg1[idx+1].toLowerAscii() == result.mode:
        var j = idx + 2
        while j < result.arg1.len and result.arg1[j].isAlphaNumeric and not result.arg1[j].isDigit:
          inc j
        var digits = ""
        while j < result.arg1.len and result.arg1[j].isDigit:
          digits.add(result.arg1[j])
          inc j
        if digits.len > 0:
          result.slotNum = parseInt(digits)
          result.hasSlot = true
        break
      inc idx

  if result.mode.len > 0:
    result.xarg = result.arg1
    for i in 0..<result.xarg.len-1:
      if result.xarg[i] == '-' and $result.xarg[i+1].toLowerAscii() == result.mode:
        result.xarg[i+1] = 'x'
        break
  else:
    result.xarg = result.arg1
    while result.xarg.startsWith("-xx"): result.xarg = "-" & result.xarg[3..^1]

  result.pntop = resolvePath(jsonString(result.cfg, "pntop", "~/.steam"))
  let defaultPnapp = result.pntop / "steam" / "steamapps"
  result.pnapp = resolvePath(jsonString(result.cfg, "pnapp", defaultPnapp))

  let wnBins = resolveArrayPaths(result.cfg["wnbin"])
  let pnBins = resolveArrayPaths(result.cfg["pnbin"])
  let wnPfxs = resolveArrayPaths(result.cfg["wnpfx"])
  let pnPfxs = resolveArrayPaths(result.cfg["pnpfx"])

  result.wnbin = if wnBins.len > 0: wnBins[0] else: "/usr"
  result.pnbin = if pnBins.len > 0: pnBins[0] else: homeDir() / ".steam" / "steam" / "steamapps" / "common"
  result.wnpfx = if wnPfxs.len > 0: wnPfxs[0] else: homeDir() / ".wine"
  result.pnpfx = if pnPfxs.len > 0: pnPfxs[0] else: homeDir() / ".steam" / "steam" / "steamapps" / "compatdata"

  if result.mode == "p":
    result.xnbinList = pnBins
    result.xnpfxList = pnPfxs
    result.dpth = (4, 3)
  else:
    result.xnbinList = wnBins
    result.xnpfxList = wnPfxs
    result.dpth = (3, 2)

  result.xstrt = "wine"
  result.env = initTable[string, string]()
  result.xcmd = @[]

proc xnint(w: WStart) =
  if w.mode == "p":
    w.xnbin = ""
    w.xnpfx = w.pnpfx
    w.dpth = (4, 3)
  else:
    w.xnbin = ""
    w.xnpfx = w.wnpfx
    w.dpth = (3, 2)

proc xn64(w: WStart) =
  let wine64Bin = if w.xnbin.len > 0: w.xnbin / "bin" / "wine64" else: "/bin/wine64"
  w.xstrt = if fileExists(wine64Bin): "wine64" else: "wine"
  if w.xnbin.len > 0:
    w.xnldl = w.xnbin / "lib64" & ":" & w.xnbin / "lib"
    w.xndll = w.xnbin / "lib64/wine" & ":" & w.xnbin / "lib/wine"
  else:
    w.xnldl = ""
    w.xndll = ""

proc xn32(w: WStart) =
  w.xstrt = "wine"
  if w.xnbin.len > 0:
    w.xnldl = w.xnbin / "lib"
    w.xndll = w.xnbin / "lib/wine"
  else:
    w.xnldl = ""
    w.xndll = ""

proc xnexe(w: WStart) =
  var found: seq[(string, string)] = @[]
  let dpthBin = w.dpth[0]
  var visitedDirs = initHashSet[string]()

  proc getRealPath(p: string): string =
    physicalPath(p)

  for root in w.xnbinList:
    if not dirExists(root): continue

    proc walkBin(currentDir: string, rootDir: string) =
      let realPath = getRealPath(currentDir)
      if realPath in visitedDirs:
        return
      visitedDirs.incl(realPath)

      let rel = relativePath(currentDir, rootDir)
      let isInsideRoot = rel != "." and not rel.startsWith("..") and not isAbsolute(rel)
      let relDepth = if not isInsideRoot: 0 else: rel.split({DirSep, AltSep}).len

      if relDepth >= dpthBin: return
      if "sbin" in currentDir.split({DirSep, AltSep}): return

      try:
        var subDirs: seq[string] = @[]
        for kind, path in walkDir(currentDir, relative=false):
          if kind in {pcDir, pcLinkToDir}:
            subDirs.add(path)
          elif kind in {pcFile, pcLinkToFile}:
            if extractFilename(path).toLowerAscii() == "wine":
              let baseName = extractFilename(currentDir)
              let wineRoot = if baseName.toLowerAscii() == "bin": parentDir(currentDir) else: currentDir
              let rWine = relativePath(wineRoot, rootDir)
              let relWine = if rWine == "." or rWine.startsWith("..") or isAbsolute(rWine):
                              extractFilename(rootDir)
                            else:
                              rWine
              found.add((relWine, wineRoot))
        for d in subDirs:
          walkBin(d, rootDir)
      except CatchableError:
        discard

    walkBin(root, root)

  var pathMap = initTable[string, (string, string)]()
  for (label, path) in found:
    let identity = physicalPath(path)
    if identity notin pathMap:
      pathMap[identity] = (label, path)

  var labelCounts = initCountTable[string]()
  for _, entry in pathMap:
    labelCounts.inc(entry[0])

  var uniqueOpts = initTable[string, string]()
  for _, entry in pathMap:
    let label = entry[0]
    let path = entry[1]
    var displayLabel = label
    if labelCounts[label] > 1:
      displayLabel = label & " (" & parentDir(path) & ")"
    uniqueOpts[displayLabel] = path

  if uniqueOpts.len > 1:
    var keys = toSeq(uniqueOpts.keys)
    keys.sort()
    let sel = w.displayMenu(keys)
    w.xnbin = uniqueOpts[sel]
  elif uniqueOpts.len == 1:
    for _, p in uniqueOpts:
      w.xnbin = p
  else:
    stderr.writeLine("No installed Wine/Proton found.")
    quit(1)

proc getProtonAppMap(w: WStart; valid: seq[string]): Table[string, string] =
  result = initTable[string, string]()
  if not dirExists(w.pnapp): return
  for mf in walkFiles(w.pnapp / "appmanifest_*.acf"):
    let txt = readText(mf)
    let appid = parseAcfField(txt, "appid")
    let name = parseAcfField(txt, "name")
    if appid.len > 0 and name.len > 0 and (valid.len == 0 or appid in valid): result[appid] = name

proc xnpre(w: WStart) =
  var searchRoots = if w.xnpfxList.len > 0: w.xnpfxList else: @[w.wnpfx]
  var foundPfx: seq[(string, string)] = @[]
  let dpthPfx = w.dpth[1]

  for pfxRoot in searchRoots:
    if not dirExists(pfxRoot): continue

    proc walkPfx(currentDir: string, root: string) =
      let rel = if currentDir.startsWith(root):
                  currentDir[root.len..^1].strip(chars={DirSep, AltSep})
                else: ""
      let relDepth = if rel.len == 0: 0 else: rel.split({DirSep, AltSep}).len
      if relDepth > dpthPfx: return

      try:
        var subDirs: seq[string] = @[]
        for kind, path in walkDir(currentDir, relative=false):
          if kind == pcDir:
            subDirs.add(path)
          elif kind in {pcFile, pcLinkToFile}:
            if extractFilename(path).toLowerAscii() == "system.reg":
              let relStr = if currentDir == root or not currentDir.startsWith(root):
                             extractFilename(root)
                           else:
                             let r = currentDir[root.len..^1].strip(chars={DirSep, AltSep})
                             if r.len == 0: extractFilename(root) else: r
              foundPfx.add((relStr, currentDir))
        for d in subDirs:
          walkPfx(d, root)
      except CatchableError: discard

    walkPfx(pfxRoot, pfxRoot)

  var pfxPathMap = initTable[string, (string, string)]()
  for (label, fullPath) in foundPfx:
    let identity = physicalPath(fullPath)
    if identity notin pfxPathMap:
      pfxPathMap[identity] = (label, fullPath)

  var labelCounts = initCountTable[string]()
  for _, entry in pfxPathMap:
    labelCounts.inc(entry[0])

  var uniquePfx = initTable[string, string]()
  for _, entry in pfxPathMap:
    let label = entry[0]
    let path = entry[1]
    var displayLabel = label
    if labelCounts[label] > 1:
      displayLabel = label & " (" & parentDir(path) & ")"
    uniquePfx[displayLabel] = path

  if uniquePfx.len > 1:
    if w.mode == "p":
      var pfxAppIds: seq[string] = @[]
      for _, entry in pfxPathMap:
        let first = entry[0].split({DirSep, AltSep})[0]
        if first notin pfxAppIds: pfxAppIds.add(first)
      let amap = w.getProtonAppMap(pfxAppIds)
      var amapKeys = toSeq(amap.keys)
      amapKeys.sort(proc(a, b: string): int =
        try: cmp(parseInt(a), parseInt(b))
        except ValueError: cmp(a, b)
      )
      for id in amapKeys: echo id, "  ", amap[id]
    var labels = toSeq(uniquePfx.keys)
    labels.sort()
    let sel = w.displayMenu(labels)
    w.xnpfx = uniquePfx[sel]
  elif uniquePfx.len == 1:
    for _, p in uniquePfx:
      w.xnpfx = p

  if w.mode == "p" and w.xnpfx.len > 0:
    if extractFilename(w.xnpfx) != "pfx" and dirExists(w.xnpfx / "pfx"):
      w.xnpfx = w.xnpfx / "pfx"

  if w.xnpfx.len > 0 and dirExists(w.xnpfx / "drive_c" / "windows" / "syswow64"):
    w.xn64()
  else:
    w.xn32()

proc xndef(w: WStart) =
  if w.xnbin.len == 0: return
  if w.mode == "p":
    let pfx0 = (if w.xnpfxList.len > 0: w.xnpfxList[0] else: w.pnpfx) / "0"
    if not dirExists(pfx0):
      echo "Creating default prefix: ", pfx0
      createDir(pfx0)
      w.env["STEAM_COMPAT_DATA_PATH"] = pfx0
      let proton = explicitExecutable(parentDir(w.xnbin), "proton")
      discard w.safeStart(@[proton, "run"], w.getMergedEnv(), wait=false, quiet=true)
    w.xnpfx = pfx0 / "pfx"
  else:
    let defaultPfx = if extractFilename(w.wnpfx) == ".wine": w.wnpfx else: w.wnpfx / ".wine"
    if not dirExists(defaultPfx):
      echo "Creating default prefix: ", defaultPfx
      createDir(defaultPfx)
      w.env["WINEPREFIX"] = defaultPfx
      let winecfgBin = w.xnbin / "bin" / "winecfg"
      discard w.safeStart(@[winecfgBin], w.getMergedEnv(), wait=false, quiet=true)
      let homeWine = homeDir() / ".wine"
      if pathExists(homeWine) and homeWine != defaultPfx:
        if fileExists(homeWine) or symlinkExists(homeWine): removeFile(homeWine)
        else: removeDir(homeWine)
        createSymlink(defaultPfx, homeWine)
    w.xnpfx = defaultPfx

proc xnenv(w: WStart) =
  let oldPath = getEnv("PATH")
  let binPath = if w.xnbin.len > 0: w.xnbin / "bin" else: ""
  w.env["PATH"] = if binPath.len > 0: binPath & ":" & oldPath else: oldPath
  w.env["WINEDLLPATH"] = w.xndll
  w.env["LD_LIBRARY_PATH"] = w.xnldl
  w.env["WINEPREFIX"] = w.xnpfx
  if w.mode == "p" and w.xnpfx.len > 0:
    let compat = if extractFilename(w.xnpfx) == "pfx": parentDir(w.xnpfx) else: w.xnpfx
    w.env["STEAM_COMPAT_DATA_PATH"] = compat
    w.env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = w.pntop

proc xnldr(w: WStart) =
  if w.mode == "p":
    if not w.hasWineLoader:
      let ch = w.promptInput("wine loader? [y/N] ").toLowerAscii()
      w.useWineLoader = ch in ["y", "yes"]; w.hasWineLoader = true
      let key = if w.hasSlot: w.mode & "_" & $w.slotNum else: ""
      if key.len > 0 and w.slots.hasKey(key):
        var s = w.slots[key]; s.useWineLoader = w.useWineLoader; s.hasWineLoader = true; w.slots[key] = s; w.saveSlots()
    if w.useWineLoader:
      w.xcmd.add(w.xstrt)
    else:
      let proton = if w.xnbin.len > 0: explicitExecutable(parentDir(w.xnbin), "proton") else: "proton"
      w.xcmd.add(proton); w.xcmd.add("run")
  else:
    w.xcmd.add(w.xstrt)

proc xnset(w: WStart) =
  w.xnint(); w.xnexe(); w.xndef(); w.xnpre(); w.xnenv()

proc xlyt(w: WStart) =
  if not w.hasTarget or w.xnpfx.len == 0:
    return

  let exePath = absolutePath(w.pedir / w.xmrtn)
  try:
    let pe = loadPEFile(exePath)
    if not pe.is64bit and dirExists(w.xnpfx / "drive_c" / "windows" / "syswow64"):
      w.xn32()
      w.xnenv()
  except CatchableError:
    discard
  except Defect:
    discard

  w.xnldr()
  var extraArgs = w.clprm
  if extraArgs.len > 0 and pathExists(expandHome(extraArgs[0])):
    extraArgs = extraArgs[1..^1]
  w.xcmd.add(exePath)
  for arg in extraArgs:
    w.xcmd.add(arg)

proc applySlotConfig(w: WStart) =
  let key = if w.hasSlot: w.mode & "_" & $w.slotNum else: ""
  if w.hasSlot and w.slotNum == 0:
    var deleted = false
    for k in toSeq(w.slots.keys):
      if k.startsWith(w.mode & "_"): w.slots.del(k); deleted = true
    if deleted:
      w.saveSlots(); echo "Cleared slot configuration for mode '", w.mode, "'."
    w.xnset(); return
  if key.len > 0 and w.slots.hasKey(key):
    let s = w.slots[key]
    if pathExists(s.bin) and dirExists(s.pfx):
      w.xnbin = s.bin; w.xnpfx = s.pfx
      if s.hasWineLoader: w.useWineLoader = s.useWineLoader; w.hasWineLoader = true
      if s.hasCmd: w.cachedCmd = s.cmd; w.hasCachedCmd = true
      var resolvedCliArgs: seq[string] = @[]
      for arg in w.clprm:
        let expanded = expandHome(arg)
        if pathExists(expanded): resolvedCliArgs.add(resolvePath(expanded))
        else: resolvedCliArgs.add(arg)
      w.clprm = s.args & resolvedCliArgs
      if dirExists(w.xnpfx / "drive_c" / "windows" / "syswow64"): w.xn64() else: w.xn32()
      w.xnenv(); return
  w.xnset()
  if key.len > 0 and w.slotNum > 0:
    var s = SlotConfig(
      bin: (if w.xnbin.len > 0: w.xnbin else: ""),
      pfx: (if w.xnpfx.len > 0: w.xnpfx else: ""),
      args: w.clprm,
      useWineLoader: w.useWineLoader,
      hasWineLoader: w.hasWineLoader,
      cmd: "",
      hasCmd: false
    )
    w.slots[key] = s; w.saveSlots()

proc launchProcess(w: WStart) =
  let dbg = w.env.getOrDefault("dbg", getEnv("dbg"))
  var e = w.getMergedEnv()

  if dbg.len == 0:
    discard w.safeStart(w.xcmd, e, wait=false, quiet=true)
  else:
    if dbg == "2":
      e["WINEDEBUG"] = "warn+all"

    var parts: seq[string] = @[]
    for k, v in w.env:
      parts.add(k & "=" & quoteShell(v))

    let cmdString = w.xcmd.mapIt(quoteShell(it)).join(" ")
    let full = if parts.len > 0: "env " & parts.join(" ") & " " & cmdString else: cmdString
    echo full

    if dbg == "1" or dbg == "2":
      discard w.safeStart(w.xcmd, e, wait=false, quiet=false)

proc validGuiExe(path: string): bool =
  try:
    let pe = loadPEFile(path)
    let subsystem = if pe.is64bit: pe.optionalHeader64.subsystem
                    else: pe.optionalHeader32.subsystem
    if subsystem != 2:
      return false

    let resDir = pe.getDataDirectory(2)
    if resDir.virtualAddress == 0 or resDir.size == 0:
      return false
    let resOffset = pe.rvaToFileOffset(resDir.virtualAddress)
    if resOffset == 0 or resOffset.int + 16 > pe.data.len:
      return false

    let head = pe.readDataAt(resOffset, 16)
    let named = int(head[12]) or (int(head[13]) shl 8)
    let ids = int(head[14]) or (int(head[15]) shl 8)
    let total = named + ids
    var off = resOffset + 16'u32
    for _ in 0..<total:
      if off.int + 8 > pe.data.len: return false
      let entry = pe.readDataAt(off, 8)
      let nameOrId = uint32(entry[0]) or (uint32(entry[1]) shl 8) or
                     (uint32(entry[2]) shl 16) or (uint32(entry[3]) shl 24)
      if (nameOrId and 0x80000000'u32) == 0:
        let id = nameOrId and 0xFFFF'u32
        if id == 3'u32 or id == 14'u32: return true
      off += 8'u32
    false
  except CatchableError:
    false
  except Defect:
    false

proc findExecutables(w: WStart; searchPath: string; filtered=true): seq[string] =
  result = @[]
  if not dirExists(searchPath): return

  let skipPe = isFuseFs(searchPath)
  let skipDirs = ["cache", "microsoft", "windows", "temp"]
  let bad = re"(?i).*(capture|clokspl|helper|iexplore|install|internal|kernel|[^ ]launcher|legacypm|overlay|proxy|redist|renderer|(crash|error)reporter|serv(er|ice)|setup|streaming|tutorial|unins|update).*"
  let extPattern = (if w.xflt.len > 0: w.xflt else: "*.exe").replace("*", "").toLowerAscii()

  var queue: seq[(string, int)] = @[(searchPath, 0)]
  var head = 0
  while head < queue.len:
    let (currentDir, depth) = queue[head]
    inc head
    if depth >= 7: continue

    if filtered:
      let lowDir = currentDir.toLowerAscii()
      var skip = false
      for token in skipDirs:
        if token in lowDir:
          skip = true
          break
      if skip: continue

    try:
      for kind, path in walkDir(currentDir, relative=false):
        case kind
        of pcDir:
          queue.add((path, depth + 1))
        of pcFile, pcLinkToFile:
          let name = extractFilename(path)
          if extPattern.len == 0 or not name.toLowerAscii().endsWith(extPattern):
            continue
          if filtered and name.match(bad): continue
          if w.xflt.len == 0 and not skipPe and not validGuiExe(path): continue
          let relFile = if path.startsWith(searchPath):
              path[searchPath.len..^1].strip(chars={DirSep, AltSep})
            else:
              extractFilename(path)
          if relFile.len > 0: result.add(relFile)
        else:
          discard
    except CatchableError:
      discard

  result.sort()

proc xpmn(w: WStart) =
  if w.clprm.len > 0 and pathExists(expandHome(w.clprm[0])):
    let target = resolvePath(w.clprm[0])
    if fileExists(target):
      w.pedir = absolutePath(parentDir(target))
      w.xmrtn = extractFilename(target)
      w.hasTarget = true
    elif dirExists(target):
      w.pedir = absolutePath(target)
      let exes = w.findExecutables(w.pedir, false)
      if exes.len > 0:
        w.xmrtn = w.displayMenu(exes)
        w.hasTarget = true
  else:
    w.pedir = if w.xnpfx.len > 0: w.xnpfx / "drive_c" else: homeDir() / ".wine" / "drive_c"
    let exes = w.findExecutables(w.pedir, true)
    if exes.len > 0:
      w.xmrtn = w.displayMenu(exes)
      w.hasTarget = true

proc handleAddToPath(w: WStart) =
  w.xnint(); w.xnpre(); w.xpmn()
  if not w.hasTarget or w.xnpfx.len == 0: return

  let targetDir = if w.xmrtn.len > 0: parentDir(w.pedir / w.xmrtn) else: w.pedir
  let ptadd = ("z:" & targetDir).replace("/", "\\")
  let escapedPtadd = ptadd.replace("\\", "\\\\")
  let isSystem = w.promptInput("prepend to system path? [y/N] ").toLowerAscii() in ["y", "yes"]
  w.clearScreen()

  let regFile = if isSystem: "system.reg" else: "user.reg"
  let printPrefix = if isSystem: "HKLM\\" else: "HKCU\\"
  let defaultSection = if isSystem: "System\\ControlSet001\\Control\\Session Manager\\Environment" else: "Environment"
  let regPath = w.xnpfx / regFile
  if not fileExists(regPath): echo "Registry file missing: ", regPath; return

  let rawContent = readFile(regPath)
  let nl = if rawContent.contains("\r\n"): "\r\n" else: "\n"
  let lines = rawContent.splitLines()
  var newLines: seq[string] = @[]
  var inTarget = false
  var pathFound = false
  var sectionFound = false
  var displaySection = defaultSection

  for line in lines:
    let s = line.strip()
    if s.startsWith("["):
      if inTarget and not pathFound:
        newLines.add("\"PATH\"=str(2):\"" & escapedPtadd & "\"")
        echo printPrefix, displaySection, ":\n\n  ", ptadd, "\n\nPATH created successfully\n"
        pathFound = true

      let closeIdx = s.find(']')
      if closeIdx > 1:
        var norm = s[1 ..< closeIdx].replace("\\", "/").toLowerAscii()
        while "//" in norm: norm = norm.replace("//", "/")

        if isSystem:
          inTarget = norm.contains("system") and norm.contains("controlset") and norm.contains("control") and norm.contains("session manager") and norm.contains("environment")
          if inTarget: displaySection = s[1 ..< closeIdx].replace("\\\\", "\\")
        else:
          inTarget = norm == "environment"
          if inTarget: displaySection = "Environment"

        if inTarget: sectionFound = true
      else:
        inTarget = false

    elif inTarget and not pathFound and s.toUpperAscii().startsWith("\"PATH\""):
      let eqPos = s.find("=str(2):")
      if eqPos >= 0:
        let firstQuote = s.find('"', eqPos + 8)
        let lastQuote = if firstQuote >= 0: s.find('"', firstQuote + 1) else: -1
        if firstQuote >= 0 and lastQuote > firstQuote:
          let currentPath = s[firstQuote + 1 ..< lastQuote]
          let normCurrent = currentPath.toLowerAscii().replace("\\\\", "\\")
          let normPtadd = ptadd.toLowerAscii()
          if normPtadd in normCurrent:
            echo printPrefix, displaySection, ":\n\n  ", ptadd, "\n\nalready in PATH\n"
            newLines.add(line)
          else:
            let newPath = if currentPath.len > 0: escapedPtadd & ";" & currentPath else: escapedPtadd
            newLines.add("\"PATH\"=str(2):\"" & newPath & "\"")
            echo printPrefix, displaySection, ":\n\n  ", ptadd, "\n\nPATH added successfully\n"
          pathFound = true
          continue
    newLines.add(line)

  if inTarget and not pathFound:
    newLines.add("\"PATH\"=str(2):\"" & escapedPtadd & "\"")
    echo printPrefix, displaySection, ":\n\n  ", ptadd, "\n\nPATH created successfully\n"
  if not sectionFound:
    newLines.add("")
    newLines.add("[" & displaySection.replace("\\", "\\\\") & "]")
    newLines.add("\"PATH\"=str(2):\"" & escapedPtadd & "\"")
    echo printPrefix, displaySection, ":\n\n  ", ptadd, "\n\nPATH created successfully\n"
  writeFile(regPath, newLines.join(nl) & nl)

proc handleBuildPrefix(w: WStart) =
  if w.clprm.len == 0 or w.clprm[0].len == 0:
    echo "Wine/Proton prefix name required: (e.g. .wine, 0 )"
    return
  let prefixArg = w.clprm[0]
  let targetPfx = if prefixArg.startsWith("/") or prefixArg.startsWith("~"):
                    resolvePath(prefixArg)
                  else:
                    (if w.mode == "p": w.pnpfx else: w.wnpfx) / prefixArg
  w.xnint()
  w.xnpfx = targetPfx
  if pathExists(targetPfx):
    echo "Wine/Proton Prefix exists: ", targetPfx
    return
  w.xnexe()
  echo "Creating Wine/Proton Prefix: ", prefixArg
  if w.mode == "p":
    createDir(targetPfx)
    w.xnpfx = targetPfx / "pfx"
    w.xnenv()
    let proton = explicitExecutable(parentDir(w.xnbin), "proton")
    w.xcmd = @[proton, "run"]
  else:
    let chse = w.promptInput("32-bit only? [y/N] ").toLowerAscii()
    if chse in ["y", "yes"]:
      w.xn32(); w.xnenv(); w.env["WINEARCH"] = "win32"
    else:
      w.xn64(); w.xnenv(); w.env["WINEARCH"] = "win64"
    w.xcmd = @[w.xstrt, "winecfg.exe"]
  w.launchProcess()

proc splitCommand*(s: string): seq[string] =
  var res: seq[string] = @[]
  var cur = ""
  var inQuote = false
  var quoteChar = '\0'
  var esc = false

  for i in 0 ..< s.len:
    let c = s[i]
    if esc:
      cur.add(c)
      esc = false
    elif inQuote:
      if c == quoteChar:
        inQuote = false
      elif c == '\\' and i + 1 < s.len and s[i + 1] == quoteChar:
        esc = true
      else:
        cur.add(c)
    elif c == '\\':
      if i + 1 < s.len and s[i + 1] in {' ', '\t', '"', '\''}:
        esc = true
      else:
        cur.add('\\')
    elif c in {'"', '\''}:
      inQuote = true
      quoteChar = c
    elif c in {' ', '\t'}:
      if cur.len > 0:
        res.add(cur)
        cur = ""
    else:
      cur.add(c)

  if cur.len > 0:
    res.add(cur)
  return res

proc handleProgramMenu(w: WStart) =
  w.applySlotConfig()
  var target = if w.hasCachedCmd: w.cachedCmd else: ""
  if target.len == 0:
    var labels: seq[string] = @[]
    for m in w.pmenu: labels.add(m[0])
    let sel = w.displayMenu(labels)
    for m in w.pmenu:
      if m[0] == sel: target = m[1]
    let key = if w.hasSlot: w.mode & "_" & $w.slotNum else: ""
    if key.len > 0 and w.slots.hasKey(key):
      var s = w.slots[key]; s.cmd = target; s.hasCmd = true; w.slots[key] = s; w.saveSlots()
  w.xnldr()
  var resolvedClprm: seq[string] = @[]
  for p in w.clprm: resolvedClprm.add(expandHome(p))
  let cmdArgs = splitCommand(target)
  if resolvedClprm.len > 0 and fileExists(resolvedClprm[0]):
    let targetFile = resolvePath(resolvedClprm[0])
    setCurrentDir(parentDir(targetFile))
    w.xcmd.add(cmdArgs)
    w.xcmd.add(targetFile)
    if resolvedClprm.len > 1:
      w.xcmd.add(resolvedClprm[1..^1])
  else:
    w.xcmd.add(cmdArgs)
    w.xcmd.add(resolvedClprm)
  w.launchProcess()

proc handleDesktop(w: WStart) =
  w.applySlotConfig(); w.xnldr(); w.xcmd.add("explorer.exe"); w.xcmd.add("/desktop=shell,1024x768"); w.xcmd.add("explorer.exe"); w.launchProcess()

proc handleProtonGE(w: WStart) =
  let pnpge = resolvePath(jsonString(w.cfg, "pnpge", "~/.steam/root/compatibilitytools.d"))
  let bins = resolveArrayPaths(w.cfg["pnbin"])
  if bins.len == 0: echo "No Proton binary root configured."; return
  let pnbin = bins[0]
  let temp = resolvePath(jsonString(w.cfg, "temp", "~/Downloads"))
  if not dirExists(parentDir(pnpge)): echo "Could not create folder in ", parentDir(pnpge); return
  createDir(pnpge); createDir(temp)
  echo "Checking latest Proton GE release..."
  try:
    let client = newHttpClient()
    client.headers = newHttpHeaders({"User-Agent": "wstart"})
    let data = parseJson(client.getContent("https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"))
    let tag = data["tag_name"].getStr()
    let gever = tag.replace(re"(?i)^ge-proton", "")
    let versionFile = pnpge / "protonge" / "version"
    if fileExists(versionFile):
      let installedVer = readFile(versionFile)
      if installedVer.toLowerAscii().contains(gever.toLowerAscii()):
        echo "Available Proton GE ", gever,
             " matches installed, nothing to do.\n"
        return
    echo if fileExists(versionFile): "Available Proton GE " & gever & " differs from installed, updating...\n" else: "Proton GE not found, installing...\n"
    var assetUrl = ""; var assetName = ""
    for a in data["assets"].items:
      let n = a["name"].getStr()
      if n.endsWith(".tar.gz") and n.contains("x86_64"): assetName = n; assetUrl = a["browser_download_url"].getStr(); break
    if assetUrl.len == 0: echo "No x86_64 Proton GE tarball found."; return
    let tarFile = temp / assetName
    echo "Downloading ", tag, "..."
    client.downloadFile(assetUrl, tarFile)
    let targetDir = pnpge / "protonge"
    if dirExists(targetDir): removeDir(targetDir)

    let tarExe = findExe("tar")
    if tarExe.len == 0: echo "Cannot install Proton GE: 'tar' executable not found in PATH."; return
    discard execCmd(quoteShell(tarExe) & " -xzf " & quoteShell(tarFile) & " -C " & quoteShell(pnpge))

    var extracted = ""
    for kind, x in walkDir(pnpge):
      if kind in {pcDir, pcLinkToDir} and extractFilename(x).toLowerAscii().contains("proton"): extracted = x; break
    if extracted.len > 0 and extracted != targetDir: moveDir(extracted, targetDir)
    removeFile(tarFile)
    if not fileExists(versionFile):
      writeFile(versionFile, "GE-Proton" & gever & "\n")
    else:
      let currentVersion = readFile(versionFile)
      if not currentVersion.toLowerAscii().contains(gever.toLowerAscii()):
        let normalizedVersion = currentVersion.replace(
          re"(?i)(?<=ge-proton).*",
          gever
        )
        writeFile(versionFile, normalizedVersion)
    let symlink = pnbin / "protonge"
    if not pathExists(symlink): createSymlink(targetDir, symlink)
    echo "Proton GE installed successfully."
  except CatchableError as e: echo "Failed to fetch Proton GE: ", e.msg

proc readU32LE(data: seq[byte]; off: int): uint32 =
  if off < 0 or off + 4 > data.len:
    raise newException(ValueError, "readU32LE out of bounds")
  uint32(data[off]) or
    (uint32(data[off + 1]) shl 8) or
    (uint32(data[off + 2]) shl 16) or
    (uint32(data[off + 3]) shl 24)

proc utf16zAt(data: seq[byte]; off: int; maxEnd: int): string =
  var p = off
  while p + 1 < maxEnd:
    let c = uint16(data[p]) or (uint16(data[p + 1]) shl 8)
    if c == 0'u16:
      break
    if c <= 0x7F'u16:
      result.add(char(c))
    else:
      result.add('?')
    p += 2

proc findUtf16Key(data: seq[byte]; startPos, endPos: int;
                  key: string): int =
  if key.len == 0:
    return -1

  let need = key.len * 2
  if endPos - startPos < need:
    return -1

  for i in startPos ..< endPos - need + 1:
    var matched = true
    for j, c in key:
      if data[i + j * 2] != byte(ord(c)) or
         data[i + j * 2 + 1] != 0:
        matched = false
        break
    if matched:
      return i

  -1

proc extractPeVersion(pe: PEFile): string =
  result = "N/A"

  try:
    let resDir = pe.getDataDirectory(IMAGE_DIRECTORY_ENTRY_RESOURCE)
    if resDir.virtualAddress == 0'u32 or resDir.size == 0'u32:
      return

    let resOffset = int(pe.rvaToFileOffset(resDir.virtualAddress))
    if resOffset <= 0 or resOffset >= pe.data.len:
      return

    let resEnd = min(
      pe.data.len,
      resOffset + int(resDir.size)
    )

    if resEnd <= resOffset:
      return

    const sig = 0xFEEF04BD'u32
    const structVer = 0x00010000'u32

    if resEnd - resOffset >= 16:
      for off in resOffset .. resEnd - 16:
        if readU32LE(pe.data, off) == sig and
           readU32LE(pe.data, off + 4) == structVer:

          let ms = readU32LE(pe.data, off + 8)
          let ls = readU32LE(pe.data, off + 12)

          result =
            $(ms shr 16) & "." &
            $(ms and 0xFFFF'u32) & "." &
            $(ls shr 16) & "." &
            $(ls and 0xFFFF'u32)

          return

    proc valueAfterKey(keyPos: int; key: string): string =
      let keyEnd = keyPos + key.len * 2 + 2
      if keyEnd >= resEnd:
        return ""

      var p = keyEnd
      let relative = p - resOffset
      let aligned = (relative + 3) and not 3
      p = resOffset + aligned

      if p >= resEnd:
        return ""

      utf16zAt(pe.data, p, resEnd)

    let fileVersionKey = findUtf16Key(
      pe.data, resOffset, resEnd, "FileVersion"
    )

    if fileVersionKey >= 0:
      let v = valueAfterKey(fileVersionKey, "FileVersion").strip()
      if v.len > 0:
        return v

    let productVersionKey = findUtf16Key(
      pe.data, resOffset, resEnd, "ProductVersion"
    )

    if productVersionKey >= 0:
      let v = valueAfterKey(productVersionKey, "ProductVersion").strip()
      if v.len > 0:
        return v

  except CatchableError:
    discard

  result = "N/A"

proc handleExeInfo(w: WStart) =
  if w.clprm.len == 0 or
     (not fileExists(expandHome(w.clprm[0])) and
      not dirExists(expandHome(w.clprm[0]))):
    w.xnint()
    w.xnpre()

  if w.clprm.len == 0 or
     not fileExists(expandHome(w.clprm[0])):
    if w.promptInput("query dll? [y/N] ").toLowerAscii() in ["y", "yes"]:
      w.xflt = "*.dll"

  w.xpmn()

  if not w.hasTarget or w.pedir.len == 0:
    echo "\nNo file found\n"
    return

  let target = w.pedir / w.xmrtn

  try:
    let pe = loadPEFile(target)

    let magic =
      if pe.is64bit:
        IMAGE_NT_OPTIONAL_HDR64_MAGIC
      else:
        IMAGE_NT_OPTIONAL_HDR32_MAGIC

    let bits =
      if magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC:
        "64-bit"
      else:
        "32-bit"

    echo "FILE:\n", w.xmrtn, "\n"
    echo "PE HEADER:\n", bits, "\n"

    let versionStr = extractPeVersion(pe)

    echo "Version:\n", versionStr, "\n"
    echo "REFERENCES:"

    let (outp, _) = execCmdEx("strings " & quoteShell(target))

    var seen = initTable[string, bool]()

    let dllRe = re"""(?i)([^<>:"/\\|?*\s]+\.dll)"""
    let sectionRe =
      re"(?i)^\.(?:text|s?[eripx]?data|bss|rsrc|reloc|tls|debug|crt|gfids)"

    for d in outp.findAll(dllRe):
      if not d.match(sectionRe):
        seen[d.toLowerAscii()] = true

    var dlls = toSeq(seen.keys)
    dlls.sort()

    if dlls.len == 0:
      echo "None found"
    else:
      for d in dlls:
        echo d

    echo ""

  except CatchableError:
    echo "\nNot a 32/64-bit program, no information to provide\n"
  except Defect:
    echo "\nNot a 32/64-bit program, no information to provide\n"

proc handleKill(w: WStart) =
  w.applySlotConfig()
  if w.xnbin.len == 0:
    stderr.writeLine("Error: No Wine binary root selected.")
    return
  w.xcmd.add("wineserver"); w.xcmd.add("-k"); w.launchProcess()

proc handleOverrides(w: WStart) =
  w.xnint(); w.xnpre()
  let perApp = w.promptInput("per application? [y/N] ").toLowerAscii() in ["y", "yes"]
  w.clearScreen()
  if w.xnpfx.len == 0: return
  let reg = w.xnpfx / "user.reg"
  if not fileExists(reg): echo "Registry file not found: ", reg; return

  echo "Prefix:\n", w.xnpfx, "\n"
  var entries: seq[string] = @[]
  var inBlock = false

  let appPrefix = "software/wine/appdefaults/"
  let appSuffix = "/dlloverrides"

  for line in readFile(reg).splitLines():
    let s = line.strip()
    if s.startsWith("["):
      let closeIdx = s.find(']')
      if closeIdx > 1:
        var norm = s[1 ..< closeIdx].replace("\\", "/").toLowerAscii()
        while "//" in norm: norm = norm.replace("//", "/")

        if perApp:
          if norm.startsWith(appPrefix) and norm.endsWith(appSuffix):
            inBlock = true
            let appName = norm[appPrefix.len ..< norm.len - appSuffix.len]
            entries.add(appName)
          else:
            inBlock = false
        else:
          inBlock = (norm == "software/wine/dlloverrides")
      else:
        inBlock = false
    elif inBlock and s.startsWith("\""):
      entries.add(s)

  echo if perApp: "Per-application overrides:" else: "Global overrides:"
  if entries.len == 0:
    echo "None found\n"
  else:
    for e in entries: echo e
    echo ""

proc handleLaunchExe(w: WStart) =
  w.applySlotConfig(); w.xpmn()
  if w.hasTarget: w.xlyt(); setCurrentDir(w.pedir); w.launchProcess()

proc findWineSteam(driveC: string): string =
  if not dirExists(driveC): return ""

  proc walkSteam(currentDir: string, root: string): string =
    let rel = if currentDir.startsWith(root): currentDir[root.len..^1].strip(chars={DirSep, AltSep}) else: ""
    let depth = if rel.len == 0: 0 else: rel.split({DirSep, AltSep}).len
    if depth > 3: return ""

    try:
      var subDirs: seq[string] = @[]
      for kind, path in walkDir(currentDir, relative=false):
        if kind in {pcDir, pcLinkToDir}:
          subDirs.add(path)
        elif kind in {pcFile, pcLinkToFile} and extractFilename(path).toLowerAscii() == "steam.exe":
          return path
      for d in subDirs:
        let found = walkSteam(d, root)
        if found.len > 0: return found
    except CatchableError: discard
    return ""

  return walkSteam(driveC, driveC)

proc handleSteam(w: WStart) =
  var steam = ""; var pnapp = w.pnapp
  if w.mode == "p":
    steam = findExe("steam")
  else:
    w.applySlotConfig()
    if w.xnpfx.len > 0:
      let s = findWineSteam(w.xnpfx / "drive_c")
      if s.len > 0: steam = s; pnapp = parentDir(s) / "steamapps"; w.xcmd.add(w.xstrt)
  if steam.len == 0: echo "Steam not found."; return
  var items: seq[string] = @[]
  if dirExists(pnapp):
    for mf in walkFiles(pnapp / "appmanifest_*.acf"):
      let txt = readText(mf); let id = parseAcfField(txt, "appid"); let name = parseAcfField(txt, "name")
      if id.len > 0 and name.len > 0: items.add(id & " " & name)
  var target = ""
  if items.len > 0:
    items.sort(); items.add("steam")
    let sel = w.displayMenu(items)
    let p = sel.split(maxsplit=1)
    if p.len > 0 and p[0].allCharsInSet(Digits): target = p[0]
  if target.len > 0: w.xcmd.add(steam); w.xcmd.add("-no-browser"); w.xcmd.add("-applaunch"); w.xcmd.add(target)
  else: w.xcmd.add(steam); w.xcmd.add("-no-browser"); w.xcmd.add("steam://open/minigameslist")
  w.launchProcess()

proc handleWinetricks(w: WStart) =
  w.applySlotConfig()
  if w.xnbin.len == 0:
    stderr.writeLine("Error: No Wine binary root selected.")
    return
  w.xcmd.add("winetricks")
  if w.clprm.len > 0:
    for p in w.clprm: w.xcmd.add(p)
    w.env["dbg"] = "1"
  else:
    w.xcmd.add("--gui")
  w.launchProcess()

proc handleShortcut(w: WStart) =
  let desk = resolvePath(jsonString(w.cfg, "desk", homeDir() / "Desktop"))
  if not dirExists(desk): echo "Invalid desktop location: ", desk; return
  w.applySlotConfig(); w.xpmn()
  if not w.hasTarget: return
  w.xlyt(); setCurrentDir(desk)
  let defaultName = splitFile(w.xmrtn).name
  var name = w.promptInput("Shortcut Name? [" & defaultName & "]: "); if name.len == 0: name = defaultName
  var parts = @["env"]
  for v in ["PATH", "WINEDLLPATH", "LD_LIBRARY_PATH", "WINEPREFIX", "STEAM_COMPAT_DATA_PATH", "STEAM_COMPAT_CLIENT_INSTALL_PATH"]:
    if w.env.hasKey(v): parts.add(quoteShell(v & "=" & w.env[v]))
  for x in w.xcmd: parts.add(quoteShell(x))
  let innerCmd = "cd " & quoteShell(w.pedir) & " ; " & parts.join(" ")
  let execCmd = "bash -c " & quoteShell(innerCmd)
  let content = "[Desktop Entry]\nVersion=1.0\nType=Application\nName=" & name &
    "\nComment=created by wstart\nExec=" & execCmd &
    "\nIcon=" & jsonString(w.cfg, "icon", "applications-other") &
    "\nTerminal=false\nStartupNotify=false\nCategories=Emulator;Game;\nKeywords=wine;proton;launcher;\n"
  let file = desk / (name & ".desktop")
  writeFile(file, content)
  setFilePermissions(file, {fpUserExec, fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  echo "Created shortcut: ", file

proc handleWineVersion(w: WStart) =
  w.xnint()
  w.xnexe()
  w.xnenv()
  w.xcmd.add("wine")
  w.xcmd.add("--version")
  discard w.safeStart(w.xcmd, w.getMergedEnv(), wait = false, quiet = false)

proc run(w: WStart) =
  if w.arg1.len == 0 or w.arg1 in ["-h", "--help"]:
    if w.arg1.len == 0:
      w.usage("one option required!")
    else:
      echo "\n  General usage:  wstart -w? args\n" &
           "  -w? options for wine and -p? for proton.\n" &
           "  Type wstart by itself for command list.\n"
      quit(0)

  var baseFlag = w.xarg.toLowerAscii()
  while baseFlag.len > 0 and baseFlag[^1].isDigit:
    baseFlag = baseFlag[0..^2]

  case baseFlag
  of "-xa", "--xadd": w.handleAddToPath()
  of "-xb", "--xbld": w.handleBuildPrefix()
  of "-xc", "--xcmd": w.handleProgramMenu()
  of "-xd", "--xdsk": w.handleDesktop()
  of "-ge", "--gepn": w.handleProtonGE()
  of "-xi", "--xinf": w.handleExeInfo()
  of "-xk", "--xkil": w.handleKill()
  of "-xo", "--xovr": w.handleOverrides()
  of "-xp", "--xprg": w.handleLaunchExe()
  of "-xs", "--xstm": w.handleSteam()
  of "-xt", "--xtrk": w.handleWinetricks()
  of "-xu", "--xcut": w.handleShortcut()
  of "-xv", "--xver": w.handleWineVersion()
  else:
    w.usage("invalid option " & w.arg1)

when isMainModule:
  try:
    let app = initWStart()
    app.run()
  except CatchableError:
    echo "\nAborted."
    quit(0)
