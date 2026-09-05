#!/usr/bin/env nim
import std/[os, osproc, strutils, sequtils, sets, algorithm, json, streams, times]

{.warning[Deprecated]: off.}
import std/md5
{.warning[Deprecated]: on.}

const DefaultSource = "~/Dev"
const DefaultTarget = "~/pCloudDrive/alpm"
const DefaultDownload = "~/Downloads"
const DefaultLxc = "my32bitbox"
const DefaultRepoDepth = 2

type
  Config = object
    source, target, download, lxc32: string
    repoDepth: int

  CmdResult = object
    code: int
    output: string

  RepoResult = object
    remoteHash, localHash: string
    error: string

proc expandUser(p: string): string =
  if p == "~": return getHomeDir()
  if p.startsWith("~/"): return getHomeDir() / p[2..^1]
  result = p

proc loadConfig(): Config =
  result.source = expandUser(DefaultSource)
  result.target = expandUser(DefaultTarget)
  result.download = expandUser(DefaultDownload)
  result.lxc32 = DefaultLxc
  result.repoDepth = DefaultRepoDepth
  let cp = expandUser("~/.config/repochk/config.json")
  if fileExists(cp):
    try:
      let j = parseJson(readFile(cp))
      if j.kind != JObject: quit("repochk: configuration root must be an object", 1)
      if j.hasKey("source"): result.source = expandUser(j["source"].getStr())
      if j.hasKey("target"): result.target = expandUser(j["target"].getStr())
      if j.hasKey("download"): result.download = expandUser(j["download"].getStr())
      if j.hasKey("lxc32"): result.lxc32 = j["lxc32"].getStr()
      if j.hasKey("repo_depth"): result.repoDepth = j["repo_depth"].getInt()
    except CatchableError as e:
      quit("repochk: unable to read " & cp & ": " & e.msg, 1)
  result.source = try: expandFilename(result.source) except OSError: result.source
  result.target = try: expandFilename(result.target) except OSError: result.target
  result.download = try: expandFilename(result.download) except OSError: result.download

proc usage(message: string) =
  let n = extractFilename(getAppFilename())
  stderr.write("\n" & n & ": ERROR - " & message & "\n")
  stderr.write("\nusage: " & n & "\n [-b,--build] [-i,--install] [-l,--lxc] [-m,--move] [-t,--tags]\n")

proc runCmd(args: seq[string]; cwd = ""; timeoutMs = 0): CmdResult =
  if args.len == 0: return CmdResult(code: -1, output: "")
  try:
    let p = startProcess(args[0], workingDir = cwd, args = if args.len > 1: args[1..^1] else: @[],
                         options = {poUsePath, poStdErrToStdOut})
    if timeoutMs > 0:
      let rc = waitForExit(p, timeoutMs)
      if rc == -1:
        terminate(p)
        discard waitForExit(p)
        close(p)
        return CmdResult(code: -2, output: "command timed out")
      result.code = rc
      result.output = p.outputStream.readAll()
    else:
      result.output = p.outputStream.readAll()
      result.code = waitForExit(p)
    close(p)
  except CatchableError as e:
    result.code = -3
    result.output = e.msg

proc commandOutput(args: seq[string]; cwd = ""; timeoutMs = 0): string =
  runCmd(args, cwd, timeoutMs).output

proc yesResponse(prompt: string): bool =
  stdout.write(prompt)
  stdout.flushFile()
  try:
    let line = stdin.readLine().strip().toLowerAscii()
    return line.startsWith("y")
  except EOFError, IOError:
    return false

proc firstN(s: string; n: int): string =
  if s.len > n: s[0..<n] else: s

proc findPkgbuildProjects(src: string): seq[string] =
  var found = initHashSet[string]()
  if not dirExists(src): return @[]
  for kind, path in walkDir(src, relative = false):
    if kind in {pcDir, pcLinkToDir}:
      let name = path / "PKGBUILD"
      if fileExists(name): found.incl(extractFilename(path))
    elif kind in {pcFile, pcLinkToFile} and extractFilename(path).toLowerAscii() == "pkgbuild":
      found.incl(extractFilename(parentDir(path)))
  result = toSeq(found)
  result.sort()

