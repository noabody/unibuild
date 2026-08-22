#!/usr/bin/env python3
# Version 1.0 - Python Port of wstart (Standardized Architecture)

import os
import sys
import re
import json
import shutil
import tarfile
import urllib.request
import subprocess
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, List, Dict, Tuple, Any

import pefile

# --- Constants & Environment Defaults ---

ANSI_CLEAR = "\033[H\033[2J"

CONFIG_DIR = Path.home() / ".config" / "wstart"
CONFIG_FILE = CONFIG_DIR / "config.json"
SLOTS_FILE = CONFIG_DIR / "slots.json"

DEFAULT_CONFIG = {
    "wnbin": ["/usr", str(Path.home() / ".local" / "opt")],
    "wnpfx": [str(Path.home()), str(Path.home() / ".wineprefixes")],
    "pntop": str(Path.home() / ".steam"),
    "pnapp": str(Path.home() / ".steam" / "steam" / "steamapps"),
    "pnbin": [
        str(Path.home() / ".steam" / "steam" / "steamapps" / "common"),
        str(Path.home() / ".local" / "share" / "Steam" / "steamapps" / "common")
    ],
    "pnpfx": [
        str(Path.home() / ".steam" / "steam" / "steamapps" / "compatdata"),
        str(Path.home() / ".local" / "share" / "Steam" / "steamapps" / "compatdata")
    ],
    "pnpge": str(Path.home() / ".steam" / "root" / "compatibilitytools.d"),
    "progs": "drive_c/Program Files",
    "stcmn": "Steam/steamapps/common",
    "desk": str(Path.home() / "Desktop"),
    "icon": "applications-other",
    "temp": str(Path.home() / "Downloads")
}

PMENU = [
    ("Command Prompt", "wineconsole.exe"),
    ("Control Panel", "control.exe"),
    ("Registry Editor", "regedit.exe"),
    ("Task Manager", "taskmgr.exe"),
    ("Windows Explorer", "explorer.exe"),
    ("Wine Configuration", "winecfg.exe")
]


# --- Data Models & Pipeline Objects ---

@dataclass
class SlotConfig:
    bin: str
    pfx: str
    args: List[str] = field(default_factory=list)
    use_wine_loader: Optional[bool] = None
    cmd: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        data = {"bin": self.bin, "pfx": self.pfx, "args": self.args}
        if self.use_wine_loader is not None:
            data["use_wine_loader"] = self.use_wine_loader
        if self.cmd is not None:
            data["cmd"] = self.cmd
        return data

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SlotConfig":
        return cls(
            bin=data.get("bin", ""),
            pfx=data.get("pfx", ""),
            args=data.get("args", []),
            use_wine_loader=data.get("use_wine_loader"),
            cmd=data.get("cmd")
        )


@dataclass(frozen=True)
class LaunchConfig:
    """Immutable data object encapsulating the execution context."""
    cmd: List[str]
    env: Dict[str, str]
    cwd: Optional[Path] = None


# --- Terminal UI Layer ---

class TerminalUI:
    @staticmethod
    def clear() -> None:
        print(ANSI_CLEAR, end="")

    @staticmethod
    def prompt_input(prompt_text: str, default: str = "") -> str:
        try:
            val = input(prompt_text).strip()
            return val if val else default
        except (KeyboardInterrupt, EOFError):
            print("\nExiting.")
            sys.exit(0)

    @staticmethod
    def display_menu(options: List[str]) -> str:
        opts = list(options)
        if "quit" not in opts:
            opts.append("quit")

        while True:
            for i, opt in enumerate(opts, 1):
                print(f"{i}) {opt}")

            try:
                choice = input("Please enter your choice: ").strip()
                if not choice:
                    continue
                idx = int(choice)
                if 1 <= idx <= len(opts):
                    selected = opts[idx - 1]
                    if selected == "quit":
                        sys.exit(0)
                    TerminalUI.clear()
                    return selected
            except (ValueError, KeyboardInterrupt, EOFError):
                pass


# --- System & File Helpers ---

def load_json(path: Path, default: dict) -> dict:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(default, f, indent=4)
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
            for k, v in default.items():
                if k not in loaded:
                    loaded[k] = v
            return loaded
    except Exception:
        return default


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4)


def resolve_array_paths(val: Any) -> List[Path]:
    if isinstance(val, str):
        val = [val]
    elif not isinstance(val, list):
        val = []
    return [Path(os.path.expanduser(p)).resolve() for p in val]


def is_fuse_fs(path: Path) -> bool:
    try:
        res = subprocess.run(
            ['stat', '--file-system', '--format=%T', str(path)],
            capture_output=True, text=True, check=True
        )
        return 'fuse' in res.stdout.lower()
    except Exception:
        return False


def is_valid_gui_exe(file_path: Path) -> bool:
    pe = None
    try:
        pe = pefile.PE(str(file_path), fast_load=True)
        subsystem = getattr(pe.OPTIONAL_HEADER, 'Subsystem', None)
        if subsystem != 2:
            pe.close()
            return False

        pe.parse_data_directories(directories=[
            pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE']
        ])

        has_icon = False
        if hasattr(pe, 'DIRECTORY_ENTRY_RESOURCE'):
            for entry in pe.DIRECTORY_ENTRY_RESOURCE.entries:
                res_id = getattr(entry, 'id', None)
                if res_id is None and hasattr(entry, 'struct'):
                    res_id = getattr(entry.struct, 'Id', None)

                if res_id in (3, 14):
                    has_icon = True
                    break

        pe.close()
        return has_icon
    except Exception:
        if pe:
            try:
                pe.close()
            except Exception:
                pass
        return False


