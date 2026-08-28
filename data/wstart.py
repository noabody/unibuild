#!/usr/bin/env python3
# Version 0.3 - Python Port of wstart (Strict Parity & Macro Slots)

import os
import sys
import re
import json
import shlex
import shutil
import tarfile
import urllib.request
import subprocess
import pefile
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Tuple, Any

# Clear inherited Wine/Proton environment variables (matching Bash top-level unsets)
FORBIDDEN_ENV_VARS = [
    "WINEARCH",
    "WINEDLLPATH",
    "WINEPREFIX",
    "STEAM_COMPAT_CLIENT_INSTALL_PATH",
    "STEAM_COMPAT_DATA_PATH"
]
for var in FORBIDDEN_ENV_VARS:
    os.environ.pop(var, None)

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
    "temp": str(Path.home() / "Downloads"),
    "pmenu": [
        ["Command Prompt", "wineconsole.exe"],
        ["Control Panel", "control.exe"],
        ["Registry Editor", "regedit.exe"],
        ["Task Manager", "taskmgr.exe"],
        ["Windows Explorer", "explorer.exe"],
        ["Wine Configuration", "winecfg.exe"]
    ]
}


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
    """Checks /proc/mounts to determine if path resides on a FUSE filesystem."""
    try:
        resolved_path = str(path.resolve())
        if Path("/proc/mounts").exists():
            with open("/proc/mounts", "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 3 and "fuse" in parts[2].lower():
                        if resolved_path.startswith(parts[1]):
                            return True
    except Exception:
        pass
    return False


def is_valid_gui_exe(file_path: Path) -> bool:
    try:
        with pefile.PE(str(file_path), fast_load=True) as pe:
            subsystem = getattr(pe.OPTIONAL_HEADER, 'Subsystem', None)
            if subsystem != 2:
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

            return has_icon
    except Exception:
        return False


class WStart:
    def __init__(self):
        self.cfg = load_json(CONFIG_FILE, DEFAULT_CONFIG)
        self.pmenu = [tuple(item) for item in self.cfg.get("pmenu", DEFAULT_CONFIG["pmenu"])]

        raw_slots = load_json(SLOTS_FILE, {})
        self.slots: Dict[str, SlotConfig] = {
            k: SlotConfig.from_dict(v) for k, v in raw_slots.items()
        }

        self.arg1 = sys.argv[1] if len(sys.argv) > 1 else ""
        self.clprm = sys.argv[2:] if len(sys.argv) > 1 else []

        m = re.search(r'-([wp])', self.arg1, re.I)
        self.mode = m.group(1).lower() if m else ""

        slot_match = re.search(r'-[wp][a-z]*(\d+)', self.arg1, re.I)
        self.slot_num = int(slot_match.group(1)) if slot_match else None

        if self.mode:
            self.xarg = re.sub(r'-[wp]', '-x', self.arg1, flags=re.I)
        else:
            self.xarg = re.sub(r'-x+', '-', self.arg1, flags=re.I)

        self.pntop = Path(self.cfg.get("pntop", "~/.steam")).expanduser()
        default_pnapp = str(self.pntop / "steam" / "steamapps")
        self.pnapp = Path(self.cfg.get("pnapp", default_pnapp)).expanduser()

        if self.mode == "p":
            self.xnbin_list = resolve_array_paths(self.cfg.get("pnbin", []))
            self.xnpfx_list = resolve_array_paths(self.cfg.get("pnpfx", []))
        else:
            self.xnbin_list = resolve_array_paths(self.cfg.get("wnbin", []))
            self.xnpfx_list = resolve_array_paths(self.cfg.get("wnpfx", []))

        self.wnpfx = self.xnpfx_list[0] if self.xnpfx_list else Path.home() / ".wine"
        self.pnpfx = self.xnpfx_list[0] if self.xnpfx_list else Path.home() / ".steam" / "steam" / "steamapps" / "compatdata"

        self.xnbin: Optional[Path] = None
        self.xnpfx: Optional[Path] = None

        self.dpth = (4, 3) if self.mode == "p" else (3, 2)

        self.xstrt = "wine"
        self.xnldl = ""
        self.xndll = ""
        self.xcmd: List[str] = []
        self.env: Dict[str, str] = {}
        self.pedir: Optional[Path] = None
        self.xmrtn: Optional[str] = None
        self.xflt: Optional[str] = None
        self.use_wine_loader: Optional[bool] = None
        self.cached_cmd: Optional[str] = None

    def clear_screen(self) -> None:
        if os.system("clear") != 0:
            print("\033[2J\033[3J\033[H", end="", flush=True)

    def save_slots(self) -> None:
        save_json(SLOTS_FILE, {k: v.to_dict() for k, v in self.slots.items()})

    def prompt_input(self, prompt_text: str) -> str:
        try:
            return input(prompt_text).strip()
        except (KeyboardInterrupt, EOFError):
            print("\nExiting.")
            sys.exit(0)

    def safe_popen(self, cmd: List[str], **kwargs) -> Optional[subprocess.Popen]:
        try:
            return subprocess.Popen(cmd, **kwargs)
        except Exception as e:
            print(f"Error launching process '{cmd[0]}': {e}", file=sys.stderr)
            return None

    def get_merged_env(self) -> Dict[str, str]:
        full_env = os.environ.copy()
        for k, v in self.env.items():
            full_env[k] = str(v)
        return full_env

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

    def display_menu(self, options: List[str]) -> str:
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
                    self.clear_screen()
                    return selected
            except (ValueError, KeyboardInterrupt, EOFError):
                pass

    # --- Core Pipeline Translation (xnint, xnexe, xndef, xnpre, xnenv, xnldr, xnset, xlyt) ---

    def xnint(self) -> None:
        if self.mode == "p":
            self.xnpfx = self.pnpfx
            self.dpth = (4, 3)
        else:
            self.xnpfx = self.wnpfx
            self.dpth = (3, 2)

    def xn64(self) -> None:
        if self.xnbin:
            wine64_bin = self.xnbin / "bin" / "wine64"
            self.xnldl = f"{self.xnbin}/lib64:{self.xnbin}/lib"
            self.xndll = f"{self.xnbin}/lib64/wine:{self.xnbin}/lib/wine"
        else:
            wine64_bin = Path("/bin/wine64")
            self.xnldl = ""
            self.xndll = ""

        self.xstrt = "wine64" if wine64_bin.is_file() else "wine"

    def xn32(self) -> None:
        self.xstrt = "wine"
        if self.xnbin:
            self.xnldl = f"{self.xnbin}/lib"
            self.xndll = f"{self.xnbin}/lib/wine"
        else:
            self.xnldl = ""
            self.xndll = ""

    def xnexe(self) -> None:
        found = []
        search_roots = self.xnbin_list

        for root in search_roots:
            if not root.exists():
                continue

            for base, dirs, files in os.walk(root, followlinks=True):
                base_path = Path(base)
                try:
                    rel_path = base_path.relative_to(root)
                    rel_depth = len(rel_path.parts)
                except ValueError:
                    rel_depth = 0

                if rel_depth >= self.dpth[0]:
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

        unique_opts = {}
        for name, path in found:
            if name not in unique_opts:
                unique_opts[name] = path

        if len(unique_opts) > 1:
            opts = sorted(list(unique_opts.keys()))
            sel = self.display_menu(opts)
            if sel in unique_opts:
                self.xnbin = unique_opts[sel]
        elif len(unique_opts) == 1:
            self.xnbin = list(unique_opts.values())[0]
        else:
            print("No installed Wine/Proton found.", file=sys.stderr)
            sys.exit(1)

    def xndef(self) -> None:
        if not self.xnbin:
            return

        if self.mode == "p":
            pfx0 = self.xnpfx_list[0] / "0"
            if not pfx0.is_dir():
                print(f"Creating default prefix: {pfx0}")
                pfx0.mkdir(parents=True, exist_ok=True)

                env = self.get_merged_env()
                env["STEAM_COMPAT_DATA_PATH"] = str(pfx0)

                proton_bin = self.xnbin.parent / "proton"
                self.safe_popen([str(proton_bin), "run"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.xnpfx = pfx0 / "pfx"
        else:
            default_pfx = self.wnpfx if self.wnpfx.name == ".wine" else self.wnpfx / ".wine"
            if not default_pfx.is_dir():
                print(f"Creating default prefix: {default_pfx}")
                default_pfx.mkdir(parents=True, exist_ok=True)

                env = self.get_merged_env()
                env["WINEPREFIX"] = str(default_pfx)

                winecfg_bin = self.xnbin / "bin" / "winecfg"
                self.safe_popen([str(winecfg_bin)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                home_wine = Path.home() / ".wine"
                if home_wine.exists() and home_wine != default_pfx:
                    if home_wine.is_symlink() or home_wine.is_file():
                        home_wine.unlink()
                    else:
                        shutil.rmtree(home_wine)
                    home_wine.symlink_to(default_pfx)
            self.xnpfx = default_pfx

    def get_proton_app_map(self, valid_app_ids: Optional[set] = None) -> Dict[str, str]:
        app_map = {}
        if not self.pnapp.exists():
            return app_map

        for mf in self.pnapp.glob("appmanifest_*.acf"):
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

    def xnpre(self) -> None:
        """Strict Bash Parity: Finds/selects existing prefix. DOES NOT create one on fallthrough."""
        found_pfx = []
        search_roots = self.xnpfx_list if getattr(self, "xnpfx_list", None) else [self.wnpfx]

        for pfx_root in search_roots:
            if not pfx_root.is_dir():
                continue

            for base, dirs, files in os.walk(pfx_root):
                base_path = Path(base)
                try:
                    rel_path = base_path.relative_to(pfx_root)
                    rel_depth = len(rel_path.parts)
                except ValueError:
                    rel_depth = 0

                if rel_depth > self.dpth[1]:
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

        unique_pfx = {}
        for label, full_path in found_pfx:
            if label not in unique_pfx:
                unique_pfx[label] = full_path

        if len(unique_pfx) > 1:
            if self.mode == "p":
                pfx_app_ids = {Path(k).parts[0] for k in unique_pfx.keys()}
                app_map = self.get_proton_app_map(valid_app_ids=pfx_app_ids)

                if app_map:
                    for app_id, name in sorted(app_map.items(), key=lambda item: int(item[0]) if item[0].isdigit() else item[0]):
                        print(f"{app_id}  {name}")

            sorted_labels = sorted(unique_pfx.keys())
            sel_label = self.display_menu(sorted_labels)
            self.xnpfx = unique_pfx[sel_label]
        elif len(unique_pfx) == 1:
            self.xnpfx = list(unique_pfx.values())[0]

        if self.mode == "p" and self.xnpfx:
            if self.xnpfx.name != "pfx" and (self.xnpfx / "pfx").is_dir():
                self.xnpfx = self.xnpfx / "pfx"

        if self.xnpfx and (self.xnpfx / "drive_c" / "windows" / "syswow64").exists():
            self.xn64()
        else:
            self.xn32()

    def xnenv(self) -> None:
        xpath = f"{self.xnbin}/bin:{os.environ.get('PATH', '')}" if self.xnbin else os.environ.get('PATH', '')

        self.env = {
            "PATH": xpath,
            "WINEDLLPATH": self.xndll,
            "LD_LIBRARY_PATH": self.xnldl,
            "WINEPREFIX": str(self.xnpfx) if self.xnpfx else "",
        }

        if self.mode == "p" and self.xnpfx:
            compat_data_dir = self.xnpfx.parent if self.xnpfx.name == "pfx" else self.xnpfx
            self.env["STEAM_COMPAT_DATA_PATH"] = str(compat_data_dir)
            self.env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = str(self.pntop)

    def xnldr(self) -> None:
        if self.mode == "p":
            if self.use_wine_loader is None:
                chse = self.prompt_input("wine loader? [y/N] ").lower()
                self.use_wine_loader = chse in ["y", "yes"]

                slot_key = f"{self.mode}_{self.slot_num}" if self.slot_num else None
                if slot_key and slot_key in self.slots:
                    self.slots[slot_key].use_wine_loader = self.use_wine_loader
                    self.save_slots()

            if self.use_wine_loader:
                self.xcmd.append(self.xstrt)
            else:
                proton_bin = self.xnbin.parent / "proton" if self.xnbin else Path("proton")
                self.xcmd.extend([str(proton_bin), "run"])
        else:
            self.xcmd.append(self.xstrt)

    def xnset(self) -> None:
        """Standard setup chain matching Bash: xnint -> xnexe -> xndef -> xnpre -> xnenv"""
        self.xnint()
        self.xnexe()
        self.xndef()
        self.xnpre()
        self.xnenv()

    def xlyt(self) -> None:
        """Layout adjustment matching Bash xlyt for target PE arch."""
        if not self.pedir or not self.xmrtn:
            return

        exe_path = self.pedir / self.xmrtn
        try:
            with open(exe_path, "rb") as f:
                header = f.read(0x200)
                pe_off = int.from_bytes(header[0x3C:0x40], "little")
                magic = int.from_bytes(header[pe_off + 0x18:pe_off + 0x1A], "little")
                if magic == 0x10B and self.xnpfx and (self.xnpfx / "drive_c" / "windows" / "syswow64").is_dir():
                    self.xn32()
                    self.xnenv()
        except OSError:
            pass

        self.xnldr()

        if self.clprm and Path(self.clprm[0]).exists():
            extra_args = self.clprm[1:]
        else:
            extra_args = self.clprm

        self.xcmd.append(str(exe_path))
        self.xcmd.extend(extra_args)

    # --- Save Slot Macro Interceptor ---

    def apply_slot_config(self) -> None:
        slot_key = f"{self.mode}_{self.slot_num}" if self.slot_num is not None else None

        if self.slot_num == 0:
            deleted = False
            keys_to_remove = [k for k in self.slots if k.startswith(f"{self.mode}_")]
            for k in keys_to_remove:
                del self.slots[k]
                deleted = True

            if deleted:
                self.save_slots()
                print(f"Cleared slot configuration for mode '{self.mode}'.")

            self.xnset()
            return

        if slot_key and slot_key in self.slots:
            cached = self.slots[slot_key]
            cached_bin = Path(cached.bin)
            cached_pfx = Path(cached.pfx)
            if cached_bin.exists() and cached_pfx.exists():
                self.xnbin = cached_bin
                self.xnpfx = cached_pfx

                if cached.use_wine_loader is not None:
                    self.use_wine_loader = cached.use_wine_loader

                if cached.cmd:
                    self.cached_cmd = cached.cmd

                resolved_cli_args = [
                    str(Path(arg).expanduser().resolve()) if Path(arg).expanduser().exists() else arg
                    for arg in self.clprm
                ]
                self.clprm = cached.args + resolved_cli_args

                if (self.xnpfx / "drive_c" / "windows" / "syswow64").is_dir():
                    self.xn64()
                else:
                    self.xn32()
                self.xnenv()
                return

        self.xnset()

        if slot_key and self.slot_num > 0:
            self.slots[slot_key] = SlotConfig(
                bin=str(self.xnbin) if self.xnbin else "",
                pfx=str(self.xnpfx) if self.xnpfx else "",
                args=self.clprm if self.clprm else [],
                use_wine_loader=self.use_wine_loader
            )
            self.save_slots()

    def launch_process(self) -> None:
        dbg = os.environ.get("dbg", "")
        env_vars = " ".join(f"{k}={v}" for k, v in self.env.items())
        cmd_str = " ".join(self.xcmd)
        full_cmd_str = f"env {env_vars} {cmd_str}" if env_vars else cmd_str

        full_env = self.get_merged_env()
        if not dbg:
            self.safe_popen(self.xcmd, env=full_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        else:
            print(full_cmd_str)
            if dbg == "1":
                self.safe_popen(self.xcmd, env=full_env)
            elif dbg == "2":
                full_env["WINEDEBUG"] = "warn+all"
                self.safe_popen(self.xcmd, env=full_env)

    # --- Menu and Executable Discovery ---

    def xpmn(self) -> None:
        if self.clprm and Path(self.clprm[0]).is_file():
            target_path = Path(self.clprm[0]).resolve()
            self.pedir = target_path.parent
            self.xmrtn = target_path.name
        else:
            if self.clprm and Path(self.clprm[0]).is_dir():
                self.pedir = Path(self.clprm[0]).resolve()
                exes = self.find_executables(self.pedir, filtered=False)
            else:
                self.pedir = self.xnpfx / "drive_c" if self.xnpfx else Path.home() / ".wine" / "drive_c"
                exes = self.find_executables(self.pedir, filtered=True)

            if len(exes) > 0:
                self.xmrtn = self.display_menu(exes)

    def find_executables(self, search_path: Path, filtered: bool = True) -> List[str]:
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
            base_path = Path(base)
            try:
                rel_depth = len(base_path.relative_to(search_path).parts)
            except ValueError:
                rel_depth = 0

            if rel_depth >= 7:
                dirs[:] = []
                continue

            if filtered and any(s in base.lower() for s in skip):
                dirs[:] = []
                continue

            for f in files:
                pattern = self.xflt if self.xflt else "*.exe"
                if f.lower().endswith(pattern.replace("*", "")):
                    if filtered and bad.match(f):
                        continue

                    full_p = base_path / f
                    if not self.xflt and not skip_pe_check:
                        if not is_valid_gui_exe(full_p):
                            continue

                    rel = full_p.relative_to(search_path)
                    found.append(str(rel))

        return sorted(found)

    # --- Option Handlers ---

    def handle_add_to_path(self) -> None:
        self.xnint()
        self.xnpre()
        self.xpmn()

        if not (self.xmrtn and self.pedir and self.xnpfx):
            return

        target_dir = (self.pedir / self.xmrtn).parent if self.xmrtn else self.pedir
        ptadd = f"z:{target_dir}".replace("/", "\\")
        escaped_ptadd = ptadd.replace("\\", "\\\\")

        chse = self.prompt_input("prepend to system path? [y/N] ").lower()
        self.clear_screen()

        is_system = chse in ["y", "yes"]

        if is_system:
            reg_file = "system.reg"
            print_prefix = "HKLM\\"
            default_section = r"System\ControlSet001\Control\Session Manager\Environment"
            sec_pattern = re.compile(r'^\[(system.*controlset.*control.*session manager.*environment)\]', re.IGNORECASE)
        else:
            reg_file = "user.reg"
            print_prefix = "HKCU\\"
            display_section = "Environment"

        reg_path = self.xnpfx / reg_file
        if not reg_path.exists():
            print(f"Registry file missing: {reg_path}")
            return

        raw_content = reg_path.read_text(encoding="utf-8", errors="ignore")
        nl = "\r\n" if "\r\n" in raw_content else "\n"
        lines = raw_content.splitlines()

        if is_system:
            display_section = default_section
            for line in lines:
                m = sec_pattern.match(line.strip())
                if m:
                    display_section = m.group(1).replace("\\\\", "\\")
                    break

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

                if is_system:
                    in_target = bool(sec_pattern.match(stripped))
                else:
                    in_target = bool(re.match(r'^\[environment\]', stripped, re.IGNORECASE))

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
            path_found = True

        if not section_found:
            new_lines.append("")
            new_lines.append(f"[{display_section.replace('\\', '\\\\')}]")
            new_lines.append(f'"PATH"=str(2):"{escaped_ptadd}"')
            print(f"{print_prefix}{display_section}:\n\n  {ptadd}\n\nPATH created successfully\n")

        reg_path.write_text(nl.join(new_lines) + nl, encoding="utf-8")

    def handle_build_prefix(self) -> None:
        if not self.clprm or not self.clprm[0]:
            print("Wine/Proton prefix name required: (e.g. .wine, 0 )")
            return

        prefix_arg = self.clprm[0]
        if prefix_arg.startswith("/") or prefix_arg.startswith("~"):
            target_pfx = Path(prefix_arg).expanduser()
        else:
            base_pfx = self.pnpfx if self.mode == "p" else self.wnpfx
            target_pfx = base_pfx / prefix_arg

        self.xnint()
        self.xnpfx = target_pfx

        if self.xnpfx and self.xnpfx.exists():
            print(f"Wine/Proton Prefix exists: {self.xnpfx}")
            return

        self.xnexe()
        print(f"Creating Wine/Proton Prefix: {prefix_arg}")

        if self.mode == "p" and self.xnbin and self.xnpfx:
            self.xnpfx.mkdir(parents=True, exist_ok=True)
            self.xnpfx = self.xnpfx / "pfx"
            self.xnenv()
            proton_bin = self.xnbin.parent / "proton"
            self.xcmd = [str(proton_bin), "run"]
        else:
            chse = self.prompt_input("32-bit only? [y/N] ").lower()
            if chse in ["y", "yes"]:
                self.xn32()
                self.xnenv()
                self.env["WINEARCH"] = "win32"
            else:
                self.xn64()
                self.xnenv()
                self.env["WINEARCH"] = "win64"

            self.xcmd = [self.xstrt, "winecfg.exe"]

        self.launch_process()

    def handle_program_menu(self) -> None:
        self.apply_slot_config()
        exe_target = getattr(self, "cached_cmd", None)

        if not exe_target:
            labels = [m[0] for m in self.pmenu]
            sel_label = self.display_menu(labels)
            exe_target = dict(self.pmenu)[sel_label]

            slot_key = f"{self.mode}_{self.slot_num}" if self.slot_num else None
            if slot_key and slot_key in self.slots:
                self.slots[slot_key].cmd = exe_target
                self.save_slots()

        self.xnldr()
        resolved_clprm = [os.path.expanduser(p) for p in self.clprm]

        cmd_args = shlex.split(exe_target)

        if resolved_clprm and Path(resolved_clprm[0]).is_file():
            target_file = Path(resolved_clprm[0]).resolve()
            os.chdir(target_file.parent)
            self.xcmd.extend([*cmd_args, str(target_file), *resolved_clprm[1:]])
        else:
            self.xcmd.extend([*cmd_args, *resolved_clprm])

        self.launch_process()

    def handle_desktop_mode(self) -> None:
        self.apply_slot_config()
        self.xnldr()
        self.xcmd.extend(["explorer.exe", "/desktop=shell,1024x768", "explorer.exe"])
        self.launch_process()

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
                    if hasattr(tarfile, "data_filter"):
                        tar.extractall(path=pnpge, filter="data")
                    else:
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
        if not self.clprm or (not Path(self.clprm[0]).is_file() and not Path(self.clprm[0]).is_dir()):
            self.xnint()
            self.xnpre()

        if not self.clprm or not Path(self.clprm[0]).is_file():
            chse = self.prompt_input("query dll? [y/N] ").lower()
            if chse in ["y", "yes"]:
                self.xflt = "*.dll"

        self.xpmn()

        if not self.xmrtn or not self.pedir:
            print("\nNo file found\n")
            return

        target = self.pedir / self.xmrtn

        try:
            with pefile.PE(str(target), fast_load=True) as pe:
                magic = pe.OPTIONAL_HEADER.Magic
                bits = "64-bit" if magic == pefile.OPTIONAL_HEADER_MAGIC_PE_PLUS else "32-bit"

                print(f"FILE:\n{self.xmrtn}\n")
                print(f"PE HEADER:\n{bits}\n")

                pe.parse_data_directories(directories=[
                    pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE']
                ])

                version_str = "N/A"
                if hasattr(pe, 'VS_FIXEDFILEINFO') and pe.VS_FIXEDFILEINFO:
                    ffi = pe.VS_FIXEDFILEINFO[0]
                    if ffi:
                        ms, ls = ffi.FileVersionMS, ffi.FileVersionLS
                        version_str = f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"
                if version_str == "N/A" and hasattr(pe, 'FileInfo'):
                    for file_info in pe.FileInfo:
                        items = file_info if isinstance(file_info, list) else [file_info]
                        for item in items:
                            if hasattr(item, 'StringTable'):
                                for st in item.StringTable:
                                    if b'FileVersion' in st.entries:
                                        version_str = st.entries[b'FileVersion'].decode('utf-8', errors='ignore').strip()
                                        break
                                    elif b'ProductVersion' in st.entries:
                                        version_str = st.entries[b'ProductVersion'].decode('utf-8', errors='ignore').strip()
                                        break

                print(f"Version:\n{version_str}\n")

            print("REFERENCES:")
            res = subprocess.run(['strings', str(target)], capture_output=True, text=True, check=True)
            raw_matches = re.findall(r'([^<>:"/\\|?*\s]+\.dll)', res.stdout, re.IGNORECASE)
            section_pattern = re.compile(r'^\.(?:text|s?[eripx]?data|bss|rsrc|reloc|tls|debug|crt|gfids)', re.IGNORECASE)
            valid_dlls = {d.lower() for d in raw_matches if not section_pattern.match(d)}

            if valid_dlls:
                for d in sorted(valid_dlls):
                    print(d)
            else:
                print("None found")
            print()

        except Exception:
            print("\nNot a 32/64-bit program, no information to provide\n")

    def handle_kill_wine(self) -> None:
        self.apply_slot_config()
        self.xcmd.extend(["wineserver", "-k"])
        self.launch_process()

    def handle_dll_overrides(self) -> None:
        self.xnint()
        self.xnpre()
        chse = self.prompt_input("per application? [y/N] ").lower()
        self.clear_screen()

        if not self.xnpfx:
            return

        user_reg = self.xnpfx / "user.reg"
        if not user_reg.exists():
            print(f"Registry file not found: {user_reg}")
            return

        content = user_reg.read_text(encoding="utf-8", errors="ignore")
        print(f"Prefix:\n{self.xnpfx}\n")

        found_entries = []

        if chse in ["y", "yes"]:
            print("Per-application overrides:")
            pattern = r'\[Software\\+Wine\\+AppDefaults\\+([^\\]+)\\+DllOverrides\]([^\[]*)'
            matches = re.findall(pattern, content, flags=re.IGNORECASE)
            for app_name, block in matches:
                found_entries.append(app_name)
                for line in block.splitlines():
                    line = line.strip()
                    if line.startswith('"'):
                        found_entries.append(line)
        else:
            print("Global overrides:")
            pattern = r'\[Software\\+Wine\\+DllOverrides\]([^\[]*)'
            blocks = re.findall(pattern, content, flags=re.IGNORECASE)
            for block in blocks:
                for line in block.splitlines():
                    line = line.strip()
                    if line.startswith('"'):
                        found_entries.append(line)

        if found_entries:
            for entry in found_entries:
                print(entry)
            print()
        else:
            print("None found\n")

    def handle_launch_exe(self) -> None:
        self.apply_slot_config()
        self.xpmn()
        if self.xmrtn and self.pedir:
            self.xlyt()
            target_file = self.pedir / self.xmrtn
            os.chdir(target_file.parent)
            self.launch_process()

    def _find_wine_steam(self, drive_c: Path) -> Optional[Path]:
        """Strict Bash Parity: find "$xnpfx/drive_c" -maxdepth 3 -iname 'steam.exe'"""
        if not drive_c.is_dir():
            return None

        for base, dirs, files in os.walk(drive_c):
            base_path = Path(base)
            try:
                rel_depth = len(base_path.relative_to(drive_c).parts)
            except ValueError:
                continue

            if rel_depth > 3:
                dirs[:] = []
                continue

            for f in files:
                if f.lower() == "steam.exe":
                    return base_path / f

        return None

    def handle_steam_launch(self) -> None:
        sstrt = None
        pnapp = self.pnapp

        if self.mode == "p":
            sstrt = shutil.which("steam")
        else:
            self.apply_slot_config()
            if self.xnpfx:
                steam_bin = self._find_wine_steam(self.xnpfx / "drive_c")
                if steam_bin:
                    sstrt = str(steam_bin)
                    pnapp = steam_bin.parent / "steamapps"
                    self.xcmd.append(self.xstrt)

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
                sel = self.display_menu(items)
                parts = sel.split(maxsplit=1)
                if parts and parts[0].isdigit():
                    app_id_target = parts[0]

            if app_id_target:
                self.xcmd.extend([sstrt, "-no-browser", "-applaunch", app_id_target])
            else:
                self.xcmd.extend([sstrt, "-no-browser", "steam://open/minigameslist"])

            self.launch_process()
        else:
            print("Steam not found.")

    def handle_winetricks(self) -> None:
        self.apply_slot_config()
        if self.clprm:
            self.xcmd.extend(["winetricks", *self.clprm])
            os.environ["dbg"] = "1"
        else:
            self.xcmd.extend(["winetricks", "--gui"])
        self.launch_process()

    def handle_shortcut_creation(self) -> None:
        desk = Path(self.cfg["desk"]).expanduser()
        if desk.is_dir():
            self.apply_slot_config()
            self.xpmn()
            if self.xmrtn and self.pedir:
                self.xlyt()
                os.chdir(desk)
                default_name = Path(self.xmrtn).stem
                name = self.prompt_input(f"Shortcut Name? [{default_name}]: ") or default_name

                cmd_parts = [shlex.quote("env")]
                for var in ["PATH", "WINEDLLPATH", "LD_LIBRARY_PATH", "WINEPREFIX", "STEAM_COMPAT_DATA_PATH", "STEAM_COMPAT_CLIENT_INSTALL_PATH"]:
                    if var in self.env:
                        cmd_parts.append(shlex.quote(f"{var}={self.env[var]}"))

                for item in self.xcmd:
                    cmd_parts.append(shlex.quote(item))

                exec_cmd = f"bash -c 'cd {shlex.quote(str(self.pedir))} ; {' '.join(cmd_parts)} '"

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
        self.xnint()
        self.xnexe()
        self.xnenv()
        self.xcmd.extend(["wine", "--version"])
        self.safe_popen(self.xcmd, env=self.get_merged_env())

    def run(self) -> None:
        if not self.arg1 or self.arg1 in ["-h", "--help"]:
            if not self.arg1:
                self.usage("one option required!")
            else:
                print("\n  General usage:  wstart -w? args\n"
                      "  -w? options for wine and -p? for proton.\n"
                      "  Type wstart by itself for command list.\n")
                sys.exit(0)

        base_flag = re.sub(r'\d+$', '', self.xarg).lower()

        match base_flag:
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
                self.usage(f"invalid option {self.arg1}")


def main() -> None:
    try:
        app = WStart()
        app.run()
    except (KeyboardInterrupt, EOFError):
        print("\nAborted.")
        sys.exit(0)


if __name__ == "__main__":
    main()