proc resolveProjectDir(src, value: string): string =
  var wanted = value
  if wanted.startsWith("_"): wanted = wanted[1..^1]
  var matches: seq[string] = @[]
  if dirExists(src):
    for kind, path in walkDir(src, relative = false):
      if kind notin {pcDir, pcLinkToDir}: continue
      let rp = try: expandFilename(path) except OSError: path
      if rp.toLowerAscii().endsWith(wanted.toLowerAscii()): matches.add(rp)
  matches.sort()
  if matches.len > 0: result = matches[0]

proc findRepoSignatures(project: string; maxDepth: int): seq[string] =
  if not dirExists(project): return @[]
  var found = initHashSet[string]()
  var visited = initHashSet[string]()
  var stack: seq[tuple[path: string, depth: int]] = @[(project, 1)]

  while stack.len > 0:
    let (cur, depth) = stack.pop()
    if depth > maxDepth: continue
    let real = try: expandFilename(cur) except OSError: cur
    if real in visited: continue
    visited.incl(real)

    try:
      for kind, path in walkDir(cur, relative = false):
        let n = extractFilename(path)
        let nl = n.toLowerAscii()
        if depth == 1 and nl == ".git": continue
        if n == "HEAD" and kind in {pcFile, pcLinkToFile}: found.incl(real)
        if nl in [".hg", ".svn"] and kind in {pcDir, pcLinkToDir}: found.incl(real)
        if depth < maxDepth and kind in {pcDir, pcLinkToDir}:
          stack.add((path, depth + 1))
    except OSError:
      discard

  result = toSeq(found)
  result.sort()

proc gitRemoteBranch(sourceRepo, splitRepo: string): string =
  let b = commandOutput(@["git", "-C", splitRepo, "branch", "-a", "--contains", "HEAD"])
  var matches: seq[string] = @[]
  for line in b.splitLines():
    let pos = line.find("-> origin/")
    if pos >= 0:
      var refName = line[pos + 10 .. ^1].splitWhitespace()[0]
      while refName.len > 0 and refName[^1] == ',':
        refName.setLen(refName.len - 1)
      if refName.len > 0: matches.add(refName)
  if matches.len == 0:
    for line in b.splitLines():
      let pos = line.find("origin/")
      if pos >= 0:
        var refName = line[pos + 7 .. ^1].splitWhitespace()[0]
        while refName.len > 0 and refName[^1] == ',':
          refName.setLen(refName.len - 1)
        if refName.len > 0: matches.add(refName)
  var branch = if matches.len > 0: matches[0] else: ""
  if matches.len > 1:
    let logFile = splitRepo / ".git" / "logs" / "refs" / "heads" / "makepkg"
    if fileExists(logFile):
      var last = ""
      for line in readFile(logFile).splitLines():
        let marker = "branch: created from origin/"
        let p = line.find(marker)
        if p >= 0: last = line[p + marker.len .. ^1].strip()
      if last.len > 0: branch = last
  if branch.len == 0: return ""
  let r = runCmd(@["git", "-C", sourceRepo, "rev-parse", "--abbrev-ref", branch])
  if r.code != 0: return ""
  r.output.strip()

proc gitRemoteHash(sourceRepo, branch: string): RepoResult =
  if branch.len == 0: return RepoResult(error: "Git branch lookup failed")
  let r = runCmd(@["git", "-C", sourceRepo, "ls-remote", "-q", "-h", "origin", branch], timeoutMs = 5000)
  if r.code == -2: return RepoResult(error: "Network timeout while querying remote")
  if r.code != 0: return RepoResult(error: "git ls-remote failed: " & r.output.strip())
  let wanted = "refs/heads/" & branch
  for line in r.output.splitLines():
    let f = line.splitWhitespace()
    if f.len >= 2 and f[1] == wanted: return RepoResult(remoteHash: firstN(f[0], 7))
  RepoResult(error: "Git remote unreachable or branch '" & branch & "' missing")