def find_executables(search_path: Path, filtered: bool = True, filter_pattern: Optional[str] = None) -> List[str]:
    found = []
    skip = {"cache", "microsoft", "windows", "temp"}
    bad = re.compile(
        r'.*(capture|clokspl|helper|iexplore|install|internal|kernel|'
        r'[^ ]launcher|legacypm|overlay|proxy|redist|renderer|'
        r'(crash|error)reporter|serv(er|ice)|setup|streaming|tutorial|'
        r'unins|update).*', re.I
    )

    skip_pe_check = is_fuse_fs(search_path)

    for base, dirs, files in os.walk(search_path):
        try:
            rel_depth = len(Path(base).relative_to(search_path).parts)
        except ValueError:
            rel_depth = 0

        if rel_depth >= 7:
            dirs[:] = []
            continue

        if filtered and any(s in base.lower() for s in skip):
            dirs[:] = []
            continue

        for f in files:
            pattern = filter_pattern if filter_pattern else "*.exe"
            if f.lower().endswith(pattern.replace("*", "")):
                if filtered and bad.match(f):
                    continue

                full_p = Path(base) / f
                if not filter_pattern and not skip_pe_check:
                    if not is_valid_gui_exe(full_p):
                        continue

                rel = full_p.relative_to(search_path)
                found.append(str(rel))

    return sorted(found)


# --- Runner Strategy Abstractions ---

class BaseRunner(ABC):
    """Abstract Strategy representing a runtime environment engine."""

    def __init__(self, cfg: dict, ui: TerminalUI):
        self.cfg = cfg
        self.ui = ui
        self.bin_path: Optional[Path] = None
        self.pfx_path: Optional[Path] = None
        self.is_64bit: bool = False
        self.wine_bin_name: str = "wine"

    @property
    @abstractmethod
    def mode_prefix(self) -> str:
        """Return 'w' for Wine, 'p' for Proton."""
        pass

    @property
    @abstractmethod
    def search_depths(self) -> Tuple[int, int]:
        """Depth search tuples (bin_depth, pfx_depth)."""
        pass

    @abstractmethod
    def locate_binary(self, bin_roots: List[Path]) -> Path:
        pass

    @abstractmethod
    def resolve_prefix(self, pfx_roots: List[Path]) -> Path:
        pass

    @abstractmethod
    def create_default_prefix(self, default_pfx_root: Path, pntop: Path) -> Path:
        pass

    @abstractmethod
    def build_launch_config(
        self,
        target_cmd: List[str],
        cwd: Optional[Path] = None,
        use_wine_loader: Optional[bool] = None
    ) -> LaunchConfig:
        pass

    def configure_arch(self) -> None:
        if self.pfx_path and (self.pfx_path / "drive_c" / "windows" / "syswow64").exists():
            self.configure_64bit()
        else:
            self.configure_32bit()

    def configure_64bit(self) -> None:
        self.is_64bit = True
        bin_dir = self.bin_path / "bin" if self.bin_path else Path("/usr/bin")
        wine64_bin = bin_dir / "wine64"
        self.wine_bin_name = "wine64" if wine64_bin.is_file() else "wine"

    def configure_32bit(self) -> None:
        self.is_64bit = False
        self.wine_bin_name = "wine"

    def _get_library_paths(self) -> Tuple[str, str]:
        prefix = str(self.bin_path) if self.bin_path else "/usr"
        if self.is_64bit:
            return f"{prefix}/lib64:{prefix}/lib", f"{prefix}/lib64/wine:{prefix}/lib/wine"
        return f"{prefix}/lib", f"{prefix}/lib/wine"


