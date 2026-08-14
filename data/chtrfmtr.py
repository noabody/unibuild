#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
chtrfmtr.py
Monolithic PySide6/Python port of chtrfmtr.ps1.

Dependencies:
    pip install PySide6 regex

The original PowerShell program is preserved conceptually:
- ordered cheat database
- centralized regex library
- per-system parser mapping
- 1to1 / 1few / few1 unified parsing layouts
- binary/text import and export modules
- NES Game Genie encode/decode
- dynamic input -> output module relationship
- editable groups with format isolation
- dirty-state handling and activity log

The Python `regex` package is intentional: it supports Unicode properties such
as \\p{P}, \\p{S}, and \\p{Z}, which Python's stdlib `re` does not support.
"""

from __future__ import annotations

import math
import os
import re as pyre
import struct
import sys
import traceback
import xml.etree.ElementTree as ET
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional, Any

import regex  # third-party regex; required for Unicode property support

from PySide6.QtCore import Qt, QSignalBlocker, QTimer
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QApplication, QComboBox, QFileDialog, QFormLayout, QGridLayout,
    QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem,
    QMainWindow, QMessageBox, QPushButton, QPlainTextEdit, QSizePolicy,
    QSplitter, QVBoxLayout, QWidget
)


# =============================================================================
# DATA / STATE
# =============================================================================

@dataclass
class CheatEntry:
    base_desc: str
    format: str
    codes: list[str] = field(default_factory=list)
    health: float = 1.0
    tags: dict[str, Any] = field(default_factory=dict)


@dataclass
class ParseResult:
    code: str
    format: str
    match_length: int


@dataclass
class ParseMetrics:
    lines_processed: int = 0
    code_names_found: int = 0
    codes_found: int = 0


@dataclass
class InputModule:
    name: str
    filter: str
    parse_func: Callable[..., Any]
    import_func: Callable[..., Any]


@dataclass
class OutputModule:
    name: str
    filter: str
    export_func: Callable[..., Any]


# =============================================================================
# MAIN APPLICATION
# =============================================================================

class CheatReformatter(QMainWindow):
    HEALTH_THRESHOLD = 0.80

    SYSTEM_KEY_MAP = OrderedDict([
        ("Nintendo NES", "NES"),
        ("Super Nintendo / SNES", "SNES"),
        ("Game Boy / GBC", "GBC"),
        ("Game Boy Advance / GBA", "GBA"),
        ("Nintendo DS", "NDS"),
        ("Sega Master System / SMS", "SMS"),
        ("Sega Mega Drive / MD", "MD"),
        ("Sega Saturn", "Saturn"),
        ("Sony PlayStation / PSX (PCSXR)", "PCSXR"),
        ("Sony PlayStation / PSX (ePSXe)", "ePSXe"),
    ])

    MODULE_OUTPUT_MAP = {
        "Game Boy / GBC": "GBC.emu (.gbcht)",
        "Game Boy Advance / GBA": "VBA-M (.clt)",
        "Super Nintendo / SNES": "Snes9x (.cht)",
        "Nintendo DS": "melonDS (.mch)",
        "Nintendo NES": "nes.emu (.cht)",
        "Sega Master System / SMS": "md.emu SMS (.pat)",
        "Sega Mega Drive / MD": "md.emu MD (.pat)",
        "Sega Saturn": "Kronos (.yct)",
        "Sony PlayStation / PSX (PCSXR)": "PCSXR (.cht)",
        "Sony PlayStation / PSX (ePSXe)": "ePSXe (.txt)",
    }

    # -------------------------------------------------------------------------
    # Centralized compiled regex master library.
    # This is the direct semantic equivalent of the PowerShell regex table.
    # -------------------------------------------------------------------------
    REGEX_PATTERNS = OrderedDict([
        ("rx333gg", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{3}([\p{P}\p{S}\p{Z}][0-9A-F]{3}){2}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx422hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{4}([\p{P}\p{S}\p{Z}][0-9A-F]{2}){1,2}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx44hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{4}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx62hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{6}[\p{P}\p{S}\p{Z}][0-9A-F]{2}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx8hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{8}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx84hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx848hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{8})[\p{P}\p{S}\p{Z}]([0-9A-F]{4,8}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx88hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{8}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx64hex", regex.compile(
            r"((?<![0-9A-F])[0-9A-F]{6}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))",
            regex.IGNORECASE)),
        ("rx44gg", regex.compile(
            r"((?<![0-9A-Z])[0-9A-Z]{4}[\p{P}\p{S}\p{Z}][0-9A-Z]{4}(?![0-9A-Z]))",
            regex.IGNORECASE)),
        ("rx68gg", regex.compile(
            r"(?<![0-9A-Z])([AEGIKLN-PS-VX-Z]{6}|[AEGIKLN-PS-VX-Z]{8})(?![0-9A-Z])",
            regex.IGNORECASE)),
    ])

    SYSTEM_CODE_PATTERNS = {
        "NES": OrderedDict([
            ("68gg", REGEX_PATTERNS["rx68gg"]),
            ("422hex", REGEX_PATTERNS["rx422hex"]),
        ]),
        "SNES": OrderedDict([
            ("44hex", REGEX_PATTERNS["rx44hex"]),
            ("8hex", REGEX_PATTERNS["rx8hex"]),
        ]),
        "GBC": OrderedDict([
            ("8hex", REGEX_PATTERNS["rx8hex"]),
            ("333gg", REGEX_PATTERNS["rx333gg"]),
        ]),
        "GBA": OrderedDict([
            ("84hex", REGEX_PATTERNS["rx84hex"]),
        ]),
        "NDS": OrderedDict([
            ("88hex", REGEX_PATTERNS["rx88hex"]),
        ]),
        "SMS": OrderedDict([
            ("333gg", REGEX_PATTERNS["rx333gg"]),
        ]),
        "MD": OrderedDict([
            ("64hex", REGEX_PATTERNS["rx64hex"]),
            ("44hex", REGEX_PATTERNS["rx44hex"]),
        ]),
        "Saturn": OrderedDict([
            ("84hex", REGEX_PATTERNS["rx84hex"]),
        ]),
        "ePSXe": OrderedDict([
            ("848hex", REGEX_PATTERNS["rx848hex"]),
        ]),
        "PCSXR": OrderedDict([
            ("848hex", REGEX_PATTERNS["rx848hex"]),
        ]),
    }

    def __init__(self):
        super().__init__()
        self.cheat_database: OrderedDict[str, CheatEntry] = OrderedDict()
        self.is_dirty = False
        self.last_selected_index = -1
        self.suppress_events = False
        self.last_directory = str(Path.home() / "Documents")
        self.input_modules: OrderedDict[str, InputModule] = OrderedDict()
        self.output_modules: OrderedDict[str, OutputModule] = OrderedDict()
        self._build_modules()
        self._build_ui()
        self._connect_events()
        self.update_output_module_choices()
        self.update_ui_state()

    # =========================================================================
    # UI
    # =========================================================================

    def _build_ui(self):
        self.setWindowTitle("Multi-Emulator Cheat Reformatter")

        # ---------------------------------------------------------------------
        # Initial window geometry
        #
        # Previous: 864 x 585
        # New:      820 x 585
        #
        # 820 is approximately 5.1% narrower than 864.
        # ---------------------------------------------------------------------
        self.resize(820, 585)
        self.setMinimumSize(700, 500)

        central = QWidget()
        self.setCentralWidget(central)

        root = QVBoxLayout(central)
        root.setContentsMargins(10, 10, 10, 10)
        root.setSpacing(6)

        # =====================================================================
        # TOP CONTROL ROW
        #
        # These remain LEFT JUSTIFIED.
        # =====================================================================

        top = QHBoxLayout()
        top.setSpacing(6)

        top.addWidget(QLabel("Input Module:"))

        self.cmb_input_module = QComboBox()
        self.cmb_input_module.addItems(self.input_modules.keys())

        # Master dropdown width.
        self.cmb_input_module.setFixedWidth(214)

        top.addWidget(self.cmb_input_module)

        self.btn_import = QPushButton("Import File")
        self.btn_import.setFixedWidth(95)

        top.addWidget(self.btn_import)

        self.lbl_target_regex = QLabel("Target System Regex:")
        self.lbl_target_regex.setVisible(False)

        top.addWidget(self.lbl_target_regex)

        self.cmb_target_regex = QComboBox()
        self.cmb_target_regex.addItems(
            k for k in self.input_modules.keys()
            if k != "RetroArch (Global)"
        )

        # Match Input Module exactly.
        self.cmb_target_regex.setFixedWidth(
            self.cmb_input_module.width()
        )

        self.cmb_target_regex.setVisible(False)

        top.addWidget(self.cmb_target_regex)

        # Keep the module controls left justified.
        top.addStretch(1)

        root.addLayout(top)

        # =====================================================================
        # MAIN EDITOR AREA
        #
        # Left  = Named Code Groups
        # Right = Codes
        #
        # The splitter starts at exactly 50/50.
        # =====================================================================

        splitter = QSplitter(Qt.Horizontal)

        # =====================================================================
        # LEFT SIDE: Grouped Cheat Descriptions
        # =====================================================================

        left = QWidget()

        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.setSpacing(5)

        # ---------------------------------------------------------------------
        # Center the section heading within the left pane.
        # ---------------------------------------------------------------------

        left_title_row = QHBoxLayout()

        left_title_row.addWidget(
            QLabel("Grouped Cheat Descriptions:")
        )

        left_title_row.addStretch(1)

        left_layout.addLayout(left_title_row)

        # ---------------------------------------------------------------------
        # Group list
        #
        # Keep the list itself filling the left pane.
        # ---------------------------------------------------------------------

        self.lst_cheats = QListWidget()

        left_layout.addWidget(
            self.lst_cheats,
            1
        )

        # ---------------------------------------------------------------------
        # New group / group manipulation row
        #
        # Center the complete control group inside the NEW left-pane width.
        # ---------------------------------------------------------------------

        action_row = QHBoxLayout()
        action_row.setSpacing(4)

        action_row.addStretch(1)

        row_height = 29
        
        self.txt_new_group = QLineEdit()
        self.txt_new_group.setPlaceholderText("New group name")
        self.txt_new_group.setFixedWidth(206)
        self.txt_new_group.setFixedHeight(row_height)
        action_row.addWidget(self.txt_new_group)

        self.btn_new_group = QPushButton("Add")
        self.btn_new_group.setFixedWidth(48)
        self.btn_new_group.setFixedHeight(row_height)
        action_row.addWidget(self.btn_new_group)

        self.btn_move_up = QPushButton("▲")
        self.btn_move_up.setFixedWidth(35)
        self.btn_move_up.setFixedHeight(row_height)
        action_row.addWidget(self.btn_move_up)

        self.btn_move_down = QPushButton("▼")
        self.btn_move_down.setFixedWidth(35)
        self.btn_move_down.setFixedHeight(row_height)
        action_row.addWidget(self.btn_move_down)

        self.btn_delete_group = QPushButton("❌")
        self.btn_delete_group.setFixedWidth(35)
        self.btn_delete_group.setFixedHeight(row_height)
        action_row.addWidget(self.btn_delete_group)

        action_row.addStretch(1)

        left_layout.addLayout(action_row)

        # =====================================================================
        # RIGHT SIDE: CODES
        # =====================================================================

        right = QWidget()

        right_layout = QVBoxLayout(right)
        right_layout.setContentsMargins(0, 0, 0, 0)
        right_layout.setSpacing(5)

        # ---------------------------------------------------------------------
        # Center the section heading within the right pane.
        # ---------------------------------------------------------------------

        right_title_row = QHBoxLayout()

        right_title_row.addWidget(
            QLabel("Codes in Selected Group (One per line):")
        )

        right_title_row.addStretch(1)

        right_layout.addLayout(
            right_title_row
        )

        # ---------------------------------------------------------------------
        # Code editor
        #
        # It remains the same size relative to its pane and expands with it.
        # ---------------------------------------------------------------------

        self.txt_editor = QPlainTextEdit()

        self.txt_editor.setFont(
            QFont("Monospace", 10)
        )

        self.txt_editor.setLineWrapMode(
            QPlainTextEdit.NoWrap
        )

        right_layout.addWidget(
            self.txt_editor,
            1
        )

        # ---------------------------------------------------------------------
        # Update button
        #
        # Center it within the NEW right-pane width.
        # ---------------------------------------------------------------------

        save_row = QHBoxLayout()

        save_row.addStretch(1)

        self.btn_save_group = QPushButton(
            "Update Current Modifications"
        )

        # Keep the user's widened button.
        # It is centered in the new right pane.
        self.btn_save_group.setFixedWidth(420)

        save_row.addWidget(
            self.btn_save_group
        )

        save_row.addStretch(1)

        right_layout.addLayout(
            save_row
        )

        # =====================================================================
        # ADD PANELS TO SPLITTER
        # =====================================================================

        splitter.addWidget(left)
        splitter.addWidget(right)

        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 1)

        root.addWidget(
            splitter,
            1
        )

        # ---------------------------------------------------------------------
        # Force initial splitter position to exactly 50/50.
        #
        # The user can still drag it normally afterward.
        # ---------------------------------------------------------------------

        def center_splitter():
            available_width = splitter.width()

            if available_width > 0:
                left_width = available_width // 2
                right_width = (
                    available_width - left_width
                )

                splitter.setSizes([
                    left_width,
                    right_width
                ])

        QTimer.singleShot(
            0,
            center_splitter
        )

        # =====================================================================
        # EXPORT ROW
        #
        # These remain LEFT JUSTIFIED, just like Input Module.
        # =====================================================================

        export_row = QHBoxLayout()
        export_row.setSpacing(6)

        export_row.addWidget(
            QLabel("Export To:")
        )

        self.cmb_output_module = QComboBox()

        # Exactly the same width as Input Module.
        self.cmb_output_module.setFixedWidth(
            self.cmb_input_module.width()
        )

        export_row.addWidget(
            self.cmb_output_module
        )

        self.btn_export = QPushButton(
            "Export File"
        )

        self.btn_export.setFixedWidth(95)

        export_row.addWidget(
            self.btn_export
        )

        export_row.addStretch(1)

        root.addLayout(
            export_row
        )

        # =====================================================================
        # ACTIVITY LOG
        # =====================================================================

        root.addWidget(
            QLabel("System Activity Log:")
        )

        self.txt_status_log = QPlainTextEdit()

        self.txt_status_log.setReadOnly(True)

        self.txt_status_log.setFont(
            QFont("Monospace", 8)
        )

        self.txt_status_log.setLineWrapMode(
            QPlainTextEdit.WidgetWidth
        )

        # Approximately four visible lines.
        self.txt_status_log.setFixedHeight(72)

        root.addWidget(
            self.txt_status_log
        )

    def _connect_events(self):
        self.cmb_input_module.currentIndexChanged.connect(
            self.update_output_module_choices
        )
        self.cmb_target_regex.currentIndexChanged.connect(
            self.update_output_module_choices
        )
        self.btn_import.clicked.connect(self.import_file_dialog)
        self.btn_export.clicked.connect(self.export_file_dialog)
        self.lst_cheats.currentRowChanged.connect(self.list_selection_changed)
        self.txt_editor.textChanged.connect(self.text_changed)
        self.btn_save_group.clicked.connect(self.save_group_clicked)
        self.btn_new_group.clicked.connect(self.new_group_clicked)
        self.txt_new_group.returnPressed.connect(self.new_group_clicked)
        self.btn_delete_group.clicked.connect(self.delete_group_clicked)
        self.btn_move_up.clicked.connect(lambda: self.move_cheat_group(-1))
        self.btn_move_down.clicked.connect(lambda: self.move_cheat_group(1))

        if self.cmb_input_module.count():
            self.cmb_input_module.setCurrentIndex(0)

    # =========================================================================
    # LOGGING / BASIC UI STATE
    # =========================================================================

    def write_log(self, message: str, level: str = "INFO"):
        if self.txt_status_log is None:
            return
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.txt_status_log.appendPlainText(f"[{timestamp}] [{level}] {message}")

    def update_ui_state(self):
        has_items = self.lst_cheats.count() > 0
        self.btn_move_up.setEnabled(has_items)
        self.btn_move_down.setEnabled(has_items)
        self.btn_delete_group.setEnabled(has_items)
        self.btn_save_group.setEnabled(has_items)

    def text_changed(self):
        if not self.suppress_events:
            self.is_dirty = True

    def visible_keys(self) -> list[str]:
        return [
            k for k, entry in self.cheat_database.items()
            if entry.format != "Heading"
        ]

    def disable_list_events(self):
        try:
            self.lst_cheats.currentRowChanged.disconnect(self.list_selection_changed)
        except (RuntimeError, TypeError):
            pass

    def enable_list_events(self):
        try:
            self.lst_cheats.currentRowChanged.connect(self.list_selection_changed)
        except (RuntimeError, TypeError):
            pass

    # =========================================================================
    # SYSTEM PARSER
    # =========================================================================

    def invoke_system_parser(
        self, system_name: str, raw_line: Optional[str]
    ) -> Optional[ParseResult]:
        if raw_line is None or not raw_line.strip():
            return None

        clean_line = raw_line.strip()
        clean_line = regex.sub(r"^[*\t\s#]+", "", clean_line)

        active_patterns = self.SYSTEM_CODE_PATTERNS.get(system_name)
        if not active_patterns:
            return None

        for pattern_key, pattern in active_patterns.items():
            match = pattern.search(clean_line)
            if match:
                return ParseResult(
                    code=match.group(0).upper().strip(),
                    format=pattern_key,
                    match_length=len(match.group(0)),
                )
        return None

    # =========================================================================
    # DATABASE MUTATOR
    # =========================================================================

    def add_cheat_to_database(
        self,
        description: str,
        codes: Optional[list[str]],
        system_name: Optional[str] = None,
        format_override: Optional[str] = None,
        raw_length: int = 0,
        match_length: int = 0,
    ):
        codes = list(codes or [])
        is_heading = raw_length == 0 and not codes

        health_score = 1.0
        if raw_length > 0:
            health_score = match_length / raw_length

        if not is_heading and health_score < self.HEALTH_THRESHOLD:
            percentage = round(health_score * 100, 1)
            threshold = round(self.HEALTH_THRESHOLD * 100, 1)
            self.write_log(
                f"Discarded entry group '{description}' due to health failure "
                f"({percentage}% score falls below required {threshold}% threshold).",
                "WARN",
            )
            return

        grouped_formats: OrderedDict[str, list[str]] = OrderedDict()

        for code in codes:
            format_key = "Unknown"
            clean_code = code.strip().upper()

            if format_override:
                format_key = format_override
            elif system_name:
                parse_result = self.invoke_system_parser(system_name, clean_code)
                if parse_result:
                    format_key = parse_result.format
                    clean_code = parse_result.code

            grouped_formats.setdefault(format_key, []).append(clean_code)

        if is_heading:
            grouped_formats["Heading"] = []

        for fmt, fmt_codes in grouped_formats.items():
            composite_key = f"{description}:::{fmt}"

            if composite_key not in self.cheat_database:
                self.cheat_database[composite_key] = CheatEntry(
                    base_desc=description,
                    format=fmt,
                    codes=list(fmt_codes),
                    health=health_score,
                    tags={
                        "IsHeading": is_heading,
                        "AccumulatedRawLength": raw_length,
                        "AccumulatedMatchLength": match_length,
                    },
                )
            else:
                entry = self.cheat_database[composite_key]
                entry.codes.extend(fmt_codes)
                entry.tags["AccumulatedRawLength"] += raw_length
                entry.tags["AccumulatedMatchLength"] += match_length
                total_raw = entry.tags["AccumulatedRawLength"]
                if total_raw > 0:
                    entry.health = (
                        entry.tags["AccumulatedMatchLength"] / total_raw
                    )

    # =========================================================================
    # UNIFIED CHEAT ENGINE
    # =========================================================================

    def invoke_unified_cheat_engine(
        self,
        lines: list[str],
        system_name: str,
        layout_type: str,
        name_header_regex: Optional[str] = None,
        code_header_regex: Optional[str] = None,
        delimiter: Optional[str] = None,
        parse_func: Optional[Callable[..., Any]] = None,
    ):
        if not lines:
            return

        system_key = self.SYSTEM_KEY_MAP.get(system_name, system_name)
        metrics = ParseMetrics()

        def check_line_metrics(chk_line: str, is_description: bool) -> bool:
            metrics.lines_processed += 1
            if is_description:
                metrics.code_names_found += 1

            p_res = self.invoke_system_parser(system_key, chk_line)
            if p_res:
                metrics.codes_found += 1

            if metrics.lines_processed == 50:
                density = metrics.codes_found / 50.0
                if density < 0.04:
                    self.write_log(
                        "File verification failed at line 50: Code density "
                        f"({round(density * 100, 1)}%) falls below required "
                        "4% schema rule standard.",
                        "WARN",
                    )
                    QMessageBox.warning(
                        self,
                        "Verification Guard Warning",
                        "File verification failed: Content density does not "
                        "match the selected Input Module schema.",
                    )
                    self.cheat_database.clear()
                    return False
            return True

        rolling_parent_category = "Unassigned Code Block"
        has_prompted_for_merge = False
        merge_categories_toggle = False

        if layout_type == "1to1":
            for line in lines:
                trimmed = line.strip()
                if not trimmed or trimmed.startswith("#"):
                    continue

                raw_code = ""
                raw_desc = "Unassigned Code Block"
                is_description = False

                if delimiter:
                    parts = regex.split(delimiter, trimmed, maxsplit=1)
                    raw_code = parts[0].strip()
                    if len(parts) > 1:
                        raw_desc = parts[1].replace("'", "").strip()
                        is_description = bool(raw_desc)
                elif name_header_regex and code_header_regex:
                    name_match = regex.search(name_header_regex, trimmed)
                    code_match = regex.search(code_header_regex, trimmed)
                    if name_match:
                        raw_desc = name_match.group(1).replace("'", "").strip()
                        is_description = True
                    if code_match:
                        raw_code = code_match.group(1).strip()
                else:
                    raw_code = trimmed

                if not check_line_metrics(raw_code, is_description):
                    return

                parse_result = self.invoke_system_parser(system_key, raw_code)
                code_array: list[str] = []
                match_length = 0

                if parse_result:
                    code_array = [parse_result.code]
                    match_length = parse_result.match_length

                if match_length == 0 and raw_code:
                    rolling_parent_category = raw_desc
                    self.add_cheat_to_database(
                        raw_desc, [], system_key, raw_length=0, match_length=0
                    )
                    continue

                final_title = (
                    f"{rolling_parent_category} - {raw_desc}"
                    if merge_categories_toggle
                    and rolling_parent_category != "Unassigned Code Block"
                    else raw_desc
                )

                self.add_cheat_to_database(
                    final_title,
                    code_array,
                    system_key,
                    raw_length=len(raw_code),
                    match_length=match_length,
                )

        elif layout_type == "1few":
            current_header = "Unassigned Code Block"
            current_codes: list[str] = []
            total_raw_length = 0
            total_match_length = 0

            def commit_block():
                nonlocal current_codes, total_raw_length, total_match_length
                if current_codes:
                    final_title = (
                        f"{rolling_parent_category} - {current_header}"
                        if merge_categories_toggle
                        and rolling_parent_category != "Unassigned Code Block"
                        else current_header
                    )
                    self.add_cheat_to_database(
                        final_title,
                        current_codes,
                        system_key,
                        raw_length=total_raw_length,
                        match_length=total_match_length,
                    )
                    current_codes = []

            for line in lines:
                trimmed = line.strip()
                if not trimmed:
                    continue

                is_description = False
                chk_line = trimmed

                if name_header_regex:
                    name_match = regex.search(name_header_regex, trimmed)
                else:
                    name_match = None

                if name_match:
                    is_description = True
                    chk_line = name_match.group(1).strip()

                    if not check_line_metrics(chk_line, is_description):
                        return

                    commit_block()
                    current_header = name_match.group(1).replace("'", "").strip()
                    if not current_header:
                        current_header = "Unassigned Code Block"

                    rolling_parent_category = current_header
                    self.add_cheat_to_database(
                        current_header, [], system_key,
                        raw_length=0, match_length=0
                    )
                    total_raw_length = 0
                    total_match_length = 0
                else:
                    clean_code_line = regex.sub(r"^[*\t\s#]+", "", trimmed)
                    if code_header_regex:
                        code_match = regex.search(code_header_regex, trimmed)
                    else:
                        code_match = None
                    if code_match:
                        clean_code_line = code_match.group(1).strip()

                    chk_line = clean_code_line
                    if not check_line_metrics(chk_line, is_description):
                        return

                    total_raw_length += len(clean_code_line)
                    parse_result = self.invoke_system_parser(
                        system_key, clean_code_line
                    )
                    if parse_result:
                        current_codes.append(parse_result.code)
                        total_match_length += parse_result.match_length

            commit_block()

        elif layout_type == "few1":
            if not parse_func or not name_header_regex or not code_header_regex:
                return

            desc_map: OrderedDict[str, str] = OrderedDict()
            code_map: OrderedDict[str, str] = OrderedDict()

            for line in lines:
                is_description = False
                chk_line = line

                desc_match = regex.search(name_header_regex, line)
                code_match = regex.search(code_header_regex, line)

                if desc_match:
                    desc_map[desc_match.group(1)] = desc_match.group(2).strip()
                    is_description = True
                    chk_line = desc_match.group(2).strip()
                elif code_match:
                    code_map[code_match.group(1)] = code_match.group(2).strip()
                    chk_line = code_match.group(2).strip()

                if not check_line_metrics(chk_line, is_description):
                    return

            for key, desc_text in desc_map.items():
                if key not in code_map:
                    if not has_prompted_for_merge:
                        has_prompted_for_merge = True
                        choice = QMessageBox.question(
                            self,
                            "Universal Category Layout Manager",
                            "Merge structural parent categories into code "
                            "description naming blocks?",
                            QMessageBox.Yes | QMessageBox.No,
                            QMessageBox.No,
                        )
                        merge_categories_toggle = choice == QMessageBox.Yes

                    rolling_parent_category = desc_text
                    self.add_cheat_to_database(
                        desc_text, [], system_key,
                        raw_length=0, match_length=0
                    )
                    continue

                parse_result = parse_func(code_map[key])
                if parse_result is None:
                    continue

                clean_codes = None
                raw_len = 0
                match_len = 0

                if isinstance(parse_result, dict):
                    clean_codes = parse_result.get("Codes")
                    raw_len = int(parse_result.get("RawLength", 0))
                    match_len = int(parse_result.get("MatchLength", 0))
                elif isinstance(parse_result, ParseResult):
                    clean_codes = [parse_result.code]
                    raw_len = len(code_map[key])
                    match_len = parse_result.match_length
                else:
                    clean_codes = [parse_result]

                if not clean_codes:
                    continue

                final_title = (
                    f"{rolling_parent_category} - {desc_text}"
                    if merge_categories_toggle
                    and rolling_parent_category != "Unassigned Code Block"
                    else desc_text
                )
                final_title = final_title.replace("'", "").strip()
                if not final_title:
                    final_title = "Unassigned Code Block"

                self.add_cheat_to_database(
                    final_title, list(clean_codes), system_key,
                    raw_length=raw_len, match_length=match_len
                )

        self.cheat_database[":::_METRICS:::Global"] = CheatEntry(
            base_desc="File Metrics Metadata Summary Record Instance",
            format="Heading",
            codes=[],
            health=1.0,
            tags={
                "IsHeading": True,
                "TelemetryMetrics": metrics,
            },
        )

        self.write_log(
            "File parsing complete. Summary Metrics -> "
            f"Total Lines Processed: {metrics.lines_processed} | "
            f"Unique Naming Elements Identified: {metrics.code_names_found} | "
            f"Format Match Codes Found: {metrics.codes_found}"
        )

    # =========================================================================
    # REFRESH / DIRTY STATE
    # =========================================================================

    def refresh_cheat_list(self):
        self.disable_list_events()
        try:
            self.lst_cheats.clear()

            descriptions = [
                entry.base_desc
                for entry in self.cheat_database.values()
                if entry.format != "Heading"
            ]
            self.lst_cheats.addItems(descriptions)

            self.is_dirty = False

            if self.lst_cheats.count() > 0:
                self.last_selected_index = 0
                self.lst_cheats.setCurrentRow(0)
                db_keys = self.visible_keys()
                selected_key = db_keys[0]

                self.suppress_events = True
                try:
                    self.txt_editor.setPlainText(
                        "\n".join(self.cheat_database[selected_key].codes)
                    )
                finally:
                    self.suppress_events = False
                self.is_dirty = False
            else:
                self.last_selected_index = -1
                self.suppress_events = True
                try:
                    self.txt_editor.clear()
                finally:
                    self.suppress_events = False

            self.update_ui_state()
        finally:
            self.enable_list_events()

    def save_current_selection_if_dirty(self) -> bool:
        if (
            self.is_dirty
            and self.last_selected_index >= 0
            and self.last_selected_index < self.lst_cheats.count()
        ):
            choice = QMessageBox.warning(
                self,
                "Unsaved Progress",
                "Save changes to the current group before proceeding?",
                QMessageBox.Yes | QMessageBox.No | QMessageBox.Cancel,
                QMessageBox.Cancel,
            )

            if choice == QMessageBox.Cancel:
                return False

            if choice == QMessageBox.Yes:
                db_keys = self.visible_keys()
                target_key = db_keys[self.last_selected_index]
                lines = [
                    x.strip().upper()
                    for x in self.txt_editor.toPlainText().splitlines()
                    if x.strip()
                ]
                self.cheat_database[target_key].codes = lines

            self.is_dirty = False

        return True

    # =========================================================================
    # IMPORT ENGINES
    # =========================================================================

    @staticmethod
    def read_text_lines(file_path: str) -> list[str]:
        with open(file_path, "r", encoding="utf-8-sig", errors="replace") as f:
            return f.read().splitlines()

    def import_retroarch_cht_engine(
        self, file_path: str, system_profile: str, parse_func: Callable[..., Any]
    ):
        if not os.path.exists(file_path):
            return
        lines = self.read_text_lines(file_path)
        self.invoke_unified_cheat_engine(
            lines,
            system_profile,
            "few1",
            r'^cheat(\d+)_desc\s*=\s*"(.*)"',
            r'^cheat(\d+)_code\s*=\s*"(.*)"',
            parse_func=parse_func,
        )

    def import_vba_clt_engine(self, file_path: str):
        if not os.path.exists(file_path):
            return

        with open(file_path, "rb") as f:
            data = f.read()

        if len(data) < 12:
            return

        total_records = struct.unpack_from("<I", data, 8)[0]
        remaining = len(data) - 12
        stride = 84
        if total_records > 0:
            calculated = remaining / total_records
            if calculated == 80:
                stride = 80

        lines = []
        for i in range(total_records):
            record_start = 12 + i * stride
            if record_start + stride > len(data):
                break

            code_offset = record_start + (28 if stride == 80 else 32)
            desc_offset = record_start + (48 if stride == 80 else 52)

            raw_code = data[code_offset:code_offset + 20].split(b"\x00", 1)[0].decode(
                "ascii", errors="ignore"
            ).strip()
            raw_desc = data[desc_offset:desc_offset + 32].split(
                b"\x00", 1
            )[0].decode("ascii", errors="ignore").strip()

            if not raw_desc:
                raw_desc = "Unassigned Code Block"
            if raw_code:
                lines.append(f"{raw_code}\t{raw_desc}")

        if lines:
            self.invoke_unified_cheat_engine(
                lines, "GBA", "1to1", delimiter=r"\t"
            )

    def import_myboy_cht_engine(self, file_path: str):
        if not os.path.exists(file_path):
            return

        try:
            root = ET.parse(file_path).getroot()
            stripped_lines = []

            for cheat in root.findall(".//cheat"):
                if cheat.get("type") != "cb":
                    continue
                name = cheat.get("name")
                if name is None:
                    name_node = cheat.find("name")
                    name = name_node.text if name_node is not None else None
                if not name:
                    continue

                clean_desc = name.replace("'", "").strip()
                if not clean_desc:
                    clean_desc = "Unassigned Code Block"

                stripped_lines.append(f"[NAME] {clean_desc}")

                for code_node in cheat.findall(".//code"):
                    raw = code_node.text or ""
                    if raw.strip():
                        stripped_lines.append(raw.strip())

            if stripped_lines:
                self.invoke_unified_cheat_engine(
                    stripped_lines,
                    "GBA",
                    "1few",
                    name_header_regex=r"^\[NAME\]\s*(.*)",
                )
        except Exception as exc:
            raise RuntimeError(f"Failed parsing MyBoy XML target: {exc}") from exc

    def import_kronos_yct_engine(self, file_path: str):
        if not os.path.exists(file_path):
            return

        with open(file_path, "rb") as f:
            data = f.read()

        if len(data) < 8 or data[:4] != b"YCHT":
            return

        total_records = data[7]
        pos = 8
        lines = []

        for _ in range(total_records):
            if pos + 13 > len(data):
                break

            type_bytes = data[pos:pos + 4]
            pos += 4
            type_byte = type_bytes[3]

            prefix = "D"
            if type_byte == 0x02:
                prefix = "3"
            elif type_byte == 0x03:
                prefix = "1"

            addr_bytes = data[pos:pos + 4]
            pos += 4
            if len(addr_bytes) < 4:
                break

            addr1 = f"{addr_bytes[0] & 0x0F:X}"
            addr2 = f"{addr_bytes[1]:02X}"
            addr3 = f"{addr_bytes[2]:02X}"
            addr4 = f"{addr_bytes[3]:02X}"
            full_addr = prefix + addr1 + addr2 + addr3 + addr4

            pos += 2
            val_bytes = data[pos:pos + 2]
            pos += 2
            if len(val_bytes) < 2:
                break

            raw_code_string = f"{full_addr} {val_bytes[0]:02X}{val_bytes[1]:02X}"

            if pos >= len(data):
                break
            name_length_byte = data[pos]
            pos += 1
            name_length = max(1, name_length_byte - 1)

            if pos + name_length + 5 > len(data):
                break

            raw_desc = data[pos:pos + name_length].split(
                b"\x00", 1
            )[0].decode("ascii", errors="ignore").strip()
            pos += name_length + 5

            if not raw_desc:
                raw_desc = "Unassigned Code Block"

            lines.append(f"{raw_code_string}\t{raw_desc}")

        if lines:
            self.invoke_unified_cheat_engine(
                lines, "Saturn", "1to1", delimiter=r"\t"
            )

    def import_nes_cht_engine(
        self, file_path: str, parse_func: Callable[[str], Any]
    ):
        if not os.path.exists(file_path):
            return

        lines = self.read_text_lines(file_path)
        preprocessed = []

        for line in lines:
            trimmed = line.strip()
            if not trimmed or trimmed.startswith("#"):
                continue

            active = trimmed.lstrip(":")
            parts = active.split(":")
            if len(parts) < 2:
                continue

            addr_index = 0
            prefix = ""
            if parts[0] in ("S", "SC", "C"):
                prefix = parts[0]
                addr_index = 1

            if len(parts) - addr_index < 2:
                continue

            address_hex = parts[addr_index]
            val1 = parts[addr_index + 1]

            compare_value = None
            if len(parts) == addr_index + 4:
                compare_value = parts[addr_index + 2]
                description = parts[addr_index + 3]
            elif len(parts) > addr_index + 4:
                compare_value = parts[addr_index + 2]
                description = ":".join(parts[addr_index + 3:])
            elif len(parts) == addr_index + 3:
                description = parts[addr_index + 2]
            else:
                description = "Unassigned Code Block"

            clean_desc = description.replace("'", "").strip()
            if not clean_desc:
                clean_desc = "Unassigned Code Block"

            code_list = []
            try:
                address_val = int(address_hex, 16) if pyre.fullmatch(
                    r"[0-9A-Fa-f]{4}", address_hex
                ) else 0
            except ValueError:
                address_val = 0

            if address_val >= 0x8000:
                raw_segment = f"{address_hex}:{val1}"
                if compare_value is not None:
                    raw_segment += f":{compare_value}"
                encoded = self.invoke_game_genie_encode_nes(raw_segment)
                if encoded:
                    code_list.append(encoded)

            if not code_list:
                raw_segment = (
                    f"{prefix}:{address_hex}:{val1}"
                    if prefix else f"{address_hex}:{val1}"
                )
                parse_result = self.invoke_system_parser("NES", raw_segment)
                if parse_result:
                    code_list.append(parse_result.code)
                else:
                    fallback = parse_func(f"{address_hex} {val1}")
                    if isinstance(fallback, dict) and fallback.get("Codes"):
                        code_list.extend(fallback["Codes"])
                    elif isinstance(fallback, str) and fallback:
                        code_list.append(fallback)

            for final_code in code_list:
                preprocessed.append(f"{final_code}\t{clean_desc}")

        if preprocessed:
            self.invoke_unified_cheat_engine(
                preprocessed, "NES", "1to1", delimiter=r"\t"
            )

    # =========================================================================
    # NES GAME GENIE
    # =========================================================================

    @staticmethod
    def convert_unmap_nes_char(c: str) -> int:
        return {
            "A": 0, "P": 1, "Z": 2, "L": 3,
            "G": 4, "I": 5, "T": 6, "Y": 7,
            "E": 8, "O": 9, "X": 10, "U": 11,
            "K": 12, "S": 13, "V": 14, "N": 15,
        }.get(c.upper(), 0)

    @staticmethod
    def convert_map_nes_char(v: int) -> str:
        return "APZLGITYEOXUKSVN"[v] if 0 <= v < 16 else "?"

    def invoke_game_genie_decode_nes(self, gg: str) -> Optional[str]:
        gg = gg.strip().upper()
        if len(gg) not in (6, 8):
            return None

        data = [self.convert_unmap_nes_char(c) for c in gg]
        data += [0] * (8 - len(data))

        address = 0x8000
        address |= (data[1] & 8) << 4
        address |= (data[2] & 7) << 4
        address |= (data[3] & 7) << 12
        address |= (data[3] & 8)
        address |= (data[4] & 7)
        address |= (data[4] & 8) << 8
        address |= (data[5] & 7) << 8

        value = 0
        check = 0
        have_check = len(gg) == 8

        if have_check:
            value |= (data[0] & 7)
            value |= (data[0] & 8) << 4
            value |= (data[1] & 7) << 4
            value |= (data[7] & 8)

            check |= (data[5] & 8)
            check |= (data[6] & 7)
            check |= (data[6] & 8) << 4
            check |= (data[7] & 7) << 4
            return f"{address:04X}:{value:02X}:{check:02X}"

        value |= (data[0] & 7)
        value |= (data[0] & 8) << 4
        value |= (data[1] & 7) << 4
        value |= (data[5] & 8)
        return f"{address:04X}:{value:02X}"

    def invoke_game_genie_encode_nes(self, raw: str) -> Optional[str]:
        parts = raw.split(":")
        if len(parts) < 2:
            return None

        try:
            address = int(parts[0], 16)
            value = int(parts[1], 16)
            check = int(parts[2], 16) if len(parts) == 3 else 0
        except ValueError:
            return None

        have_check = len(parts) == 3
        data = [0] * 8

        data[1] |= ((address >> 4) & 8)
        data[2] |= ((address >> 4) & 7)
        data[3] |= ((address >> 12) & 7)
        data[3] |= ((address >> 0) & 8)
        data[4] |= ((address >> 0) & 7)
        data[4] |= ((address >> 8) & 8)
        data[5] |= ((address >> 8) & 7)

        if have_check:
            data[0] |= ((value >> 0) & 7)
            data[0] |= ((value >> 4) & 8)
            data[1] |= ((value >> 4) & 7)
            data[2] |= 8
            data[7] |= ((value >> 0) & 8)
            data[5] |= ((check >> 0) & 8)
            data[6] |= ((check >> 0) & 7)
            data[6] |= ((check >> 4) & 8)
            data[7] |= ((check >> 4) & 7)
        else:
            data[0] |= ((value >> 0) & 7)
            data[0] |= ((value >> 4) & 8)
            data[1] |= ((value >> 4) & 7)
            data[5] |= ((value >> 0) & 8)

        length = 8 if have_check else 6
        return "".join(self.convert_map_nes_char(data[i]) for i in range(length))

    # =========================================================================
    # INPUT MODULE PARSERS
    # =========================================================================

    def parse_standard(self, system: str, text: str):
        result = self.invoke_system_parser(system, text)
        return result.code if result else None

    def parse_nes(self, text: str):
        if not text:
            return None
        result = self.invoke_system_parser("NES", text)
        if not result:
            return None

        clean = result.code
        match = pyre.fullmatch(
            r"([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?",
            clean,
        )
        if match:
            address = int(match.group(1), 16)
            if address >= 0x8000:
                encoded = self.invoke_game_genie_encode_nes(clean)
                if encoded:
                    return encoded
        return clean

    def parse_retroarch_global(self, input_block: str, target_module: str):
        if not target_module:
            return None

        results = []
        system_key = self.SYSTEM_KEY_MAP.get(target_module)
        total_match_length = 0

        if system_key in self.SYSTEM_CODE_PATTERNS:
            sanitized = input_block.replace("+", " ")
            for pattern_key, pattern in self.SYSTEM_CODE_PATTERNS[system_key].items():
                for match in pattern.finditer(sanitized):
                    clean = match.group(0).upper().strip()
                    if clean:
                        results.append(clean)
                        total_match_length += len(match.group(0))

        return {
            "Codes": results,
            "RawLength": len(input_block),
            "MatchLength": total_match_length,
        }

    # =========================================================================
    # MODULE REGISTRATION
    # =========================================================================

    def register_input_module(self, name, filter_string, parse_func, import_func):
        self.input_modules[name] = InputModule(
            name, filter_string, parse_func, import_func
        )

    def register_output_module(self, name, filter_string, export_func):
        self.output_modules[name] = OutputModule(
            name, filter_string, export_func
        )

    def _build_modules(self):
        # ---- Saturn ----
        self.register_input_module(
            "Sega Saturn",
            "Saturn Cheat Files (*.yct)",
            lambda text: self.parse_standard("Saturn", text),
            self.import_saturn,
        )
        self.register_output_module(
            "Kronos (.yct)",
            "Kronos Cheat Files (*.yct)",
            self.export_kronos_yct,
        )

        # ---- GBA ----
        self.register_input_module(
            "Game Boy Advance / GBA",
            "GBA Cheat Files (*.cht *.clt)",
            lambda text: self.parse_standard("GBA", text),
            self.import_gba,
        )
        self.register_output_module(
            "VBA-M (.clt)",
            "VBA Cheat Files (*.clt)",
            self.export_vba_clt,
        )

        # ---- SNES ----
        self.register_input_module(
            "Super Nintendo / SNES",
            "SNES Cheat Files (*.cht)",
            lambda text: self.parse_standard("SNES", text),
            self.import_snes,
        )
        self.register_output_module(
            "Snes9x (.cht)",
            "Snes9x Cheat Files (*.cht)",
            self.export_snes9x,
        )

        # ---- SMS ----
        self.register_input_module(
            "Sega Master System / SMS",
            "Master System Cheats (*.pat)",
            lambda text: self.parse_standard("SMS", text),
            self.import_sms,
        )
        self.register_output_module(
            "md.emu SMS (.pat)",
            "md.emu Cheat Files (*.pat)",
            self.export_pat,
        )

        # ---- Mega Drive ----
        self.register_input_module(
            "Sega Mega Drive / MD",
            "MD Cheats (*.pat)",
            lambda text: self.parse_standard("MD", text),
            self.import_md,
        )
        self.register_output_module(
            "md.emu MD (.pat)",
            "md.emu Cheat Files (*.pat)",
            self.export_pat,
        )

        # ---- PSX ----
        self.register_input_module(
            "Sony PlayStation / PSX (PCSXR)",
            "PCSXR Cheat Files (*.cht)",
            lambda text: self.parse_standard("PCSXR", text),
            self.import_pcsxr,
        )
        self.register_input_module(
            "Sony PlayStation / PSX (ePSXe)",
            "ePSXe Cheat Files (*.txt)",
            lambda text: self.parse_standard("ePSXe", text),
            self.import_epsxe,
        )
        self.register_output_module(
            "PCSXR (.cht)",
            "PCSXR Cheat Files (*.cht)",
            self.export_pcsxr,
        )
        self.register_output_module(
            "ePSXe (.txt)",
            "ePSXe Cheat Files (*.txt)",
            self.export_epsxe,
        )

        # ---- GBC ----
        self.register_input_module(
            "Game Boy / GBC",
            "GBC Cheat Files (*.gbcht)",
            lambda text: self.parse_standard("GBC", text),
            self.import_gbc,
        )
        self.register_output_module(
            "GBC.emu (.gbcht)",
            "GBC Cheat Files (*.gbcht)",
            self.export_gbc,
        )

        # ---- Nintendo DS ----
        self.register_input_module(
            "Nintendo DS",
            "NDS Cheat Files (*.mch)",
            lambda text: self.parse_standard("NDS", text),
            self.import_nds,
        )
        self.register_output_module(
            "melonDS (.mch)",
            "melonDS Cheat Files (*.mch)",
            self.export_nds,
        )

        # ---- NES ----
        self.register_input_module(
            "Nintendo NES",
            "NES Cheat Files (*.cht)",
            self.parse_nes,
            self.import_nes,
        )
        self.register_output_module(
            "nes.emu (.cht)",
            "nes.emu Cheat Files (*.cht)",
            self.export_nes,
        )

        # ---- RetroArch Global ----
        self.register_input_module(
            "RetroArch (Global)",
            "RetroArch Cheat Files (*.cht)",
            self.parse_retroarch_global,
            self.import_retroarch_global,
        )
        self.register_output_module(
            "RetroArch (.cht)",
            "RetroArch Cheat Files (*.cht)",
            self.export_retroarch,
        )

        # Dynamic RetroArch target list uses the same module map as PowerShell.
        # The output module is deliberately registered last so the UI can
        # populate target-specific and generic RetroArch output choices.

    # =========================================================================
    # IMPORT DISPATCH
    # =========================================================================

    def sniff_text(self, file_path: str, count: int = 3) -> str:
        lines = self.read_text_lines(file_path)[:count]
        return " ".join(lines).strip()

    def import_saturn(self, file_path, system_profile, parse_func):
        sniff = self.sniff_text(file_path)
        if pyre.search(r"^cheats\s*=", sniff) or pyre.search(
            r"^cheat\d+_", sniff
        ):
            self.import_retroarch_cht_engine(
                file_path, system_profile, parse_func
            )
        else:
            self.import_kronos_yct_engine(file_path)

    def import_gba(self, file_path, system_profile, parse_func):
        sniff = self.sniff_text(file_path)
        if pyre.search(r"^cheats\s*=", sniff) or pyre.search(
            r"^cheat\d+_", sniff
        ):
            self.import_retroarch_cht_engine(
                file_path, system_profile, parse_func
            )
        elif "<?xml" in sniff and "<cheats>" in sniff:
            self.import_myboy_cht_engine(file_path)
        else:
            with open(file_path, "rb") as f:
                buffer = f.read(12)
            if len(buffer) >= 12:
                sig = " ".join(f"{b:02X}" for b in buffer)
                if pyre.fullmatch(
                    r"01 00 00 00 (01|00) 00 00 00 [0-9A-Fa-f]{2} 00 00 00",
                    sig,
                    pyre.IGNORECASE,
                ):
                    self.import_vba_clt_engine(file_path)
                else:
                    raise ValueError(
                        "Unknown or invalid binary cheat file format signature."
                    )
            else:
                raise ValueError(
                    "File is too small to contain a valid binary cheat header."
                )

    def import_snes(self, file_path, system_profile, parse_func):
        lines = self.read_text_lines(file_path)
        preprocessed = []
        current_name = None

        for line in lines:
            trimmed = line.strip()
            match = pyre.match(r"^name:\s*(.*)", trimmed)
            if match:
                current_name = match.group(1).strip()
            else:
                match = pyre.match(r"^code:\s*(.*)", trimmed)
                if match and current_name is not None:
                    clean_code = match.group(1).strip().replace("=", "")
                    preprocessed.append(f"{clean_code}\t{current_name}")
                    current_name = None

        if preprocessed:
            self.invoke_unified_cheat_engine(
                preprocessed, "SNES", "1to1", delimiter=r"\t"
            )

    def import_sms(self, file_path, system_profile, parse_func):
        self.invoke_unified_cheat_engine(
            self.read_text_lines(file_path),
            "SMS", "1to1", delimiter=r"\t"
        )

    def import_md(self, file_path, system_profile, parse_func):
        self.invoke_unified_cheat_engine(
            self.read_text_lines(file_path),
            "MD", "1to1", delimiter=r"\t"
        )

    def import_pcsxr(self, file_path, system_profile, parse_func):
        self.invoke_unified_cheat_engine(
            self.read_text_lines(file_path),
            "PCSXR", "1few",
            name_header_regex=r"^\[(.*)\]"
        )

    def import_epsxe(self, file_path, system_profile, parse_func):
        self.invoke_unified_cheat_engine(
            self.read_text_lines(file_path),
            "ePSXe", "1few",
            name_header_regex=r"^#(.*)"
        )

    def import_gbc(self, file_path, system_profile, parse_func):
        with open(file_path, "rb") as f:
            data = f.read()

        if len(data) < 4:
            return

        total_records = data[1]
        pos = 3
        preprocessed = []

        for _ in range(total_records):
            if pos + 3 > len(data):
                break

            status = data[pos]
            desc_len = data[pos + 1]
            null_sep = data[pos + 2]
            pos += 3

            if pos + desc_len > len(data):
                break

            raw_desc = data[pos:pos + desc_len].decode(
                "ascii", errors="ignore"
            ).strip()
            pos += desc_len

            if pos + 1 > len(data):
                break

            prefix_byte = data[pos]
            pos += 1
            code_len = 11 if prefix_byte == 0x0B else 8

            if pos + code_len > len(data):
                break

            raw_code = data[pos:pos + code_len].decode(
                "ascii", errors="ignore"
            ).strip()
            pos += code_len

            if not raw_desc:
                raw_desc = "Unassigned Code Block"
            if raw_code:
                preprocessed.append(f"{raw_code}\t{raw_desc}")

        if preprocessed:
            self.invoke_unified_cheat_engine(
                preprocessed, "GBC", "1to1", delimiter=r"\t"
            )

    def import_nds(self, file_path, system_profile, parse_func):
        self.invoke_unified_cheat_engine(
            self.read_text_lines(file_path),
            "NDS", "1few",
            name_header_regex=r"^CODE\s+\d+\s*(.*)"
        )

    def import_nes(self, file_path, system_profile, parse_func):
        sniff = self.sniff_text(file_path)
        if pyre.search(r"^cheats\s*=", sniff) or pyre.search(
            r"^cheat\d+_", sniff
        ):
            self.import_retroarch_cht_engine(
                file_path, system_profile, parse_func
            )
        else:
            self.import_nes_cht_engine(file_path, parse_func)

    def import_retroarch_global(self, file_path, system_profile, parse_func):
        self.import_retroarch_cht_engine(
            file_path, system_profile, parse_func
        )

    # =========================================================================
    # EXPORT HELPERS
    # =========================================================================

    def iter_export_entries(self):
        for entry in self.cheat_database.values():
            if entry.format != "Heading":
                yield entry

    @staticmethod
    def ascii_clean(text: str) -> str:
        return pyre.sub(r"[^\x20-\x7E]", "", text)

    def export_kronos_yct(self, file_path):
        chunks = [bytes((0x59, 0x43, 0x48, 0x54, 0, 0, 0))]
        total = 0

        entries = list(self.iter_export_entries())
        for entry in entries:
            for code in entry.codes:
                if pyre.match(r"^[Dd13][0-9A-Fa-f]{7}", code):
                    total += 1

        chunks.append(bytes((total & 0xFF,)))

        for entry in entries:
            cnam = self.ascii_clean(entry.base_desc)[:255]
            cnam_bytes = cnam.encode("ascii", errors="ignore")
            chdg_count = (len(cnam_bytes) + 1) & 0xFF

            for code in entry.codes:
                parts = pyre.split(r"\s+", code.strip())
                if len(parts) < 2:
                    continue

                part1 = parts[0].upper().ljust(8, "0")[:8]
                part2 = parts[1].upper().ljust(4, "0")[:4]
                ctyp = part1[0]

                if ctyp not in ("D", "1", "3"):
                    continue

                type_str = {"D": "01", "3": "02", "1": "03"}[ctyp]
                hex_string = (
                    "000000" + type_str + "0" + part1[1:8] + "0000" + part2
                )
                chunk = bytes.fromhex(hex_string)
                chunks.append(chunk)
                chunks.append(bytes((chdg_count,)))
                chunks.append(cnam_bytes)
                chunks.append(b"\x00" * 5)

        with open(file_path, "wb") as f:
            f.write(b"".join(chunks))

    def export_vba_clt(self, file_path):
        mask_map = {
            "0": 0xFF, "1": 0x70, "2": 0x21, "3": 0x00,
            "4": 0x09, "5": 0x24, "6": 0x0B, "7": 0x08,
            "8": 0x01, "9": 0xFF, "A": 0x0A, "B": 0x23,
            "C": 0x22, "D": 0x07, "E": 0x20, "F": 0x32,
        }

        entries = list(self.iter_export_entries())
        total = sum(len(e.codes) for e in entries)

        out = bytearray()
        out += struct.pack("<III", 1, 1, total)

        for entry in entries:
            safe_desc = self.ascii_clean(entry.base_desc)
            desc_bytes = safe_desc.encode("ascii", errors="ignore")[:32]
            desc_bytes = desc_bytes.ljust(32, b"\x00")

            data_lines_remaining = 0
            is_slide_next_line = False

            for code_item in entry.codes:
                parts = pyre.split(r"\s+", code_item.strip())
                if len(parts) < 2:
                    continue

                part1 = parts[0].upper().ljust(8, "0")[:8]
                part2 = parts[1].upper().ljust(4, "0")[:4]
                ctyp = part1[0]

                cd8 = int(part1, 16)
                cd8z = int("0" + part1[1:], 16)
                cd4 = int(part2, 16)

                is_multiline = False
                if data_lines_remaining > 0:
                    is_multiline = True
                    data_lines_remaining -= 1
                elif is_slide_next_line:
                    is_multiline = True
                    is_slide_next_line = False

                mask_val = 0xFF if is_multiline else mask_map.get(ctyp, 0)
                if mask_val == 0xFF:
                    cd8z = cd8

                code_str_bytes = code_item.encode("ascii", errors="ignore")[:20]
                code_str_bytes = code_str_bytes.ljust(20, b"\x00")

                out += b"\x00\x02\x00\x00"
                if is_multiline or ctyp in ("0", "9"):
                    out += b"\xFF\xFF\xFF\xFF"
                else:
                    out += bytes((mask_val, 0, 0, 0))
                out += struct.pack("<II", 0, 0)
                out += struct.pack("<I", cd8)
                out += struct.pack("<I", cd8z)
                out += struct.pack("<H", cd4)
                out += b"\x00" * 6
                out += code_str_bytes
                out += desc_bytes

                if not is_multiline:
                    if ctyp == "5":
                        halfword_count = int(part2, 16)
                        data_lines_remaining = (
                            math.floor(((halfword_count - 1) & 0xFFFF) / 3) + 1
                        )
                    elif ctyp == "4":
                        is_slide_next_line = True

        with open(file_path, "wb") as f:
            f.write(out)

    def export_snes9x(self, file_path):
        lines = []
        for entry in self.iter_export_entries():
            for code in entry.codes:
                output_code = code
                if len(output_code) == 8 and "-" not in output_code:
                    output_code = output_code[:6] + "=" + output_code[6:8]
                lines.append(
                    f"cheat\n  name: {entry.base_desc}\n  code: {output_code}\n"
                )
        Path(file_path).write_text(
            "\n".join(lines), encoding="utf-8"
        )

    def export_pat(self, file_path):
        lines = []
        for entry in self.iter_export_entries():
            for code in entry.codes:
                lines.append(f"{code}\t{entry.base_desc}")
        Path(file_path).write_text(
            "\n".join(lines) + ("\n" if lines else ""),
            encoding="utf-8",
        )

    def export_pcsxr(self, file_path):
        lines = []
        for entry in self.iter_export_entries():
            if not entry.codes:
                continue
            lines.append(f"[{entry.base_desc}]")
            lines.extend(entry.codes)
        Path(file_path).write_text(
            "\n".join(lines) + ("\n" if lines else ""),
            encoding="utf-8",
        )

    def export_epsxe(self, file_path):
        lines = []
        for entry in self.iter_export_entries():
            if not entry.codes:
                continue
            lines.append(f"#{entry.base_desc}")
            lines.extend(entry.codes)
        Path(file_path).write_text(
            "\n".join(lines) + ("\n" if lines else ""),
            encoding="utf-8",
        )

    def export_gbc(self, file_path):
        entries = list(self.iter_export_entries())
        total = sum(len(e.codes) for e in entries)

        out = bytearray()
        out += bytes((0x00, min(total, 255), 0x00))
        processed = 0

        for entry in entries:
            if processed >= 255:
                break

            safe_desc = self.ascii_clean(entry.base_desc)
            desc_bytes = safe_desc.encode("ascii", errors="ignore")

            for code in entry.codes:
                if processed >= 255:
                    break
                prefix_byte = 0x0B if "-" in code else 0x08
                code_bytes = code.encode("ascii", errors="ignore")
                out += bytes((0x00, len(desc_bytes) & 0xFF, 0x00))
                out += desc_bytes
                out += bytes((prefix_byte,))
                out += code_bytes
                processed += 1

        with open(file_path, "wb") as f:
            f.write(out)

    def export_nds(self, file_path):
        lines = ["CAT Cheats"]
        for entry in self.iter_export_entries():
            lines.append(f"CODE 0 {entry.base_desc}")
            lines.extend(entry.codes)
        Path(file_path).write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )

    def export_nes(self, file_path):
        lines = []

        for entry in self.iter_export_entries():
            clean_desc = entry.base_desc.strip()

            for code_item in entry.codes:
                for sub_code in code_item.split("+"):
                    raw_code = sub_code.strip().lstrip(":")

                    if len(raw_code) == 9 and pyre.fullmatch(
                        r"[A-Z]{9}", raw_code
                    ):
                        raw_code = raw_code[1:]

                    if pyre.fullmatch(r"[A-Z]{6}|[A-Z]{8}", raw_code):
                        decoded = self.invoke_game_genie_decode_nes(raw_code)
                        if decoded:
                            raw_code = decoded

                    match = pyre.fullmatch(
                        r"([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?",
                        raw_code,
                    )

                    if match:
                        addr_str, val_str, cmp_str = match.groups()
                        is_high = int(addr_str, 16) >= 0x8000
                        has_compare = cmp_str is not None

                        if is_high:
                            prefix = "SC:" if has_compare else "S:"
                        else:
                            prefix = "C:" if has_compare else ":"

                        body = (
                            f"{addr_str}:{val_str}:{cmp_str}"
                            if has_compare
                            else f"{addr_str}:{val_str}"
                        )
                        lines.append(f"{prefix}{body}:{clean_desc}")
                    else:
                        fallback = raw_code if raw_code.startswith(":") else ":" + raw_code
                        lines.append(f"{fallback}:{clean_desc}")

        Path(file_path).write_text(
            "\n".join(lines) + ("\n" if lines else ""),
            encoding="utf-8",
        )

    def export_retroarch(self, file_path):
        entries = list(self.iter_export_entries())
        lines = [f"cheats = {len(entries)}", ""]

        for idx, entry in enumerate(entries):
            joined = "+".join(entry.codes)
            lines.extend([
                f'cheat{idx}_desc = "{entry.base_desc}"',
                f'cheat{idx}_code = "{joined}"',
                f"cheat{idx}_enable = false",
                "",
            ])

        Path(file_path).write_text(
            "\n".join(lines), encoding="utf-8"
        )

    # =========================================================================
    # DYNAMIC INPUT / OUTPUT RELATIONSHIP
    # =========================================================================

    def update_output_module_choices(self):
        selected = self.cmb_input_module.currentText()
        if not selected:
            return

        self.cmb_output_module.blockSignals(True)
        try:
            self.cmb_output_module.clear()
            retro_output = "RetroArch (.cht)"

            if selected == "RetroArch (Global)":
                self.lbl_target_regex.setVisible(True)
                self.cmb_target_regex.setVisible(True)
                self.cmb_target_regex.setEnabled(True)

                target = self.cmb_target_regex.currentText()
                mapped = self.MODULE_OUTPUT_MAP.get(target)

                if mapped and mapped in self.output_modules:
                    self.cmb_output_module.addItem(mapped)

                if retro_output in self.output_modules:
                    self.cmb_output_module.addItem(retro_output)

                self.cmb_output_module.setEnabled(
                    self.cmb_output_module.count() > 0
                )
            else:
                if retro_output in self.output_modules:
                    self.cmb_output_module.addItem(retro_output)

                mapped = self.MODULE_OUTPUT_MAP.get(selected)
                if mapped and mapped in self.output_modules:
                    if self.cmb_output_module.findText(mapped) < 0:
                        self.cmb_output_module.addItem(mapped)

                self.cmb_output_module.setEnabled(
                    self.cmb_output_module.count() > 1
                )
                self.lbl_target_regex.setVisible(False)
                self.cmb_target_regex.setVisible(False)
                self.cmb_target_regex.setEnabled(False)

            if self.cmb_output_module.count():
                self.cmb_output_module.setCurrentIndex(0)
        finally:
            self.cmb_output_module.blockSignals(False)

    # =========================================================================
    # GUI EVENT HANDLERS
    # =========================================================================

    def import_file_dialog(self):
        if self.is_dirty:
            choice = QMessageBox.warning(
                self,
                "Unsaved Progress",
                "Discard unsaved changes?",
                QMessageBox.Yes | QMessageBox.No,
                QMessageBox.No,
            )
            if choice == QMessageBox.No:
                return

        selected_module = self.cmb_input_module.currentText()
        if not selected_module:
            return

        module = self.input_modules[selected_module]

        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Import Cheat File",
            self.last_directory,
            module.filter,
        )
        if not file_path:
            return

        self.last_directory = str(Path(file_path).parent)

        try:
            self.cheat_database.clear()

            if selected_module == "RetroArch (Global)":
                target_profile = self.cmb_target_regex.currentText()

                def parse_func(text):
                    return module.parse_func(text, target_profile)
            else:
                target_profile = selected_module
                parse_func = module.parse_func

            module.import_func(file_path, target_profile, parse_func)
            self.refresh_cheat_list()
            self.txt_new_group.clear()
            self.write_log("Import operation finalized.")
        except Exception as exc:
            self.write_log(
                f"Parsing error encountered: {exc}", "ERROR"
            )
            traceback.print_exc()

    def export_file_dialog(self):
        if not self.cheat_database:
            self.write_log(
                "No structural configuration items inside current registry "
                "matrix to process.",
                "WARN",
            )
            return

        selected_module = self.cmb_output_module.currentText()
        if not selected_module:
            return

        module = self.output_modules[selected_module]

        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Cheat File",
            self.last_directory,
            module.filter,
        )
        if not file_path:
            return

        self.last_directory = str(Path(file_path).parent)

        try:
            module.export_func(file_path)
            self.write_log("Export operation executed successfully.")
        except Exception as exc:
            self.write_log(
                f"Export operational crash footprint: {exc}", "ERROR"
            )
            traceback.print_exc()

    def list_selection_changed(self, new_index: int):
        if new_index == self.last_selected_index:
            return

        if (
            self.is_dirty
            and self.last_selected_index >= 0
            and self.last_selected_index < self.lst_cheats.count()
        ):
            choice = QMessageBox.warning(
                self,
                "Unsaved Progress",
                "Discard unsaved group modifications?",
                QMessageBox.Yes | QMessageBox.No,
                QMessageBox.No,
            )
            if choice == QMessageBox.No:
                blocker = QSignalBlocker(self.lst_cheats)
                self.lst_cheats.setCurrentRow(self.last_selected_index)
                del blocker
                return

        if new_index != -1:
            self.last_selected_index = new_index
            db_keys = self.visible_keys()
            if new_index >= len(db_keys):
                return

            selected_key = db_keys[new_index]
            self.suppress_events = True
            try:
                self.txt_editor.setPlainText(
                    "\n".join(self.cheat_database[selected_key].codes)
                )
            finally:
                self.suppress_events = False

            self.is_dirty = False

    def save_group_clicked(self):
        idx = self.lst_cheats.currentRow()
        if idx < 0:
            return

        db_keys = self.visible_keys()
        if idx >= len(db_keys):
            return

        target_key = db_keys[idx]
        entry = self.cheat_database[target_key]

        selected_input = self.cmb_input_module.currentText()
        sys_name = (
            self.cmb_target_regex.currentText()
            if selected_input == "RetroArch (Global)"
            else selected_input
        )
        system_key = self.SYSTEM_KEY_MAP.get(sys_name, sys_name)

        lines = [
            x for x in self.txt_editor.toPlainText().splitlines()
            if x.strip()
        ]

        updated_codes = []
        has_invalid_entries = False
        locked_format = None

        for line in lines:
            clean_line = line.strip().upper()
            parse_result = self.invoke_system_parser(system_key, clean_line)

            if parse_result:
                if locked_format is None:
                    locked_format = parse_result.format

                if parse_result.format == locked_format:
                    updated_codes.append(parse_result.code)
                else:
                    has_invalid_entries = True
                    self.write_log(
                        f"Line '{line}' rejected. Block locked to structure "
                        "protocol dynamic rules.",
                        "ERROR",
                    )
            else:
                has_invalid_entries = True
                self.write_log(
                    f"Line '{line}' tracking metric failure. Block syntax rejected.",
                    "ERROR",
                )

        if locked_format is None:
            locked_format = entry.format

        entry.codes = updated_codes
        entry.format = locked_format

        new_composite_key = f"{entry.base_desc}:::{locked_format}"

        if target_key != new_composite_key:
            new_db = OrderedDict()
            for key, value in self.cheat_database.items():
                if key == target_key:
                    new_db[new_composite_key] = entry
                else:
                    new_db[key] = value
            self.cheat_database = new_db
        else:
            self.cheat_database[target_key] = entry

        self.suppress_events = True
        try:
            self.txt_editor.setPlainText("\n".join(updated_codes))
        finally:
            self.suppress_events = False

        self.is_dirty = False

        if has_invalid_entries:
            QMessageBox.warning(
                self,
                "Format Isolation Rule",
                "Mismatched or invalid codes were detected and removed. "
                "A single block cannot mix different formats.",
            )
        else:
            self.write_log(
                f"Group '{entry.base_desc}' successfully updated as uniform "
                f"'{locked_format}' format."
            )

    def new_group_clicked(self):
        new_title = self.txt_new_group.text().strip()
        if not new_title:
            return

        if not self.save_current_selection_if_dirty():
            return

        selected_input = self.cmb_input_module.currentText()
        sys_name = (
            self.cmb_target_regex.currentText()
            if selected_input == "RetroArch (Global)"
            else selected_input
        )
        system_key = self.SYSTEM_KEY_MAP.get(sys_name, sys_name)

        inherited_format = "Unknown"
        patterns = self.SYSTEM_CODE_PATTERNS.get(system_key)
        if patterns:
            inherited_format = next(iter(patterns.keys()))

        composite_key = f"{new_title}:::{inherited_format}"

        if composite_key not in self.cheat_database:
            self.cheat_database[composite_key] = CheatEntry(
                base_desc=new_title,
                format=inherited_format,
                codes=[],
                health=1.0,
                tags={
                    "IsHeading": False,
                    "AccumulatedRawLength": 0,
                    "AccumulatedMatchLength": 0,
                },
            )

        self.txt_new_group.clear()

        self.disable_list_events()
        try:
            self.lst_cheats.addItem(new_title)
            idx = self.lst_cheats.count() - 1
            self.lst_cheats.setCurrentRow(idx)
            self.last_selected_index = idx

            self.suppress_events = True
            try:
                self.txt_editor.clear()
                self.is_dirty = False
            finally:
                self.suppress_events = False

            self.update_ui_state()
        finally:
            self.enable_list_events()

        self.write_log(
            f"Added new group '{new_title}' with inherited format standard "
            f"'{inherited_format}'."
        )

    def delete_group_clicked(self):
        idx = self.lst_cheats.currentRow()
        if idx < 0:
            return

        db_keys = self.visible_keys()
        if idx >= len(db_keys):
            return

        selected_key = db_keys[idx]
        display_title = self.cheat_database[selected_key].base_desc

        choice = QMessageBox.warning(
            self,
            "Confirm",
            f"Delete group '{display_title}'?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if choice == QMessageBox.No:
            return

        self.cheat_database.pop(selected_key, None)
        self.is_dirty = False

        self.disable_list_events()
        try:
            self.lst_cheats.takeItem(idx)

            if self.lst_cheats.count() > 0:
                new_idx = min(idx, self.lst_cheats.count() - 1)
                self.lst_cheats.setCurrentRow(new_idx)
                self.last_selected_index = new_idx

                next_keys = self.visible_keys()
                next_key = next_keys[new_idx]

                self.suppress_events = True
                try:
                    self.txt_editor.setPlainText(
                        "\n".join(self.cheat_database[next_key].codes)
                    )
                finally:
                    self.suppress_events = False
            else:
                self.last_selected_index = -1
                self.suppress_events = True
                try:
                    self.txt_editor.clear()
                finally:
                    self.suppress_events = False

            self.update_ui_state()
        finally:
            self.enable_list_events()

        self.write_log(f"Deleted group '{display_title}'.")

    def move_cheat_group(self, direction: int):
        idx = self.lst_cheats.currentRow()
        if idx < 0:
            return

        target_idx = idx + direction
        if target_idx < 0 or target_idx >= self.lst_cheats.count():
            return

        if not self.save_current_selection_if_dirty():
            return

        keys = list(self.cheat_database.keys())
        visible = self.visible_keys()

        k1 = visible[idx]
        k2 = visible[target_idx]

        idx1 = keys.index(k1)
        idx2 = keys.index(k2)
        keys[idx1], keys[idx2] = keys[idx2], keys[idx1]

        self.cheat_database = OrderedDict(
            (key, self.cheat_database[key]) for key in keys
        )

        self.disable_list_events()
        try:
            self.lst_cheats.clear()
            self.lst_cheats.addItems(
                entry.base_desc
                for entry in self.cheat_database.values()
                if entry.format != "Heading"
            )
            self.lst_cheats.setCurrentRow(target_idx)
            self.last_selected_index = target_idx
            self.is_dirty = False
        finally:
            self.enable_list_events()


# =============================================================================
# APPLICATION ENTRY POINT
# =============================================================================

def main():
    app = QApplication(sys.argv)
    app.setApplicationName("Multi-Emulator Cheat Reformatter")
    window = CheatReformatter()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