proc repositoryHashes(mydir, mysrc: string): RepoResult =
  let srcDir = mydir / "src"
  if not dirExists(srcDir): return RepoResult()
  if fileExists(mysrc / "HEAD"):
    let splitRepo = srcDir / extractFilename(mysrc)
    if not dirExists(splitRepo / ".git"): return RepoResult(error: "Git split repository missing in '" & extractFilename(mysrc) & "'")
    let branch = gitRemoteBranch(mysrc, splitRepo)
    if branch.len == 0: return RepoResult(error: "Git branch lookup failed in '" & extractFilename(mysrc) & "'")
    let rr = gitRemoteHash(mysrc, branch)
    if rr.error.len > 0: return RepoResult(error: rr.error & " in '" & extractFilename(mysrc) & "'")
    let local = runCmd(@["git", "-C", splitRepo, "show", "-s", "--pretty=format:%h"])
    if local.code != 0 or local.output.strip().len == 0: return RepoResult(error: "Git local revision lookup failed in '" & extractFilename(mysrc) & "'")
    return RepoResult(remoteHash: rr.remoteHash, localHash: firstN(local.output.strip(), 7))
  if dirExists(mysrc / ".hg"):
    let paths = runCmd(@["hg", "-R", mysrc, "paths"], timeoutMs = 5000)
    if paths.code == -2: return RepoResult(error: "Network timeout while querying Mercurial in '" & extractFilename(mysrc) & "'")
    if paths.code != 0: return RepoResult(error: "Mercurial remote lookup failed in '" & extractFilename(mysrc) & "'")
    var remote = ""
    for line in paths.output.splitLines():
      let p = line.toLowerAscii().find("http")
      if p >= 0: remote = line[p..^1].strip()
    let br = runCmd(@["hg", "-R", mysrc, "identify", "-b"], timeoutMs = 5000)
    let branch = br.output.strip()
    if br.code != 0 or branch.len == 0: return RepoResult(error: "Mercurial branch lookup failed in '" & extractFilename(mysrc) & "'")
    if remote.len == 0: return RepoResult(error: "Mercurial remote URL missing in '" & extractFilename(mysrc) & "'")
    let rr = runCmd(@["hg", "-R", mysrc, "identify", remote & "#" & branch], timeoutMs = 5000)
    if rr.code == -2: return RepoResult(error: "Network timeout while querying Mercurial in '" & extractFilename(mysrc) & "'")
    if rr.code != 0 or firstN(rr.output.strip(), 7).len == 0: return RepoResult(error: "Mercurial remote unreachable for '" & extractFilename(mysrc) & "'")
    let lr = runCmd(@["hg", "-R", srcDir / extractFilename(mysrc), "identify", "-i"])
    if lr.code != 0 or firstN(lr.output.strip(), 7).len == 0: return RepoResult(error: "Mercurial local revision lookup failed in '" & extractFilename(mysrc) & "'")
    return RepoResult(remoteHash: firstN(rr.output.strip(), 7), localHash: firstN(lr.output.strip(), 7))
  if dirExists(mysrc / ".svn"):
    let info = runCmd(@["svn", "info", mysrc], timeoutMs = 5000)
    if info.code == -2: return RepoResult(error: "Network timeout while querying SVN in '" & extractFilename(mysrc) & "'")
    var url = ""
    for line in info.output.splitLines():
      if line.startsWith("URL: "): url = line[5..^1]
    if info.code != 0 or url.len == 0: return RepoResult(error: "SVN URL lookup failed in '" & extractFilename(mysrc) & "'")
    let remote = runCmd(@["svn", "info", url], timeoutMs = 5000)
    if remote.code == -2: return RepoResult(error: "Network timeout while querying SVN in '" & extractFilename(mysrc) & "'")
    var rev = ""
    for line in remote.output.splitLines():
      if line.startsWith("Revision: "):
        for c in line[10..^1]:
          if c.isDigit:
            rev.add(c)
          elif rev.len > 0:
            break
    if remote.code != 0 or rev.len == 0: return RepoResult(error: "SVN remote unreachable for '" & extractFilename(mysrc) & "'")
    let local = runCmd(@["svnversion", srcDir / extractFilename(mysrc)])
    var lrev = ""
    for c in local.output:
      if c.isDigit:
        lrev.add(c)
      elif lrev.len > 0:
        break
    if local.code != 0 or lrev.len == 0: return RepoResult(error: "SVN local revision lookup failed in '" & extractFilename(mysrc) & "'")
    let rh = firstN($getMD5(rev), 7)
    let lh = firstN($getMD5(lrev), 7)
    return RepoResult(remoteHash: rh, localHash: lh)
  RepoResult()

proc packageName(path: string): string = commandOutput(@["pacman", "-Updd", path, "--print-format", "%n"]).strip()
proc packageVersion(path: string): string = commandOutput(@["pacman", "-Updd", path, "--print-format", "%v"]).strip()

proc packageFile(path: string): bool =
  let x = path.toLowerAscii()
  x.endsWith(".pkg.tar.xz") or x.endsWith(".pkg.tar.zst")