class WineRunner(BaseRunner):
    @property
    def mode_prefix(self) -> str:
        return "w"

    @property
    def search_depths(self) -> Tuple[int, int]:
        return (3, 2)

    def locate_binary(self, bin_roots: List[Path]) -> Path:
        found = []
        for root in bin_roots:
            if not root.exists():
                continue
            for base, dirs, files in os.walk(root, followlinks=True):
                base_path = Path(base)
                try:
                    rel_depth = len(base_path.relative_to(root).parts)
                except ValueError:
                    rel_depth = 0

                if rel_depth >= self.search_depths[0]:
                    dirs[:] = []
                    continue

                if "sbin" in base_path.parts:
                    continue

                for f in files:
                    if f.lower() == "wine":
                        wine_root = base_path.parent if base_path.name == "bin" else base_path
                        try:
                            display_rel = wine_root.relative_to(root)
                            display_name = str(display_rel) if str(display_rel) != "." else root.name
                        except ValueError:
                            display_name = wine_root.name
                        found.append((display_name, wine_root))

        unique_opts = {name: path for name, path in found}
        if len(unique_opts) > 1:
            sel = self.ui.display_menu(sorted(list(unique_opts.keys())))
            self.bin_path = unique_opts[sel]
        elif len(unique_opts) == 1:
            self.bin_path = list(unique_opts.values())[0]
        else:
            print("No installed Wine found.")
            sys.exit(1)
        return self.bin_path

    def resolve_prefix(self, pfx_roots: List[Path]) -> Path:
        found_pfx = []
        for pfx_root in pfx_roots:
            if not pfx_root.is_dir():
                continue
            for base, dirs, files in os.walk(pfx_root):
                base_path = Path(base)
                try:
                    rel_depth = len(base_path.relative_to(pfx_root).parts)
                except ValueError:
                    rel_depth = 0

                if rel_depth > self.search_depths[1]:
                    dirs[:] = []
                    continue

                for f in files:
                    if f.lower() == "system.reg":
                        try:
                            rel = base_path.relative_to(pfx_root)
                            rel_str = str(rel) if str(rel) != "." else pfx_root.name
                        except ValueError:
                            rel_str = base_path.name
                        found_pfx.append((rel_str, base_path))

        unique_pfx = {label: full_path for label, full_path in found_pfx}
        if len(unique_pfx) > 1:
            sel_label = self.ui.display_menu(sorted(list(unique_pfx.keys())))
            self.pfx_path = unique_pfx[sel_label]
        elif len(unique_pfx) == 1:
            self.pfx_path = list(unique_pfx.values())[0]
        else:
            default_root = pfx_roots[0] if pfx_roots else Path.home() / ".wine"
            self.pfx_path = self.create_default_prefix(default_root, Path.home())

        self.configure_arch()
        return self.pfx_path

    def create_default_prefix(self, default_pfx_root: Path, pntop: Path) -> Path:
        default_pfx = default_pfx_root if default_pfx_root.name == ".wine" else default_pfx_root / ".wine"
        if not default_pfx.is_dir():
            print(f"Creating default prefix: {default_pfx}")
            default_pfx.mkdir(parents=True, exist_ok=True)

            env = os.environ.copy()
            env["WINEPREFIX"] = str(default_pfx)

            winecfg = (self.bin_path / "bin" / "winecfg" if (self.bin_path / "bin").is_dir() else self.bin_path / "winecfg") if self.bin_path else Path("/usr/bin/winecfg")
            subprocess.Popen([str(winecfg)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            home_wine = Path.home() / ".wine"
            if home_wine.exists() and home_wine != default_pfx:
                if home_wine.is_symlink() or home_wine.is_file():
                    home_wine.unlink()
                else:
                    shutil.rmtree(home_wine)
                home_wine.symlink_to(default_pfx)
        return default_pfx

    def build_launch_config(
        self,
        target_cmd: List[str],
        cwd: Optional[Path] = None,
        use_wine_loader: Optional[bool] = None
    ) -> LaunchConfig:
        ldl, dll = self._get_library_paths()
        xpath = f"{self.bin_path}/bin:{os.environ.get('PATH', '')}" if self.bin_path else os.environ.get('PATH', '')
    
        env = {
            "PATH": xpath,
            "WINEDLLPATH": dll,
            "LD_LIBRARY_PATH": ldl,
        }
        if self.pfx_path:
            env["WINEPREFIX"] = str(self.pfx_path)
    
        exec_cmd = [self.wine_bin_name, *target_cmd]
        return LaunchConfig(cmd=exec_cmd, env=env, cwd=cwd)


class ProtonRunner(BaseRunner):
    @property
    def mode_prefix(self) -> str:
        return "p"

    @property
    def search_depths(self) -> Tuple[int, int]:
        return (4, 3)

    def locate_binary(self, bin_roots: List[Path]) -> Path:
        found = []
        for root in bin_roots:
            if not root.exists():
                continue
            for base, dirs, files in os.walk(root, followlinks=True):
                base_path = Path(base)
                try:
                    rel_depth = len(base_path.relative_to(root).parts)
                except ValueError:
                    rel_depth = 0

                if rel_depth >= self.search_depths[0]:
                    dirs[:] = []
                    continue

                if "sbin" in base_path.parts:
                    continue

                for f in files:
                    if f.lower() == "wine":
                        wine_root = base_path.parent if base_path.name == "bin" else base_path
                        try:
                            display_rel = wine_root.relative_to(root)
                            display_name = str(display_rel) if str(display_rel) != "." else root.name
                        except ValueError:
                            display_name = wine_root.name
                        found.append((display_name, wine_root))

        unique_opts = {name: path for name, path in found}
        if len(unique_opts) > 1:
            sel = self.ui.display_menu(sorted(list(unique_opts.keys())))
            self.bin_path = unique_opts[sel]
        elif len(unique_opts) == 1:
            self.bin_path = list(unique_opts.values())[0]
        else:
            print("No installed Proton found.")
            sys.exit(1)
        return self.bin_path

    def get_proton_app_map(self, pnapp: Path, valid_app_ids: Optional[set] = None) -> Dict[str, str]:
        app_map = {}
        if not pnapp.exists():
            return app_map

        for mf in pnapp.glob("appmanifest_*.acf"):
            try:
                content = mf.read_text(encoding="utf-8", errors="ignore")
                appid_match = re.search(r'"appid"\s+"(\d+)"', content)
                name_match = re.search(r'"name"\s+"([^"]+)"', content)
                if appid_match and name_match:
                    app_id = appid_match.group(1)
                    if valid_app_ids is None or app_id in valid_app_ids:
                        app_map[app_id] = name_match.group(1)
            except Exception:
                continue
        return app_map

    def resolve_prefix(self, pfx_roots: List[Path]) -> Path:
        found_pfx = []
        for pfx_root in pfx_roots:
            if not pfx_root.is_dir():
                continue
            for base, dirs, files in os.walk(pfx_root):
                base_path = Path(base)
                try:
                    rel_depth = len(base_path.relative_to(pfx_root).parts)
                except ValueError:
                    rel_depth = 0

                if rel_depth > self.search_depths[1]:
                    dirs[:] = []
                    continue

                for f in files:
                    if f.lower() == "system.reg":
                        try:
                            rel = base_path.relative_to(pfx_root)
                            rel_str = str(rel) if str(rel) != "." else pfx_root.name
                        except ValueError:
                            rel_str = base_path.name
                        found_pfx.append((rel_str, base_path))

        unique_pfx = {label: full_path for label, full_path in found_pfx}
        if len(unique_pfx) > 1:
            pfx_app_ids = {Path(k).parts[0] for k in unique_pfx.keys()}
            pnapp = Path(self.cfg.get("pnapp", Path.home() / ".steam" / "steam" / "steamapps")).expanduser()
            app_map = self.get_proton_app_map(pnapp, valid_app_ids=pfx_app_ids)

            if app_map:
                for app_id, name in sorted(app_map.items(), key=lambda item: int(item[0]) if item[0].isdigit() else item[0]):
                    print(f"{app_id}  {name}")

            sel_label = self.ui.display_menu(sorted(list(unique_pfx.keys())))
            self.pfx_path = unique_pfx[sel_label]
        elif len(unique_pfx) == 1:
            self.pfx_path = list(unique_pfx.values())[0]
        else:
            default_root = pfx_roots[0] if pfx_roots else Path.home() / ".steam" / "steam" / "steamapps" / "compatdata"
            pntop = Path(self.cfg.get("pntop", Path.home() / ".steam")).expanduser()
            self.pfx_path = self.create_default_prefix(default_root, pntop)

        if self.pfx_path and self.pfx_path.name != "pfx" and (self.pfx_path / "pfx").is_dir():
            self.pfx_path = self.pfx_path / "pfx"

        self.configure_arch()
        return self.pfx_path

    def create_default_prefix(self, default_pfx_root: Path, pntop: Path) -> Path:
        pfx0 = default_pfx_root / "0"
        if not pfx0.is_dir():
            print(f"Creating default prefix: {pfx0}")
            pfx0.mkdir(parents=True, exist_ok=True)

            env = os.environ.copy()
            env["STEAM_COMPAT_DATA_PATH"] = str(pfx0)
            env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = str(pntop)

            proton_bin = self.bin_path.parent / "proton" if self.bin_path else Path("/usr/bin/proton")
            subprocess.Popen([str(proton_bin), "run"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return pfx0 / "pfx"

    def build_launch_config(
        self,
        target_cmd: List[str],
        cwd: Optional[Path] = None,
        use_wine_loader: Optional[bool] = None
    ) -> LaunchConfig:
        ldl, dll = self._get_library_paths()
        xpath = f"{self.bin_path}/bin:{os.environ.get('PATH', '')}" if self.bin_path else os.environ.get('PATH', '')
    
        pntop = Path(self.cfg.get("pntop", Path.home() / ".steam")).expanduser()
        compat_data_dir = self.pfx_path.parent if self.pfx_path and self.pfx_path.name == "pfx" else self.pfx_path
    
        env = {
            "PATH": xpath,
            "WINEDLLPATH": dll,
            "LD_LIBRARY_PATH": ldl,
            "STEAM_COMPAT_CLIENT_INSTALL_PATH": str(pntop)
        }
        if self.pfx_path:
            env["WINEPREFIX"] = str(self.pfx_path)
        if compat_data_dir:
            env["STEAM_COMPAT_DATA_PATH"] = str(compat_data_dir)
    
        if use_wine_loader:
            exec_cmd = [self.wine_bin_name, *target_cmd]
        else:
            proton_bin = self.bin_path.parent / "proton" if (self.bin_path and (self.bin_path.parent / "proton").exists()) else Path("/usr/bin/proton")
            exec_cmd = [str(proton_bin), "run", *target_cmd]
    
        return LaunchConfig(cmd=exec_cmd, env=env, cwd=cwd)


# --- CLI Compatibility Adapter ---

@dataclass
class ParsedCLI:
    mode: str          # 'w', 'p', or ''
    slot_num: Optional[int]
    action: str        # e.g., '-xa', '-xb', '-xc', etc.
    raw_arg1: str
    clprm: List[str]

    @classmethod
    def parse(cls, argv: List[str]) -> "ParsedCLI":
        arg1 = argv[1] if len(argv) > 1 else ""
        clprm = argv[2:] if len(argv) > 1 else []

        m = re.search(r'-([wp])', arg1, re.I)
        mode = m.group(1).lower() if m else ""

        slot_match = re.search(r'-[wp][a-z]*(\d+)', arg1, re.I)
        slot_num = int(slot_match.group(1)) if slot_match else None

        if mode:
            xarg = re.sub(r'-[wp]', '-x', arg1, flags=re.I)
        else:
            xarg = re.sub(r'-x+', '-', arg1, flags=re.I)

        action = re.sub(r'\d+$', '', xarg).lower()
        return cls(mode=mode, slot_num=slot_num, action=action, raw_arg1=arg1, clprm=clprm)


# --- Execution Engine ---

class WStartEngine:
    def __init__(self):
        self.ui = TerminalUI()
        self.cfg = load_json(CONFIG_FILE, DEFAULT_CONFIG)

        raw_slots = load_json(SLOTS_FILE, {})
        self.slots: Dict[str, SlotConfig] = {
            k: SlotConfig.from_dict(v) for k, v in raw_slots.items()
        }

        self.cli = ParsedCLI.parse(sys.argv)
        self.runner: BaseRunner = ProtonRunner(self.cfg, self.ui) if self.cli.mode == "p" else WineRunner(self.cfg, self.ui)

        self.pntop = Path(self.cfg.get("pntop", "~/.steam")).expanduser()
        default_pnapp = str(self.pntop / "steam" / "steamapps")
        self.pnapp = Path(self.cfg.get("pnapp", default_pnapp)).expanduser()

        if self.cli.mode == "p":
            self.bin_roots = resolve_array_paths(self.cfg.get("pnbin", []))
            self.pfx_roots = resolve_array_paths(self.cfg.get("pnpfx", []))
        else:
            self.bin_roots = resolve_array_paths(self.cfg.get("wnbin", []))
            self.pfx_roots = resolve_array_paths(self.cfg.get("wnpfx", []))

        self.pedir: Optional[Path] = None
        self.xmrtn: Optional[str] = None
        self.xflt: Optional[str] = None
        self.use_wine_loader: Optional[bool] = None
        self.cached_cmd: Optional[str] = None

    def save_slots(self) -> None:
        save_json(SLOTS_FILE, {k: v.to_dict() for k, v in self.slots.items()})

    def usage(self, err_msg: str = "") -> None:
        prog = os.path.basename(sys.argv[0])
        if err_msg:
            print(f"\n{prog}: ERROR - {err_msg}", file=sys.stderr)
        print(f"\nusage: {prog}\n"
              " [-?a,--?add] [-?b,--?bld] [-?c,--?cmd] [-?d,--?dsk]\n"
              " [-?i,--?inf] [-?k,--?kil] [-?o,--?ovr] [-?p,--?prg]\n"
              " [-?s,--?stm] [-?t,--?trk] [-?u,--?cut] [-?v,--?ver]\n\n"
              "[?] = (p)roton, (w)ine\n"
              " (add) exe path to reg, (bld) build prefix,\n"
              " (cmd) prog menu, (dsk) desktop, (inf) exe info,\n"
              " (kil) kill wine, (ovr) overrides, (prg) exe list,\n"
              " (stm) steam, (trk) winetricks, (cut) shortcut,\n"
              " (ver) wine version\n", file=sys.stderr)
        sys.exit(1 if err_msg else 0)

    def execute_launch(self, config: LaunchConfig, detach: bool = True) -> None:
        dbg = os.environ.get("dbg", "")
        full_env = os.environ.copy()
        full_env.update(config.env)
    
        if dbg:
            env_vars_str = " ".join(f"{k}={v}" for k, v in config.env.items())
            cmd_str = " ".join(config.cmd)
            print(f"env {env_vars_str} {cmd_str}")
    
        if not detach:
            subprocess.run(config.cmd, env=full_env, cwd=config.cwd)
        else:
            if not dbg:
                subprocess.Popen(
                    config.cmd,
                    env=full_env,
                    cwd=config.cwd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True
                )
            else:
                if dbg == "2":
                    full_env["WINEDEBUG"] = "warn+all"
                subprocess.Popen(config.cmd, env=full_env, cwd=config.cwd)

    def resolve_loader_choice(self) -> None:
        if self.cli.mode == "p" and self.use_wine_loader is None:
            chse = self.ui.prompt_input("wine loader? [y/N] ").lower()
            self.use_wine_loader = chse in ["y", "yes"]

            slot_key = f"{self.cli.mode}_{self.cli.slot_num}" if self.cli.slot_num else None
            if slot_key and slot_key in self.slots:
                self.slots[slot_key].use_wine_loader = self.use_wine_loader
                self.save_slots()

    def load_slot_config(self, slot_key: str) -> None:
        slot = self.slots.get(slot_key)
        if not slot:
            return

        if slot.bin:
            self.runner.bin_path = Path(slot.bin)
        if slot.pfx:
            self.runner.pfx_path = Path(slot.pfx)

        if slot.use_wine_loader is not None:
            self.use_wine_loader = slot.use_wine_loader

        if slot.cmd:
            self.cached_cmd = slot.cmd

        resolved_cli_args = []
        for arg in self.cli.clprm:
            p = Path(arg).expanduser()
            if p.exists():
                resolved_cli_args.append(str(p.resolve()))
            else:
                resolved_cli_args.append(arg)

        self.cli.clprm = slot.args + resolved_cli_args

    def apply_slot_config(self) -> None:
        slot_key = f"{self.cli.mode}_{self.cli.slot_num}" if self.cli.slot_num is not None else None

        if self.cli.slot_num == 0:
            keys_to_remove = [k for k in self.slots if k.startswith(f"{self.cli.mode}_")]
            if keys_to_remove:
                for k in keys_to_remove:
                    del self.slots[k]
                self.save_slots()
                print(f"Cleared slot configuration for mode '{self.cli.mode}'.")

            self.runner.locate_binary(self.bin_roots)
            self.runner.resolve_prefix(self.pfx_roots)
            return

        if slot_key and slot_key in self.slots:
            cached = self.slots[slot_key]
            if Path(cached.bin).exists() and Path(cached.pfx).exists():
                self.load_slot_config(slot_key)
                self.runner.configure_arch()
                return

        self.runner.locate_binary(self.bin_roots)
        self.runner.resolve_prefix(self.pfx_roots)

        if slot_key and self.cli.slot_num > 0:
            self.slots[slot_key] = SlotConfig(
                bin=str(self.runner.bin_path),
                pfx=str(self.runner.pfx_path),
                args=self.cli.clprm if self.cli.clprm else [],
                use_wine_loader=self.use_wine_loader
            )
            self.save_slots()

    def select_program_menu(self) -> None:
        if self.cli.clprm and Path(self.cli.clprm[0]).is_file():
            target_path = Path(self.cli.clprm[0]).resolve()
            self.pedir = target_path.parent
            self.xmrtn = target_path.name
        else:
            if self.cli.clprm and Path(self.cli.clprm[0]).is_dir():
                self.pedir = Path(self.cli.clprm[0]).resolve()
                exes = find_executables(self.pedir, filtered=False, filter_pattern=self.xflt)
            else:
                self.pedir = self.runner.pfx_path / "drive_c" if self.runner.pfx_path else Path.home() / ".wine" / "drive_c"
                exes = find_executables(self.pedir, filtered=True, filter_pattern=self.xflt)

            if len(exes) > 0:
                self.xmrtn = self.ui.display_menu(exes)

    def prepare_launch_target(self) -> None:
        if not self.pedir or not self.xmrtn:
            return

        exe_path = self.pedir / self.xmrtn
        try:
            with open(exe_path, "rb") as f:
                header = f.read(0x200)
                pe_off = int.from_bytes(header[0x3C:0x40], "little")
                magic = int.from_bytes(header[pe_off + 0x18:pe_off + 0x1A], "little")
                if magic == 0x10B and self.runner.pfx_path and (self.runner.pfx_path / "drive_c" / "windows" / "syswow64").is_dir():
                    self.runner.configure_32bit()
        except Exception:
            pass

        self.resolve_loader_choice()

    # --- Command Action Handlers ---

    def handle_add_to_path(self) -> None:
        self.runner.resolve_prefix(self.pfx_roots)
        self.select_program_menu()

        if not (self.xmrtn and self.pedir and self.runner.pfx_path):
            return

        target_dir = (self.pedir / self.xmrtn).parent if self.xmrtn else self.pedir
        ptadd = f"z:{target_dir}".replace("/", "\\")
        escaped_ptadd = ptadd.replace("\\", "\\\\")

        chse = self.ui.prompt_input("prepend to system path? [y/N] ").lower()
        self.ui.clear()

        if chse in ["y", "yes"]:
            reg_file = "system.reg"
            section_regex = re.compile(
                r'^\[System\\+(?:Current)?ControlSet\d*\\+Control\\+Session Manager\\+Environment\]',
                re.IGNORECASE
            )
            print_prefix = "HKLM\\"
            display_section = r"System\ControlSet001\Control\Session Manager\Environment"
        else:
            reg_file = "user.reg"
            section_regex = re.compile(r'^\[Environment\]', re.IGNORECASE)
            print_prefix = "HKCU\\"
            display_section = r"Environment"

        reg_path = self.runner.pfx_path / reg_file
        if not reg_path.exists():
            print(f"Registry file missing: {reg_path}")
            return

        raw_content = reg_path.read_text(encoding="utf-8", errors="ignore")
        nl = "\r\n" if "\r\n" in raw_content else "\n"
        lines = raw_content.splitlines()

        new_lines = []
        in_target = False
        path_found = False
        section_found = False

        for line in lines:
            stripped = line.strip()

            if stripped.startswith('['):
                if in_target and not path_found:
                    new_lines.append(f'"PATH"=str(2):"{escaped_ptadd}"')
                    print(f"{print_prefix}{display_section}:\n\n  {ptadd}\n\nPATH created successfully\n")
                    path_found = True

                in_target = bool(section_regex.match(stripped))
                if in_target:
                    section_found = True

            elif in_target and not path_found and stripped.upper().startswith('"PATH"'):
                path_match = re.search(r'"PATH"\s*=\s*str\(2\):"(.*?)"', stripped, re.IGNORECASE)
                if path_match:
                    current_path = path_match.group(1)
                    norm_current = current_path.lower().replace("\\\\", "\\")
                    norm_ptadd = ptadd.lower()

                    if norm_ptadd in norm_current:
                        print(f"{print_prefix}{display_section}:\n\n  {ptadd}\n\nalready in PATH\n")
                        new_lines.append(line)
                    else:
                        new_path = f"{escaped_ptadd};{current_path}"
                        new_lines.append(f'"PATH"=str(2):"{new_path}"')
                        print(f"{print_prefix}{display_section}:\n\n  {ptadd}\n\nPATH added successfully\n")

                    path_found = True
                    continue

            new_lines.append(line)

        if in_target and not path_found:
            new_lines.append(f'"PATH"=str(2):"{escaped_ptadd}"')
            print(f"{print_prefix}{display_section}:\n\n  {ptadd}\n\nPATH created successfully\n")

        if not section_found:
            new_lines.append("")
            new_lines.append(f"[{display_section}]")
            new_lines.append(f'"PATH"=str(2):"{escaped_ptadd}"')
            print(f"{print_prefix}{display_section}:\n\n  {ptadd}\n\nPATH created successfully\n")

        reg_path.write_text(nl.join(new_lines) + nl, encoding="utf-8")

    def handle_build_prefix(self) -> None:
        if not self.cli.clprm or not self.cli.clprm[0]:
            print("Wine/Proton prefix name required: (e.g. .wine, 0 )")
            return

        prefix_arg = self.cli.clprm[0]
        if prefix_arg.startswith("/") or prefix_arg.startswith("~"):
            target_pfx = Path(prefix_arg).expanduser()
        else:
            base_pfx = self.pfx_roots[0] if self.pfx_roots else Path.home() / ".wine"
            target_pfx = base_pfx / prefix_arg

        self.runner.pfx_path = target_pfx

        if self.runner.pfx_path and self.runner.pfx_path.exists():
            print(f"Wine/Proton Prefix exists: {self.runner.pfx_path}")
            return

        self.runner.locate_binary(self.bin_roots)
        print(f"Creating Wine/Proton Prefix: {prefix_arg}")

        if self.cli.mode == "p" and self.runner.bin_path and self.runner.pfx_path:
            self.runner.pfx_path.mkdir(parents=True, exist_ok=True)
            self.runner.pfx_path = self.runner.pfx_path / "pfx"
            proton_bin = self.runner.bin_path.parent / "proton"
            config = self.runner.build_launch_config([str(proton_bin), "run"])
        else:
            chse = self.ui.prompt_input("32-bit only? [y/N] ").lower()
            if chse in ["y", "yes"]:
                self.runner.configure_32bit()
                config = self.runner.build_launch_config(["winecfg.exe"])
                config.env["WINEARCH"] = "win32"
            else:
                self.runner.configure_64bit()
                config = self.runner.build_launch_config(["winecfg.exe"])
                config.env["WINEARCH"] = "win64"

        self.execute_launch(config)

    def handle_program_menu(self) -> None:
        self.apply_slot_config()
        exe_target = getattr(self, "cached_cmd", None)

        if not exe_target:
            labels = [m[0] for m in PMENU]
            sel_label = self.ui.display_menu(labels)
            exe_target = dict(PMENU)[sel_label]

            slot_key = f"{self.cli.mode}_{self.cli.slot_num}" if self.cli.slot_num else None
            if slot_key and slot_key in self.slots:
                self.slots[slot_key].cmd = exe_target
                self.save_slots()

        self.resolve_loader_choice()
        resolved_clprm = [os.path.expanduser(p) for p in self.cli.clprm]

        cwd = None
        if resolved_clprm and Path(resolved_clprm[0]).is_file():
            target_file = Path(resolved_clprm[0]).resolve()
            cwd = target_file.parent
            target_cmd = [exe_target, str(target_file), *resolved_clprm[1:]]
        else:
            target_cmd = [exe_target, *resolved_clprm]

        config = self.runner.build_launch_config(target_cmd, cwd=cwd, use_wine_loader=self.use_wine_loader)
        self.execute_launch(config)

    def handle_desktop_mode(self) -> None:
        self.apply_slot_config()
        self.resolve_loader_choice()
        config = self.runner.build_launch_config(
            ["explorer.exe", "/desktop=shell,1024x768", "explorer.exe"],
            use_wine_loader=self.use_wine_loader
        )
        self.execute_launch(config)

    def handle_proton_ge(self) -> None:
        pnpge = Path(self.cfg["pnpge"]).expanduser()
        pnbin = resolve_array_paths(self.cfg["pnbin"])[0]
        temp = Path(self.cfg["temp"]).expanduser()

        if not pnpge.parent.exists():
            print(f"Could not create folder in {pnpge.parent}")
            return

        pnpge.mkdir(parents=True, exist_ok=True)
        print("Checking latest Proton GE release...")

        req = urllib.request.Request(
            "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest",
            headers={"User-Agent": "Mozilla/5.0"}
        )

        try:
            with urllib.request.urlopen(req) as resp:
                data = json.loads(resp.read().decode())
                tag = data["tag_name"]
                gever = re.sub(r'(?i)^ge-proton', '', tag)
                version_file = pnpge / "protonge" / "version"

                if version_file.is_file():
                    installed_ver = version_file.read_text(encoding="utf-8", errors="ignore").strip()
                    if gever in installed_ver:
                        print(f"Available Proton GE {gever} matches installed, nothing to do.\n")
                        return
                    else:
                        print(f"Available Proton GE {gever} differs from installed, updating...\n")
                else:
                    print("Proton GE not found, installing...\n")

                tar_asset = next(a for a in data["assets"] if a["name"].endswith(".tar.gz") and "x86_64" in a["name"])
                dl_url = tar_asset["browser_download_url"]

                tar_file = temp / tar_asset["name"]
                print(f"Downloading {tag}...")
                urllib.request.urlretrieve(dl_url, tar_file)

                target_dir = pnpge / "protonge"
                if target_dir.exists():
                    shutil.rmtree(target_dir)

                with tarfile.open(tar_file, "r:gz") as tar:
                    tar.extractall(path=pnpge)

                extracted = next(pnpge.glob("*roton*"))
                extracted.rename(target_dir)
                tar_file.unlink()

                if not version_file.is_file() or gever not in version_file.read_text(errors="ignore"):
                    version_file.write_text(f"GE-Proton{gever}\n", encoding="utf-8")

                symlink = pnbin / "protonge"
                if not symlink.is_symlink() and not symlink.exists():
                    symlink.symlink_to(target_dir)

                print("Proton GE installed successfully.")

        except Exception as e:
            print(f"Failed to fetch Proton GE: {e}")

    def handle_exe_info(self) -> None:
        if not self.cli.clprm or (not Path(self.cli.clprm[0]).is_file() and not Path(self.cli.clprm[0]).is_dir()):
            self.runner.resolve_prefix(self.pfx_roots)

        if not self.cli.clprm or not Path(self.cli.clprm[0]).is_file():
            chse = self.ui.prompt_input("query dll? [y/N] ").lower()
            if chse in ["y", "yes"]:
                self.xflt = "*.dll"

        self.select_program_menu()

        if self.xmrtn and self.pedir:
            target = self.pedir / self.xmrtn
            print(f"FILE:\n{self.xmrtn}\n")

            try:
                pe = pefile.PE(str(target), fast_load=True)
                magic = pe.OPTIONAL_HEADER.Magic
                bits = "64-bit" if magic == pefile.OPTIONAL_HEADER_MAGIC_PE_PLUS else "32-bit"
                print(f"PE HEADER:\n{bits}\n")

                pe.parse_data_directories(directories=[
                    pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE']
                ])

                version_str = "N/A"
                if hasattr(pe, 'VS_VERSIONINFO') and hasattr(pe, 'FileInfo'):
                    for file_info in pe.FileInfo:
                        if isinstance(file_info, list):
                            for item in file_info:
                                if hasattr(item, 'StringTable'):
                                    for st in item.StringTable:
                                        if b'ProductVersion' in st.entries:
                                            version_str = st.entries[b'ProductVersion'].decode('utf-8', errors='ignore')
                                        elif b'FileVersion' in st.entries and version_str == "N/A":
                                            version_str = st.entries[b'FileVersion'].decode('utf-8', errors='ignore')
                print(f"Version:\n{version_str}\n")
                pe.close()
            except Exception:
                print("PE HEADER:\nUnknown\n\nVersion:\nN/A\n")

            print("REFERENCES:")
            try:
                res = subprocess.run(['strings', str(target)], capture_output=True, text=True, check=True)
                dlls = sorted({d.lower() for d in re.findall(r'([a-zA-Z0-9_\-\.]+\.dll)', res.stdout, re.I)})
                if dlls:
                    for d in dlls:
                        print(d)
                else:
                    print("None found")
            except Exception:
                print("None found")
            print()

    def handle_kill_wine(self) -> None:
        self.apply_slot_config()
        config = self.runner.build_launch_config(["wineserver", "-k"], use_wine_loader=True)
        self.execute_launch(config)

    def handle_dll_overrides(self) -> None:
        self.runner.resolve_prefix(self.pfx_roots)
        chse = self.ui.prompt_input("per application? [y/N] ").lower()
        self.ui.clear()

        if not self.runner.pfx_path:
            return

        user_reg = self.runner.pfx_path / "user.reg"
        if not user_reg.exists():
            print(f"Registry file not found: {user_reg}")
            return

        content = user_reg.read_text(encoding="utf-8", errors="ignore")
        print(f"Prefix:\n{self.runner.pfx_path}\n")

        if chse in ["y", "yes"]:
            print("Per-application overrides:")
            pattern = r'\[Software\\\\Wine\\\\AppDefaults\\\\.+?\\\\DllOverrides\]([^\[]*)'
        else:
            print("Global overrides:")
            pattern = r'\[Software\\\\Wine\\\\DllOverrides\]([^\[]*)'

        blocks = re.findall(pattern, content, flags=re.IGNORECASE)
        found_entries = []
        for block in blocks:
            for line in block.splitlines():
                line = line.strip()
                if line.startswith('"'):
                    found_entries.append(line)

        if found_entries:
            for entry in found_entries:
                print(entry)
        else:
            print("None found\n")

    def handle_launch_exe(self) -> None:
        self.apply_slot_config()
        self.select_program_menu()
        if self.xmrtn and self.pedir:
            self.prepare_launch_target()
            target_file = self.pedir / self.xmrtn

            extra_args = self.cli.clprm[1:] if (self.cli.clprm and Path(self.cli.clprm[0]).exists()) else self.cli.clprm
            target_cmd = [str(target_file), *extra_args]

            config = self.runner.build_launch_config(
                target_cmd,
                cwd=target_file.parent,
                use_wine_loader=self.use_wine_loader
            )
            self.execute_launch(config)

    def handle_steam_launch(self) -> None:
        sstrt = None
        pnapp = self.pnapp

        if self.cli.mode == "p":
            sstrt = shutil.which("steam")
        else:
            self.apply_slot_config()
            if self.runner.pfx_path:
                sstrt_files = list((self.runner.pfx_path / "drive_c").rglob("steam.exe"))
                if sstrt_files:
                    sstrt = str(sstrt_files[0])
                    pnapp = Path(sstrt).parent / "steamapps"

        if sstrt and Path(sstrt).is_file():
            items = []
            if pnapp.exists():
                manifests = list(pnapp.glob("appmanifest_*.acf"))
                for m in manifests:
                    try:
                        txt = m.read_text(encoding="utf-8", errors="ignore")
                        app_id = re.search(r'"appid"\s+"(\d+)"', txt)
                        name = re.search(r'"name"\s+"([^"]+)"', txt)
                        if app_id and name:
                            items.append(f"{app_id.group(1)} {name.group(1)}")
                    except Exception:
                        continue

            app_id_target = None
            if items:
                items.sort()
                items.append("steam")
                sel = self.ui.display_menu(items)
                parts = sel.split(maxsplit=1)
                if parts and parts[0].isdigit():
                    app_id_target = parts[0]

            steam_args = [sstrt, "-no-browser", "-applaunch", app_id_target] if app_id_target else [sstrt, "-no-browser", "steam://open/minigameslist"]
            config = self.runner.build_launch_config(steam_args, use_wine_loader=True)
            self.execute_launch(config)
        else:
            print("Steam not found.")

    def handle_winetricks(self) -> None:
        self.apply_slot_config()
        tricks_cmd = ["winetricks", *self.cli.clprm] if self.cli.clprm else ["winetricks", "--gui"]
        if self.cli.clprm:
            os.environ["dbg"] = "1"

        config = self.runner.build_launch_config(tricks_cmd, use_wine_loader=True)
        self.execute_launch(config)

    def handle_shortcut_creation(self) -> None:
        desk = Path(self.cfg["desk"]).expanduser()
        if desk.is_dir():
            self.apply_slot_config()
            self.select_program_menu()
            if self.xmrtn and self.pedir:
                self.prepare_launch_target()

                default_name = Path(self.xmrtn).stem
                name = self.ui.prompt_input(f"Shortcut Name? [{default_name}]: ") or default_name

                target_file = self.pedir / self.xmrtn
                extra_args = self.cli.clprm[1:] if (self.cli.clprm and Path(self.cli.clprm[0]).exists()) else self.cli.clprm
                target_cmd = [str(target_file), *extra_args]

                config = self.runner.build_launch_config(target_cmd, cwd=self.pedir, use_wine_loader=self.use_wine_loader)

                cmd_parts = ['"env"']
                for var in ["PATH", "WINEDLLPATH", "LD_LIBRARY_PATH", "WINEPREFIX", "STEAM_COMPAT_DATA_PATH", "STEAM_COMPAT_CLIENT_INSTALL_PATH"]:
                    if var in config.env:
                        cmd_parts.append(f'"{var}={config.env[var]}"')

                for item in config.cmd:
                    cmd_parts.append(f'"{item}"')

                exec_cmd = f"bash -c 'cd \"{self.pedir}\" ; {' '.join(cmd_parts)} '"

                shortcut_content = f"""[Desktop Entry]
Version=1.0
Type=Application
Name={name}
Comment=created by wstart
Exec={exec_cmd}
Icon={self.cfg['icon']}
Terminal=false
StartupNotify=false
Categories=Emulator;Game;
Keywords=wine;proton;launcher;
"""
                desktop_file = desk / f"{name}.desktop"
                desktop_file.write_text(shortcut_content, encoding="utf-8")
                desktop_file.chmod(0o755)
                print(f"Created shortcut: {desktop_file}")
        else:
            print(f"Invalid desktop location: {desk}")

    def handle_wine_version(self) -> None:
        self.runner.locate_binary(self.bin_roots)
        config = self.runner.build_launch_config(["--version"], use_wine_loader=True)
        self.execute_launch(config, detach=False)

    def run(self) -> None:
        if not self.cli.raw_arg1 or self.cli.raw_arg1 in ["-h", "--help"]:
            if not self.cli.raw_arg1:
                self.usage("one option required!")
            else:
                print("\n  General usage:  wstart -w? args\n"
                      "  -w? options for wine and -p? for proton.\n"
                      "  Type wstart by itself for command list.\n")
                sys.exit(0)

        match self.cli.action:
            case "-xa" | "--xadd":
                self.handle_add_to_path()
            case "-xb" | "--xbld":
                self.handle_build_prefix()
            case "-xc" | "--xcmd":
                self.handle_program_menu()
            case "-xd" | "--xdsk":
                self.handle_desktop_mode()
            case "-ge" | "--gepn":
                self.handle_proton_ge()
            case "-xi" | "--xinf":
                self.handle_exe_info()
            case "-xk" | "--xkil":
                self.handle_kill_wine()
            case "-xo" | "--xovr":
                self.handle_dll_overrides()
            case "-xp" | "--xprg":
                self.handle_launch_exe()
            case "-xs" | "--xstm":
                self.handle_steam_launch()
            case "-xt" | "--xtrk":
                self.handle_winetricks()
            case "-xu" | "--xcut":
                self.handle_shortcut_creation()
            case "-xv" | "--xver":
                self.handle_wine_version()
            case _:
                self.usage(f"invalid option {self.cli.raw_arg1}")


def main() -> None:
    try:
        engine = WStartEngine()
        engine.run()
    except (KeyboardInterrupt, EOFError):
        print("\nAborted.")
        sys.exit(0)


if __name__ == "__main__":
    main()
