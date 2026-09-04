#!/usr/bin/env python3
r"""
repochk.py

Python port of the original Bash repochk utility.

The intent is behavioral parity with the Bash script:
  -b, --build
  -i, --install
  -l, --lxc
  -m, --move
  -t, --tags

Configuration is read from ~/.config/repochk/config.json when present.
Missing configuration values use the original Bash defaults.

The program deliberately continues to use the system's authoritative tools
(git, hg, svn, pacman, vercmp, makepkg, patch, trash, lxc-*) rather than
reimplementing their semantics.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat as stat_module
import subprocess
import sys
from pathlib import Path
from typing import Iterable


DEFAULT_CONFIG = {
    "source": "~/Dev",
    "target": "~/pCloudDrive/alpm",
    "download": "~/Downloads",
    "lxc32": "my32bitbox",
    "repo_depth": 2,
}


VERSION_TAG_RE = re.compile(r"(\d+([._-]|$)){2}[\w.-]*", re.IGNORECASE)
GIT_BRANCH_ARROW_RE = re.compile(r"(?<=-> origin/)[^\s,]+")
GIT_BRANCH_ORIGIN_RE = re.compile(r"(?<=origin/)[^\s,]+")
MAKEPKG_BRANCH_RE = re.compile(r"(?<=branch: created from origin/).*")
HG_REMOTE_RE = re.compile(r"http.*$", re.IGNORECASE)
SVN_URL_RE = re.compile(r"(?<=^URL: ).*", re.IGNORECASE | re.MULTILINE)
SVN_REV_RE = re.compile(r"(?<=^Revision: )\d+", re.IGNORECASE | re.MULTILINE)
SVN_VERSION_RE = re.compile(r"\d+")
VERSION_LINE_RE = re.compile(r"^version.*", re.IGNORECASE | re.MULTILINE)
TRAILING_NONSPACE_RE = re.compile(r"\S+$")


def load_config() -> dict:
    config_path = Path("~/.config/repochk/config.json").expanduser()
    config = dict(DEFAULT_CONFIG)

    if config_path.is_file():
        try:
            with config_path.open("r", encoding="utf-8") as fh:
                loaded = json.load(fh)
            if not isinstance(loaded, dict):
                raise ValueError("configuration root must be an object")
            config.update(loaded)
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            print(f"repochk: unable to read {config_path}: {exc}", file=sys.stderr)
            sys.exit(1)

    for key in ("source", "target", "download"):
        config[key] = os.path.realpath(os.path.expanduser(os.fspath(config[key])))

    try:
        config["repo_depth"] = int(config["repo_depth"])
    except (TypeError, ValueError):
        print("repochk: repo_depth must be an integer", file=sys.stderr)
        sys.exit(1)

    config["lxc32"] = str(config["lxc32"])
    return config


def usage(message: str) -> None:
    name = Path(sys.argv[0]).name
    print(f"\n{name}: ERROR - {message}", file=sys.stderr)
    print(
        f"\nusage: {name}\n"
        " [-b,--build] [-i,--install] [-l,--lxc] [-m,--move] [-t,--tags]\n",
        file=sys.stderr,
    )


def run(
    args: list[str],
    *,
    capture: bool = True,
    check: bool = False,
    cwd: str | Path | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=os.fspath(cwd) if cwd is not None else None,
        stdin=None,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
        check=check,
        timeout=timeout,
    )


def command_output(
    args: list[str],
    *,
    cwd: str | Path | None = None,
    stderr_to_stdout: bool = False,
    timeout: float | None = None,
) -> str:
    result = subprocess.run(
        args,
        cwd=os.fspath(cwd) if cwd is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if stderr_to_stdout else subprocess.PIPE,
        text=True,
        check=False,
        timeout=timeout,
    )
    return result.stdout


def yes_response(prompt: str) -> bool:
    try:
        answer = input(prompt)
    except EOFError:
        answer = ""
    return bool(re.fullmatch(r"(?:[yY][eE][sS]|[yY])+", answer))


def first_line(text: str) -> str:
    return text.splitlines()[0] if text.splitlines() else ""


def first_n_chars(text: str, count: int) -> str:
    return text[:count]


def find_pkgbuild_projects(srcdir: Path) -> list[str]:
    r"""
    Bash equivalent:

      find "$srcdir" -maxdepth 2 -mindepth 1 -type f -iname PKGBUILD \
        -printf '%h\\n' | ... | sort

    We retain the directory basename produced by the original pipeline.
    """
    projects: set[str] = set()
    srcdir = Path(srcdir)

    if not srcdir.is_dir():
        return []

    # maxdepth 2 means PKGBUILD can be directly under srcdir or one directory
    # below it. Follow the same ordinary-directory behavior as find here.
    try:
        for entry in srcdir.iterdir():
            if entry.is_file() and entry.name.lower() == "pkgbuild":
                projects.add(entry.parent.name)

            if entry.is_dir() or entry.is_symlink():
                try:
                    for child in entry.iterdir():
                        if child.is_file() and child.name.lower() == "pkgbuild":
                            projects.add(child.parent.name)
                except OSError:
                    pass
    except OSError:
        pass

    return sorted(projects)


def resolve_project_dir(srcdir: Path, value: str) -> Path | None:
    r"""
    Approximate the original:

      find "$srcdir" -maxdepth 1 -type l,d \( -ipath "*${value#_}" \)
        -execdir realpath "{}" \; |
        perl ... "$srcdir/<first component>"

    The useful result is the project root immediately below srcdir, with
    symlinks resolved. Leading '_' in the PKGBUILD-derived name is ignored
    for the path match, as in the Bash expression.
    """
    wanted = value[1:] if value.startswith("_") else value
    wanted_lower = wanted.lower()

    try:
        entries = list(srcdir.iterdir())
    except OSError:
        return None

    matches: list[Path] = []
    for entry in entries:
        if not (entry.is_dir() or entry.is_symlink()):
            continue
        try:
            resolved = Path(os.path.realpath(entry))
        except OSError:
            continue

        # The Bash find -ipath "*wanted" permits a matching path ending in
        # the project name. In normal use these are the immediate project
        # directories, including symlinks.
        if str(resolved).lower().endswith(wanted_lower):
            matches.append(resolved)

    if not matches:
        return None

    # Preserve deterministic behavior when more than one candidate happens
    # to satisfy the broad -ipath pattern.
    matches.sort(key=lambda p: str(p))
    return matches[0]


def find_repo_signatures(project_dir: Path, max_depth: int) -> list[Path]:
    r"""
    Discover repository signatures using the same depth concept as:

      find -H "$mydir" -maxdepth 2
        ! \( -ipath "$mydir/.git/*" \)
        \( -name HEAD -o -iname .hg -o -iname .svn \)
        -execdir realpath . \;

    A Git worktree's .git directory is represented by its HEAD file, while
    Mercurial/Subversion repositories are represented by .hg/.svn.
    """
    project_dir = Path(project_dir)
    found: list[Path] = []

    if not project_dir.exists():
        return found

    root_depth = len(project_dir.parts)

    def walk(current: Path, depth: int) -> None:
        if depth > max_depth:
            return

        try:
            entries = list(current.iterdir())
        except OSError:
            return

        for entry in entries:
            name_lower = entry.name.lower()

            # Original find explicitly excludes anything beneath project/.git.
            if depth == 1 and name_lower == ".git":
                # The .git directory itself is not a search result; its HEAD
                # is deliberately excluded by the Bash ! -ipath condition.
                continue

            # Repository signatures at this level.
            if entry.name == "HEAD" and entry.is_file():
                try:
                    found.append(Path(os.path.realpath(current)))
                except OSError:
                    pass

            if name_lower in {".hg", ".svn"} and entry.is_dir():
                try:
                    found.append(Path(os.path.realpath(entry.parent)))
                except OSError:
                    pass

            if depth < max_depth and (entry.is_dir() or entry.is_symlink()):
                # Do not traverse project/.git at all.
                if depth == 1 and name_lower == ".git":
                    continue
                try:
                    if entry.is_symlink():
                        target = Path(os.path.realpath(entry))
                        if target.is_dir():
                            walk(target, depth + 1)
                    else:
                        walk(entry, depth + 1)
                except OSError:
                    pass

    walk(project_dir, 1)

    # The Bash command can return duplicate paths in unusual trees.
    # sort -u behavior is reproduced here.
    unique = sorted({str(p): p for p in found}.values(), key=lambda p: str(p))
    return unique


def git_remote_branch(source_repo: Path, split_repo: Path) -> str:
    branches = command_output(
        ["git", "-C", os.fspath(split_repo), "branch", "-a", "--contains", "HEAD"]
    )

    matches = GIT_BRANCH_ARROW_RE.findall(branches)
    if not matches:
        matches = GIT_BRANCH_ORIGIN_RE.findall(branches)

    branch = "\n".join(matches)

    if len(matches) > 1:
        log_file = split_repo / ".git" / "logs" / "refs" / "heads" / "makepkg"
        try:
            log_text = log_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            log_text = ""
        created = MAKEPKG_BRANCH_RE.findall(log_text)
        if created:
            branch = created[-1]

    # Bash performs this through git rev-parse and allows failure to produce
    # an empty result.
    result = run(
        ["git", "-C", os.fspath(source_repo), "rev-parse", "--abbrev-ref", branch],
        capture=True,
        check=False,
    )
    return result.stdout.strip()


def short_git_remote_hash(source_repo: Path, branch: str) -> str:
    if not branch:
        return ""

    result = run(
        ["git", "-C", os.fspath(source_repo), "ls-remote", "-q", "-h", "origin", branch],
        capture=True,
        check=False,
        timeout=5.0,
    )

    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "remote query failed").strip()
        raise RuntimeError(f"git ls-remote failed: {detail}")

    wanted = f"refs/heads/{branch}"
    for line in result.stdout.splitlines():
        if wanted in line:
            fields = line.split()
            if fields:
                return fields[0][:7]
    return ""


def short_git_local_hash(split_repo: Path) -> str:
    result = run(
        [
            "git",
            "-C",
            os.fspath(split_repo),
            "show",
            "-s",
            "--pretty=format:%h",
        ],
        capture=True,
        check=False,
    )
    return first_n_chars(result.stdout, 7)


def md5_head7(value: str) -> str:
    import hashlib

    digest = hashlib.md5(value.encode()).hexdigest()
    return digest[:7]


def repository_hashes(
    mydir: Path,
    mysrc: Path,
) -> tuple[str, str, str | None]:
    # Return remote/local hashes plus a scan error, if any.
    src_dir = mydir / "src"

    if not src_dir.is_dir():
        return "", "", None

    try:
        if (mysrc / "HEAD").is_file():
            split_repo = src_dir / mysrc.name
            if not (split_repo / ".git").is_dir():
                return "", "", f"Git split repository missing in '{mysrc.name}'"

            branch = git_remote_branch(mysrc, split_repo)
            if not branch:
                return "", "", f"Git branch lookup failed in '{mysrc.name}'"

            myhash = short_git_remote_hash(mysrc, branch)
            if not myhash:
                return "", "", f"Git remote unreachable or branch '{branch}' missing in '{mysrc.name}'"

            mychk = short_git_local_hash(split_repo)
            if not mychk:
                return "", "", f"Git local revision lookup failed in '{mysrc.name}'"
            return myhash, mychk, None

        if (mysrc / ".hg").is_dir():
            paths_result = run(
                ["hg", "-R", os.fspath(mysrc), "paths"],
                capture=True, check=False, timeout=5.0,
            )
            if paths_result.returncode != 0:
                detail = (paths_result.stderr or paths_result.stdout or "remote lookup failed").strip()
                return "", "", f"Mercurial remote lookup failed in '{mysrc.name}': {detail}"
            remotes = HG_REMOTE_RE.findall(paths_result.stdout)
            remote = remotes[-1] if remotes else ""

            branch_result = run(
                ["hg", "-R", os.fspath(mysrc), "identify", "-b"],
                capture=True, check=False, timeout=5.0,
            )
            branch = branch_result.stdout.strip()
            if branch_result.returncode != 0 or not branch:
                return "", "", f"Mercurial branch lookup failed in '{mysrc.name}'"
            if not remote:
                return "", "", f"Mercurial remote URL missing in '{mysrc.name}'"

            mydeb = f"{remote}#{branch}"
            remote_result = run(
                ["hg", "-R", os.fspath(mysrc), "identify", mydeb],
                capture=True, check=False, timeout=5.0,
            )
            myhash = first_n_chars(remote_result.stdout, 7)
            if remote_result.returncode != 0 or not myhash:
                return "", "", f"Mercurial remote unreachable for '{mysrc.name}'"

            local_result = run(
                ["hg", "-R", os.fspath(src_dir / mysrc.name), "identify", "-i"],
                capture=True, check=False,
            )
            mychk = first_n_chars(local_result.stdout, 7)
            if local_result.returncode != 0 or not mychk:
                return "", "", f"Mercurial local revision lookup failed in '{mysrc.name}'"
            return myhash, mychk, None

        if (mysrc / ".svn").is_dir():
            info_result = run(
                ["svn", "info", os.fspath(mysrc)],
                capture=True, check=False, timeout=5.0,
            )
            if info_result.returncode != 0:
                return "", "", f"SVN URL lookup failed in '{mysrc.name}'"
            match = SVN_URL_RE.search(info_result.stdout)
            mydeb = match.group(0) if match else ""
            if not mydeb:
                return "", "", f"SVN URL lookup failed in '{mysrc.name}'"

            remote_result = run(
                ["svn", "info", mydeb],
                capture=True, check=False, timeout=5.0,
            )
            rev_match = SVN_REV_RE.search(remote_result.stdout)
            remote_revision = rev_match.group(0) if rev_match else ""
            if remote_result.returncode != 0 or not remote_revision:
                return "", "", f"SVN remote unreachable for '{mysrc.name}'"

            myhash = md5_head7(remote_revision)
            local_result = run(
                ["svnversion", os.fspath(src_dir / mysrc.name)],
                capture=True, check=False,
            )
            local_match = SVN_VERSION_RE.search(local_result.stdout)
            local_revision = local_match.group(0) if local_match else ""
            if local_result.returncode != 0 or not local_revision:
                return "", "", f"SVN local revision lookup failed in '{mysrc.name}'"
            mychk = md5_head7(local_revision)
            return myhash, mychk, None

    except subprocess.TimeoutExpired:
        return "", "", f"Network timeout while querying remote for '{mysrc.name}'"
    except OSError as exc:
        return "", "", f"Repository check failed for '{mysrc.name}': {exc}"
    except RuntimeError as exc:
        return "", "", f"Repository check failed for '{mysrc.name}': {exc}"

    return "", "", None


def build(config: dict) -> None:
    srcdir = Path(config["source"])
    myprnt: list[str] = []
    failures: list[str] = []

    print("Scanning repositories for updates...")

    # First pass: inspect every repository. Nothing destructive happens here.
    for value in find_pkgbuild_projects(srcdir):
        myprj = value
        mydir = resolve_project_dir(srcdir, value)
        if mydir is None:
            continue

        for mysrc in find_repo_signatures(mydir, config["repo_depth"]):
            if (mydir / "src").is_dir():
                myhash, mychk, error = repository_hashes(mydir, mysrc)
                if error:
                    failures.append(f"[{myprj}] {error}")
                elif myhash and myhash != mychk:
                    myprnt.append(myprj)
            else:
                # Preserve the Bash behavior: without $mydir/src, rebuild.
                myprnt.append(myprj)

    # Safety gate: a partial scan must never be allowed to start a build.
    if failures:
        print("\nERROR: Repository scan encountered errors:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        print(
            "\nBuild process stopped due to network or repository errors.",
            file=sys.stderr,
        )
        return

    if not myprnt:
        return

    unique_projects = sorted(set(myprnt))

    if yes_response("Rebuild updated Arch? [y/N] "):
        print("Rebuilding all updated Arch packages.")
        print("This could take awhile ...")
        for pkg in unique_projects:
            os.chdir(srcdir)

            pkgbuild = srcdir / pkg / "PKGBUILD"
            try:
                pkgbuild.unlink()
            except FileNotFoundError:
                pass

            patch_file = srcdir / "unibuild" / "data" / "arch" / f"{pkg}.patch"
            subprocess.run(
                ["patch", "-Np1", "-i", os.fspath(patch_file)],
                check=False,
            )

            os.chdir(srcdir / pkg)
            subprocess.run(["makepkg", "-f"], check=False)

        print("\nProjects that were updated:\n")
    else:
        print("\nProjects available for update:\n")

    log_path = srcdir / f"{Path(sys.argv[0]).name}.log"
    log_path.write_text("\n".join(unique_projects) + "\n", encoding="utf-8")
    for project in unique_projects:
        print(project)


def pacman_package_name(path: Path) -> str:
    return command_output(
        ["pacman", "-Updd", os.fspath(path), "--print-format", "%n"]
    ).strip()


def pacman_package_version(path: Path) -> str:
    return command_output(
        ["pacman", "-Updd", os.fspath(path), "--print-format", "%v"]
    ).strip()


def installed_package_version(package: str) -> str:
    output = command_output(["pacman", "-Qi", package])
    match = VERSION_LINE_RE.search(output)
    if not match:
        return ""

    tail = output[match.start() :].splitlines()[0]
    result = TRAILING_NONSPACE_RE.search(tail)
    return result.group(0) if result else ""


def vercmp(left: str, right: str) -> int | None:
    result = run(["vercmp", left, right], capture=True, check=False)
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def is_fuse_mount(path: Path) -> bool:
    r"""
    Preserve the Bash test:

      stat --file-system --format=%T $(stat --format=%m "$tgtdir") | grep -Pio fuse
    """
    try:
        mountpoint = command_output(
            ["stat", "--format=%m", os.fspath(path)]
        ).strip()
        if not mountpoint:
            return False
        fs_type = command_output(
            ["stat", "--file-system", "--format=%T", mountpoint]
        ).strip()
        return bool(re.search("fuse", fs_type, re.IGNORECASE))
    except OSError:
        return False


def install(config: dict) -> None:
    tgtdir = Path(config["target"])
    myprnt: list[str] = []

    if yes_response("Show installed up to date projects. [y/N] "):
        print("Up to date:")
        chse = True
    else:
        print("Out of date:")
        chse = False

    for value in find_packages(tgtdir):
        mydeb = pacman_package_name(value)
        myhash = pacman_package_version(value)
        mychk = installed_package_version(mydeb)

        if chse:
            if mychk and myhash:
                comparison = vercmp(mychk, myhash)
                if comparison == 0:
                    myprnt.append(
                        f"pacman({mychk})  alpm({myhash}) - {mydeb}"
                    )
        else:
            if mychk and myhash:
                comparison = vercmp(mychk, myhash)
                if comparison is not None and comparison != 0:
                    if comparison < 0:
                        print(
                            f"{mydeb} ({mychk}) is older than ({myhash}), updating..."
                        )

                        if is_fuse_mount(tgtdir):
                            tmp_value = Path("/tmp") / value.name
                            shutil.copy2(value, tmp_value)
                            subprocess.run(
                                [
                                    "sudo",
                                    "pacman",
                                    "-U",
                                    "--noconfirm",
                                    os.fspath(tmp_value),
                                ],
                                check=False,
                            )
                            try:
                                tmp_value.unlink()
                            except FileNotFoundError:
                                pass
                        else:
                            subprocess.run(
                                [
                                    "sudo",
                                    "pacman",
                                    "-U",
                                    "--noconfirm",
                                    os.fspath(value),
                                ],
                                check=False,
                            )

    if myprnt:
        print()
        # Bash: sort -k 3. These strings are deliberately formatted to retain
        # that ordering behavior.
        for line in sorted(myprnt, key=lambda s: s.split()[2:] if len(s.split()) > 2 else [s]):
            print(line)


def find_packages(tgtdir: Path) -> list[Path]:
    r"""
    Bash equivalent of the -i find:
      find -H "$tgtdir" -type f
        ! \( -ipath '*/.*' \)
        -iregex '.*\\.pkg\\.tar\\.(xz|zst)'
        -printf '%p\\n' | sort
    """
    found: list[Path] = []
    pattern = re.compile(r"\.pkg\.tar\.(xz|zst)$", re.IGNORECASE)

    if not tgtdir.is_dir():
        return []

    for root, dirs, files in os.walk(tgtdir, followlinks=False):
        # Bash excludes hidden paths anywhere in the path.
        rel = Path(root).relative_to(tgtdir)
        if any(part.startswith(".") for part in rel.parts):
            dirs[:] = []
            continue

        for name in files:
            path = Path(root) / name
            rel_parts = path.relative_to(tgtdir).parts
            if any(part.startswith(".") for part in rel_parts):
                continue
            if pattern.search(name):
                found.append(path)

    return sorted(found, key=lambda p: str(p))


def find_move_packages(config: dict) -> list[Path]:
    r"""
    Bash:
      find -L {"$HOME/.cache/yay","$srcdir"} -maxdepth 3 -type f ...
    """
    roots = [
        Path("~/.cache/yay").expanduser(),
        Path(config["source"]),
    ]
    found: list[Path] = []
    pattern = re.compile(r"\.pkg\.tar\.(xz|zst)$", re.IGNORECASE)

    for root in roots:
        if not root.exists():
            continue

        # Implement find -L with a bounded walk. Symlink directories are
        # followed; visited real directories prevent accidental cycles.
        visited: set[str] = set()

        def walk(current: Path, depth: int) -> None:
            if depth > 3:
                return
            try:
                real = os.path.realpath(current)
                if real in visited:
                    return
                visited.add(real)
                entries = list(current.iterdir())
            except OSError:
                return

            for entry in entries:
                try:
                    if entry.is_file():
                        if pattern.search(entry.name):
                            found.append(entry)
                    elif entry.is_dir():
                        if depth < 3:
                            walk(entry, depth + 1)
                except OSError:
                    pass

        walk(root, 1)

    return sorted(found, key=lambda p: str(p))


def find_matching_target_packages(tgtdir: Path, package_name: str, newer_than: Path) -> list[Path]:
    pattern = re.compile(
        rf".*/{re.escape(package_name)}.*\.pkg\.tar\.(xz|zst)$",
        re.IGNORECASE,
    )
    found: list[Path] = []

    if not tgtdir.is_dir():
        return found

    try:
        source_mtime = newer_than.stat().st_mtime
    except OSError:
        return found

    for root, dirs, files in os.walk(tgtdir, followlinks=False):
        # Bash excludes only paths containing .trash* for this find.
        dirs[:] = [
            d for d in dirs
            if ".trash" not in d
        ]

        for name in files:
            path = Path(root) / name
            if ".trash" in str(path):
                continue
            if not pattern.fullmatch(str(path)):
                continue

            try:
                if path.stat().st_mtime > source_mtime:
                    continue
            except OSError:
                continue

            found.append(path)

    return sorted(found, key=lambda p: str(p))


def move(config: dict) -> None:
    srcdir = Path(config["source"])
    tgtdir = Path(config["target"])
    dldir = Path(config["download"])
    myprnt: list[str] = []

    if yes_response(f"Delete {tgtdir} alpm and replace with newer? [y/N] "):
        print("Updating ...")

        for value in find_move_packages(config):
            mydeb = pacman_package_name(value)
            myhash: Path | None = None

            for pkg in find_matching_target_packages(tgtdir, mydeb, value):
                try:
                    if pacman_package_name(pkg) == mydeb:
                        myhash = pkg
                        break
                except Exception:
                    pass

            if myhash is not None:
                try:
                    trash_result = subprocess.run(
                        ["trash", "-f", os.fspath(myhash)], check=False
                    )
                except FileNotFoundError:
                    print(
                        f"repochk: 'trash' command not found. Cannot safely trash {myhash}",
                        file=sys.stderr,
                    )
                    continue

                if trash_result.returncode != 0:
                    print(
                        f"repochk: could not trash {myhash}; not replacing it",
                        file=sys.stderr,
                    )
                    continue

                destination = myhash.parent / value.name
                try:
                    shutil.move(os.fspath(value), os.fspath(destination))
                except OSError as exc:
                    print(
                        f"repochk: failed to move {value.name} to {destination}: {exc}",
                        file=sys.stderr,
                    )
                    continue

                # Post-operation verification: confirm target package exists
                if destination.exists():
                    myprnt.append(f"Trashed {myhash}")
                    myprnt.append(f"Replaced by {value}")
                else:
                    print(
                        f"repochk: move appeared to succeed, but destination file {destination} was not created",
                        file=sys.stderr,
                    )

    else:
        print(f"Moving alpm to {dldir} ...")
        dldir.mkdir(parents=True, exist_ok=True)

        for value in find_move_packages(config):
            destination = dldir / value.name
            try:
                shutil.move(os.fspath(value), os.fspath(destination))
            except OSError as exc:
                print(
                    f"repochk: failed to move {value.name} to {dldir}: {exc}",
                    file=sys.stderr,
                )

    if myprnt:
        print()
        for line in myprnt:
            print(line)


def normalize_tag(tag: str) -> str:
    # Bash perl -pe 's|[[:punct:]]|.|g'
    return re.sub(r"[^\w\s]", ".", tag, flags=re.ASCII)


def version_sort(values: Iterable[str]) -> list[str]:
    r"""
    Natural-ish version ordering corresponding to GNU sort -V for the tag
    strings used by this utility.
    """
    def key(value: str):
        parts = re.split(r"(\d+)", value)
        return tuple(int(p) if p.isdigit() else p for p in parts)

    return sorted(values, key=key)


def git_tags(all_tags: bool) -> list[str]:
    result = run(["git", "show", "-s", "--pretty=format:%h"], check=False)
    if result.returncode != 0:
        return []

    output = command_output(["git", "ls-remote", "-q", "--tags", "--refs"])
    tags: list[str] = []

    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        ref = fields[1]
        tag = ref.rsplit("/", 1)[-1]
        match = VERSION_TAG_RE.search(tag)
        if match:
            tags.append(normalize_tag(match.group(0)))

    result_tags = version_sort(tags)
    return result_tags if all_tags else result_tags[-1:] if result_tags else []


def hg_tags(all_tags: bool) -> list[str]:
    result = run(["hg", "identify"], check=False)
    if result.returncode != 0:
        return []

    output = command_output(["hg", "tags"])
    tags: list[str] = []

    for line in output.splitlines():
        match = VERSION_TAG_RE.search(line)
        if match:
            tags.append(normalize_tag(match.group(0)))

    result_tags = version_sort(tags)
    return result_tags if all_tags else result_tags[-1:] if result_tags else []


def tags() -> None:
    all_tags = yes_response("All tags? [y/N] ")

    values = git_tags(all_tags)
    for value in values:
        print(value)

    values = hg_tags(all_tags)
    for value in values:
        print(value)


def lxc(config: dict) -> None:
    lxc32 = config["lxc32"]

    # Preserve the Bash test:
    # sudo grep -ioa 'container=lxc' /proc/1/environ
    result = subprocess.run(
        ["sudo", "grep", "-ioa", "container=lxc", "/proc/1/environ"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )

    if not result.stdout.strip():
        info = subprocess.run(
            ["sudo", "lxc-info", "-n", lxc32],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

        if not re.search(r"running", info.stdout, re.IGNORECASE):
            start_result = subprocess.run(
                ["sudo", "lxc-start", "-n", lxc32],
                check=False,
            )
            # Bash uses && here: attach only when lxc-start succeeds.
            if start_result.returncode == 0:
                subprocess.run(
                    ["sudo", "lxc-attach", "-n", lxc32, "--", "login", os.environ.get("LOGNAME", "")],
                    check=False,
                )
        else:
            subprocess.run(["sudo", "lxc-stop", "-n", lxc32], check=False)
    else:
        subprocess.run(["sudo", "shutdown", "-h", "now"], check=False)


def main() -> int:
    config = load_config()

    srcdir = Path(config["source"])
    tgtdir = Path(config["target"])
    dldir = Path(config["download"])

    dirs_exist = True
    if not srcdir.is_dir():
        print(f"Source tree {srcdir} doesn't exist.")
        dirs_exist = False
    if not tgtdir.is_dir():
        print(f"Backup folder {tgtdir} doesn't exist.")
        dirs_exist = False
    if not dldir.is_dir():
        print(f"Temp folder {dldir} doesn't exist.")
        dirs_exist = False

    if not dirs_exist:
        return 0

    if len(sys.argv) < 2:
        usage("one option required, patch name optional")
        return 0

    arg = sys.argv[1]

    if arg in ("-b", "--build"):
        build(config)
    elif arg in ("-i", "--install"):
        install(config)
    elif arg in ("-l", "--lxc"):
        lxc(config)
    elif arg in ("-m", "--move"):
        move(config)
    elif arg in ("-t", "--tags"):
        tags()
    else:
        usage(f"invalid option {arg}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