proc walkFilesBounded(root: string; maxDepth: int; followLinks: bool; outp: var seq[string]) =
  if not dirExists(root): return
  var seen = initHashSet[string]()
  var stack: seq[tuple[path: string, depth: int]] = @[(root, 1)]

  while stack.len > 0:
    let (cur, depth) = stack.pop()
    if depth > maxDepth: continue
    let real = try: expandFilename(cur) except OSError: cur
    if real in seen: continue
    seen.incl(real)

    try:
      for kind, path in walkDir(cur, relative = false):
        if kind in {pcFile, pcLinkToFile}:
          outp.add(path)
        elif kind in {pcDir, pcLinkToDir} and depth < maxDepth:
          if kind == pcLinkToDir and not followLinks: continue
          stack.add((path, depth + 1))
    except OSError:
      discard

proc findPackages(tgt: string): seq[string] =
  var all: seq[string] = @[]
  walkFilesBounded(tgt, 1000, false, all)
  for path in all:
    if not packageFile(path): continue
    let rel = path.relativePath(tgt)
    var hidden = false
    for part in rel.split(DirSep):
      if part.startsWith("."): hidden = true
    if not hidden: result.add(path)
  result.sort()

proc installedVersion(pkg: string): string =
  let outver = commandOutput(@["pacman", "-Qi", pkg])
  for line in outver.splitLines():
    if line.toLowerAscii().startsWith("version"):
      return line.splitWhitespace()[^1]

proc vercmp(a, b: string): tuple[ok: bool, value: int] =
  let r = runCmd(@["vercmp", a, b])
  if r.code != 0: return (false, 0)
  try:
    return (true, parseInt(r.output.strip()))
  except ValueError:
    return (false, 0)

proc isFuseMount(path: string): bool =
  let m = commandOutput(@["stat", "--format=%m", path]).strip()
  if m.len == 0: return false
  let fs = commandOutput(@["stat", "--file-system", "--format=%T", m]).strip()
  fs.toLowerAscii().contains("fuse")

proc install(cfg: Config) =
  let show = yesResponse("Show installed up to date projects. [y/N] ")
  echo(if show: "Up to date:" else: "Out of date:")
  var upToDateLines: seq[string] = @[]
  for value in findPackages(cfg.target):
    let name = packageName(value)
    let targetVer = packageVersion(value)
    let localVer = installedVersion(name)
    if name.len == 0 or targetVer.len == 0 or localVer.len == 0: continue
    let vc = vercmp(localVer, targetVer)
    if not vc.ok:
      stderr.writeLine("repochk: version comparison failed for " & name & " (" & localVer & " vs " & targetVer & ")")
      continue
    let c = vc.value
    if show:
      if c == 0:
        upToDateLines.add("pacman(" & localVer & ")  alpm(" & targetVer & ") - " & name)
    elif c < 0:
      echo(name, " (", localVer, ") is older than (", targetVer, "), updating...")
      if isFuseMount(cfg.target):
        let tmp = "/tmp" / extractFilename(value)
        copyFile(value, tmp)
        discard runCmd(@["sudo", "pacman", "-U", "--noconfirm", tmp])
        try: removeFile(tmp) except OSError: discard
      else:
        discard runCmd(@["sudo", "pacman", "-U", "--noconfirm", value])
  if show:
    upToDateLines.sort(proc(a, b: string): int =
      let aa = a.splitWhitespace()
      let bb = b.splitWhitespace()
      var i = 2
      while i < aa.len and i < bb.len:
        let c = cmp(aa[i], bb[i])
        if c != 0: return c
        inc i
      cmp(aa.len, bb.len))
    for line in upToDateLines:
      echo line

proc findMovePackages(cfg: Config): seq[string] =
  let roots = @[expandUser("~/.cache/yay"), cfg.source]
  for root in roots:
    var all: seq[string] = @[]
    walkFilesBounded(root, 3, true, all)
    for path in all:
      if packageFile(path): result.add(path)
  result.sort()

proc findMatchingTarget(tgt, pkg, newer: string): seq[string] =
  if not dirExists(tgt): return @[]
  let mt = try: getLastModificationTime(newer) except OSError: return @[]
  let pkgLower = pkg.toLowerAscii()
  for p in findPackages(tgt):
    if ".trash" in p: continue
    if pkgLower notin extractFilename(p).toLowerAscii(): continue
    try:
      if getLastModificationTime(p) <= mt and packageName(p) == pkg:
        result.add(p)
    except OSError:
      discard

proc safeMoveFile(src, dest: string) =
  try:
    moveFile(src, dest)
  except OSError:
    copyFile(src, dest)
    removeFile(src)

proc movePackages(cfg: Config) =
  var messages: seq[string] = @[]
  if yesResponse("Delete " & cfg.target & " alpm and replace with newer? [y/N] "):
    echo "Updating ..."
    for value in findMovePackages(cfg):
      let pkg = packageName(value)
      if pkg.len == 0: continue
      let matches = findMatchingTarget(cfg.target, pkg, value)
      if matches.len == 0: continue
      let old = matches[0]
      let tr = runCmd(@["trash", "-f", old])
      if tr.code != 0:
        stderr.writeLine("repochk: could not trash " & old & "; not replacing it")
        continue
      let dest = parentDir(old) / extractFilename(value)
      try:
        safeMoveFile(value, dest)
        if fileExists(dest):
          messages.add("Trashed " & old)
          messages.add("Replaced by " & value)
        else:
          stderr.writeLine("repochk: move appeared to succeed, but destination file " & dest & " was not created")
      except OSError as e:
        stderr.writeLine("repochk: failed to move " & extractFilename(value) & " to " & dest & ": " & e.msg)
  else:
    echo("Moving alpm to ", cfg.download, " ...")
    createDir(cfg.download)
    for value in findMovePackages(cfg):
      try:
        safeMoveFile(value, cfg.download / extractFilename(value))
      except OSError as e:
        stderr.writeLine("repochk: failed to move " & extractFilename(value) & " to " & cfg.download & ": " & e.msg)

  if messages.len > 0:
    echo ""
    for line in messages: echo line

proc isAsciiWord(c: char): bool =
  c.isAlphaNumeric or c == '_'

proc isAsciiWhitespace(c: char): bool =
  c in {' ', '\t', '\r', '\n', '\v', '\f'}

proc normalizeTag(s: string): string =
  ## Match Python: re.sub(r"[^\w\s]", ".", tag, flags=re.ASCII)
  result = s
  for i, c in result:
    if not (isAsciiWord(c) or isAsciiWhitespace(c)):
      result[i] = '.'

proc versionTagPart(s: string): string =
  ## Python VERSION_TAG_RE:
  ##   (\d+([._-]|$)){2}[\w.-]*
  ## Return the first matching version-like portion, or "".
  var i = 0
  while i < s.len:
    var j = i
    var groups = 0
    while groups < 2 and j < s.len:
      let digitStart = j
      while j < s.len and s[j].isDigit: inc j
      if j == digitStart: break
      if j < s.len and s[j] in {'.', '_', '-'}:
        inc j
      elif j == s.len:
        inc groups
        break
      else:
        break
      inc groups
    if groups == 2:
      var k = j
      while k < s.len and (isAsciiWord(s[k]) or s[k] == '.' or s[k] == '-'):
        inc k
      return s[i..<k]
    inc i
  return ""

proc versionKey(s: string): seq[string] =
  ## Natural-ish ordering matching the Python split-on-digit approach.
  var cur = ""
  var digit = false
  var have = false
  for c in s:
    let d = c.isDigit
    if have and d != digit:
      result.add(cur)
      cur = ""
    cur.add(c)
    digit = d
    have = true
  if cur.len > 0: result.add(cur)

proc cmpVersion(a, b: string): int =
  let aa = versionKey(a)
  let bb = versionKey(b)
  var i = 0
  while i < min(aa.len, bb.len):
    if aa[i] != bb[i]:
      let an = aa[i].allCharsInSet({'0'..'9'})
      let bn = bb[i].allCharsInSet({'0'..'9'})
      if an and bn:
        try:
          return cmp(parseBiggestInt(aa[i]), parseBiggestInt(bb[i]))
        except ValueError:
          discard
      return cmp(aa[i], bb[i])
    inc i
  cmp(aa.len, bb.len)

proc versionSort(xs: seq[string]): seq[string] =
  result = xs
  result.sort(cmpVersion)

proc collectGitTags(): seq[string] =
  if runCmd(@["git", "show", "-s", "--pretty=format:%h"]).code != 0:
    return @[]
  let outgit = commandOutput(@["git", "ls-remote", "-q", "--tags", "--refs"])
  for line in outgit.splitLines():
    let f = line.splitWhitespace()
    if f.len < 2: continue
    let rawTag = f[1].split('/')[^1]
    let part = versionTagPart(rawTag)
    if part.len > 0: result.add(normalizeTag(part))
  result = versionSort(result)

proc collectHgTags(): seq[string] =
  if runCmd(@["hg", "identify"]).code != 0:
    return @[]
  let outhg = commandOutput(@["hg", "tags"])
  for line in outhg.splitLines():
    let part = versionTagPart(line)
    if part.len > 0: result.add(normalizeTag(part))
  result = versionSort(result)

proc tags() =
  let all = yesResponse("All tags? [y/N] ")
  let gitTags = collectGitTags()
  let hgTags = collectHgTags()

  if all:
    for x in gitTags: echo x
    for x in hgTags: echo x
  else:
    if gitTags.len > 0: echo gitTags[^1]
    if hgTags.len > 0: echo hgTags[^1]

proc lxc(cfg: Config) =
  let inside = runCmd(@["sudo", "grep", "-ioa", "container=lxc", "/proc/1/environ"]).output.strip().len > 0
  if inside:
    discard runCmd(@["sudo", "shutdown", "-h", "now"])
    return
  let info = runCmd(@["sudo", "lxc-info", "-n", cfg.lxc32])
  if not info.output.toLowerAscii().contains("running"):
    let st = runCmd(@["sudo", "lxc-start", "-n", cfg.lxc32])
    if st.code == 0:
      discard runCmd(@["sudo", "lxc-attach", "-n", cfg.lxc32, "--", "login", getEnv("LOGNAME")])
  else:
    discard runCmd(@["sudo", "lxc-stop", "-n", cfg.lxc32])

proc build(cfg: Config) =
  var projects: seq[string] = @[]
  var failures: seq[string] = @[]
  echo "Scanning repositories for updates..."
  for value in findPkgbuildProjects(cfg.source):
    let mydir = resolveProjectDir(cfg.source, value)
    if mydir.len == 0: continue
    for mysrc in findRepoSignatures(mydir, cfg.repoDepth):
      if dirExists(mydir / "src"):
        let rr = repositoryHashes(mydir, mysrc)
        if rr.error.len > 0:
          failures.add("[" & value & "] " & rr.error)
        elif rr.remoteHash.len > 0 and rr.remoteHash != rr.localHash:
          projects.add(value)
      else:
        projects.add(value)

  if failures.len > 0:
    stderr.writeLine("\nERROR: Repository scan encountered errors:")
    for e in failures:
      stderr.writeLine("  - " & e)
    stderr.writeLine("\nBuild process stopped due to network or repository errors.")
    return

  projects = projects.deduplicate()
  projects.sort()
  if projects.len == 0: return

  if yesResponse("Rebuild updated Arch? [y/N] "):
    echo "Rebuilding all updated Arch packages.\nThis could take awhile ..."
    for pkg in projects:
      let pkgbuild = cfg.source / pkg / "PKGBUILD"
      if fileExists(pkgbuild):
        try: removeFile(pkgbuild) except OSError: discard
      discard runCmd(@["patch", "-Np1", "-i", cfg.source / "unibuild" / "data" / "arch" / (pkg & ".patch")], cwd = cfg.source)
      discard runCmd(@["makepkg", "-f"], cwd = cfg.source / pkg)
    echo "\nProjects that were updated:\n"
  else:
    echo "\nProjects available for update:\n"

  let logPath = cfg.source / (extractFilename(getAppFilename()) & ".log")
  try:
    writeFile(logPath, projects.join("\n") & "\n")
  except OSError as e:
    stderr.writeLine("repochk: could not write log file " & logPath & ": " & e.msg)

  for p in projects: echo p

when isMainModule:
  let cfg = loadConfig()
  var ok = true
  if not dirExists(cfg.source): echo("Source tree ", cfg.source, " doesn't exist."); ok = false
  if not dirExists(cfg.target): echo("Backup folder ", cfg.target, " doesn't exist."); ok = false
  if not dirExists(cfg.download): echo("Temp folder ", cfg.download, " doesn't exist."); ok = false
  if not ok: quit(0)
  if paramCount() < 1: usage("one option required, patch name optional"); quit(0)
  case paramStr(1)
  of "-b", "--build": build(cfg)
  of "-i", "--install": install(cfg)
  of "-l", "--lxc": lxc(cfg)
  of "-m", "--move": movePackages(cfg)
  of "-t", "--tags": tags()
  else: usage("invalid option " & paramStr(1)); quit(1)
