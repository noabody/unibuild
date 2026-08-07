import sys
import re
from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QFont, QFontDatabase
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QGridLayout, QLabel, QComboBox, QPushButton, QListWidget,
    QTextEdit, QLineEdit, QMessageBox, QFileDialog
)
from core import CoreEngine, CheatEntry

class SuppressEvents:
    def __init__(self, ui_instance):
        self.ui = ui_instance
    def __enter__(self):
        self.ui.suppress_events = True
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.ui.suppress_events = False

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.core = CoreEngine()
        self.suppress_events = False
        self.core.log_callback = self.write_to_status_log
        self.init_ui()

    def init_ui(self):
        self.setWindowTitle("Multi-Emulator Cheat Reformatter")
        # 5% Width expansion (720 -> 750), 20% Height reduction (650 -> 520)
        self.setMinimumSize(QSize(750, 520))
        
        central_widget = QWidget(self)
        self.setCentralWidget(central_widget)
        master_layout = QVBoxLayout(central_widget)
        master_layout.setContentsMargins(10, 10, 10, 10)
        master_layout.setSpacing(8)

        # --- Row 0: Top Controls ---
        top_layout = QHBoxLayout()
        top_layout.addWidget(QLabel("Input Module:"))
        
        self.cmb_input_module = QComboBox()
        self.cmb_input_module.setFixedWidth(190)
        self.cmb_input_module.addItems(list(self.core.input_modules.keys()))
        top_layout.addWidget(self.cmb_input_module)
        
        self.btn_import = QPushButton("Import File")
        self.btn_import.setFixedWidth(100)
        top_layout.addWidget(self.btn_import)
        
        # Renamed text label and constrained visibility layout adjustments
        self.lbl_target_regex = QLabel("Target System Regex:")
        self.lbl_target_regex.setVisible(False)
        
        self.cmb_target_regex = QComboBox()
        self.cmb_target_regex.setFixedWidth(150)
        self.cmb_target_regex.setVisible(False)
        for key in self.core.input_modules.keys():
            if key != "RetroArch (Global)":
                self.cmb_target_regex.addItem(key)
                
        top_layout.addWidget(self.lbl_target_regex)
        top_layout.addWidget(self.cmb_target_regex)
        top_layout.addStretch()
        master_layout.addLayout(top_layout)

        # --- Row 1: Workspace Grid ---
        mid_grid = QGridLayout()
        mid_grid.setColumnStretch(0, 44)
        mid_grid.setColumnStretch(1, 56)

        # Left Column
        mid_grid.addWidget(QLabel("Grouped Cheat Descriptions:"), 0, 0)
        self.lst_cheats = QListWidget()
        mid_grid.addWidget(self.lst_cheats, 1, 0)

        left_action_layout = QHBoxLayout()
        left_action_layout.setSpacing(2)
        self.txt_new_group = QLineEdit()
        left_action_layout.addWidget(self.txt_new_group)
        
        self.btn_new_group = QPushButton("Add")
        self.btn_new_group.setFixedWidth(45)
        left_action_layout.addWidget(self.btn_new_group)
        
        self.btn_move_up = QPushButton("▲")
        self.btn_move_up.setFixedWidth(30)
        self.btn_move_up.setEnabled(False)
        left_action_layout.addWidget(self.btn_move_up)
        
        self.btn_move_down = QPushButton("▼")
        self.btn_move_down.setFixedWidth(30)
        self.btn_move_down.setEnabled(False)
        left_action_layout.addWidget(self.btn_move_down)
        
        self.btn_delete_group = QPushButton("❌")
        self.btn_delete_group.setFixedWidth(35)
        self.btn_delete_group.setEnabled(False)
        left_action_layout.addWidget(self.btn_delete_group)
        mid_grid.addLayout(left_action_layout, 2, 0)

        # Right Column
        mid_grid.addWidget(QLabel("Codes in Selected Group (One per line):"), 0, 1)
        self.txt_editor = QTextEdit()
        mono_font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        mono_font.setPointSize(10)
        self.txt_editor.setFont(mono_font)
        mid_grid.addWidget(self.txt_editor, 1, 1)

        self.btn_save_group = QPushButton("Update Current Group Modifications")
        self.btn_save_group.setEnabled(False)
        mid_grid.addWidget(self.btn_save_group, 2, 1)
        master_layout.addLayout(mid_grid, stretch=1)

        # --- Row 2: Export Controls ---
        export_layout = QHBoxLayout()
        export_layout.addWidget(QLabel("Export To:"))
        self.cmb_output_module = QComboBox()
        self.cmb_output_module.setFixedWidth(185)
        export_layout.addWidget(self.cmb_output_module)
        
        self.btn_export = QPushButton("Export File")
        self.btn_export.setFixedWidth(100)
        export_layout.addWidget(self.btn_export)
        export_layout.addStretch()
        master_layout.addLayout(export_layout)

        # --- Row 3 & 4: Log Module ---
        master_layout.addWidget(QLabel("System Activity Log:"))
        self.txt_status_log = QTextEdit()
        self.txt_status_log.setReadOnly(True)
        self.txt_status_log.setFixedHeight(60) # Scaled down marginally to fit global 20% UI reduction
        log_font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
        log_font.setPointSize(9)
        self.txt_status_log.setFont(log_font)
        master_layout.addWidget(self.txt_status_log)

        # Wiring Event Slots
        self.cmb_input_module.currentIndexChanged.connect(self.update_output_choices)
        self.cmb_target_regex.currentIndexChanged.connect(self.update_output_choices)
        self.btn_import.clicked.connect(self.on_import_clicked)
        self.btn_export.clicked.connect(self.on_export_clicked)
        self.lst_cheats.currentRowChanged.connect(self.on_list_selection_changed)
        self.txt_editor.textChanged.connect(self.on_editor_text_changed)
        self.btn_save_group.clicked.connect(self.on_save_group_clicked)
        self.btn_new_group.clicked.connect(self.on_new_group_clicked)
        self.txt_new_group.returnPressed.connect(self.btn_new_group.animateClick)
        self.btn_delete_group.clicked.connect(self.on_delete_group_clicked)
        self.btn_move_up.clicked.connect(lambda: self.move_cheat_group(-1))
        self.btn_move_down.clicked.connect(lambda: self.move_cheat_group(1))

        self.update_output_choices()

    def write_to_status_log(self, text):
        self.txt_status_log.append(text)

    def update_ui_state(self):
        has_items = self.lst_cheats.count() > 0
        self.btn_move_up.setEnabled(has_items)
        self.btn_move_down.setEnabled(has_items)
        self.btn_delete_group.setEnabled(has_items)
        self.btn_save_group.setEnabled(has_items)

    def refresh_cheat_list(self):
        with SuppressEvents(self):
            self.lst_cheats.clear()
            for key in self.core.cheat_database.keys():
                self.lst_cheats.addItem(key)
            self.core.is_dirty = False
            
            if self.lst_cheats.count() > 0:
                self.core.last_selected_index = 0
                self.lst_cheats.setCurrentRow(0)
                selected_desc = self.lst_cheats.currentItem().text()
                flattened = self.core.cheat_database[selected_desc].codes
                self.txt_editor.setPlainText("\n".join(flattened))
                self.core.is_dirty = False
            else:
                self.core.last_selected_index = -1
                self.txt_editor.clear()
        self.update_ui_state()

    def update_output_choices(self):
        selected_input = self.cmb_input_module.currentText()
        self.cmb_output_module.clear()
        ra_out = "RetroArch (.cht)"

        if selected_input == "RetroArch (Global)":
            self.lbl_target_regex.setVisible(True)
            self.cmb_target_regex.setVisible(True)
            target_sys = self.cmb_target_regex.currentText()
            mapped = self.core.module_output_map.get(target_sys)
            if mapped in self.core.output_modules:
                self.cmb_output_module.addItem(mapped)
            if ra_out in self.core.output_modules:
                self.cmb_output_module.addItem(ra_out)
            self.cmb_output_module.setEnabled(True)
        else:
            self.lbl_target_regex.setVisible(False)
            self.cmb_target_regex.setVisible(False)
            if ra_out in self.core.output_modules:
                self.cmb_output_module.addItem(ra_out)
            mapped = self.core.module_output_map.get(selected_input)
            if mapped in self.core.output_modules and mapped != ra_out:
                self.cmb_output_module.addItem(mapped)
            self.cmb_output_module.setEnabled(self.cmb_output_module.count() > 1)
        
        if self.cmb_output_module.count() > 0:
            self.cmb_output_module.setCurrentIndex(0)

    def save_selection_if_dirty(self):
        if self.core.is_dirty and 0 <= self.core.last_selected_index < self.lst_cheats.count():
            choice = QMessageBox.question(
                self, "Unsaved Progress",
                "Save changes to the current group before proceeding?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No | QMessageBox.StandardButton.Cancel,
                QMessageBox.StandardButton.Warning
            )
            if choice == QMessageBox.StandardButton.Cancel:
                return False
            if choice == QMessageBox.StandardButton.Yes:
                self.on_save_group_clicked()
            self.core.is_dirty = False
        return True

    def prompt_category_layout(self, text):
        choice = QMessageBox.question(
            self, "Category Layout Detected", text,
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )
        return choice == QMessageBox.StandardButton.Yes

    def on_import_clicked(self):
        if self.core.is_dirty:
            choice = QMessageBox.question(
                self, "Unsaved Progress", "Discard unsaved changes?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
            )
            if choice == QMessageBox.StandardButton.No:
                return

        selected_mod_name = self.cmb_input_module.currentText()
        module = self.core.input_modules[selected_mod_name]
        
        file_path, _ = QFileDialog.getOpenFileName(self, "Open Cheat File", "", module["filter"])
        if file_path:
            try:
                self.core.cheat_database.clear()
                target_sys = self.cmb_target_regex.currentText() if selected_mod_name == "RetroArch (Global)" else None
                
                def base_pf(text):
                    if selected_mod_name == "RetroArch (Global)":
                        return module["parse"](text, target_sys)
                    return module["parse"](text)

                module["import"](file_path, base_pf, self.prompt_category_layout)
                self.refresh_cheat_list()
                self.txt_new_group.clear()
                self.core.write_log("Import finished successfully!")
            except Exception as e:
                self.core.write_log(f"Parsing error: {str(e)}", "ERROR")

    def on_export_clicked(self):
        if not self.core.cheat_database:
            self.core.write_log("No cheats loaded to export.", "WARN")
            return

        selected_out_name = self.cmb_output_module.currentText()
        module = self.core.output_modules[selected_out_name]
        
        file_path, _ = QFileDialog.getSaveFileName(self, "Save Cheat File", "", module["filter"])
        if file_path:
            try:
                module["export"](file_path)
                self.core.write_log("Export finished successfully!")
            except Exception as e:
                self.core.write_log(f"Export error: {str(e)}", "ERROR")

    def on_list_selection_changed(self, row):
        if self.suppress_events or row == self.core.last_selected_index or row < 0:
            return

        if self.core.is_dirty and 0 <= self.core.last_selected_index < self.lst_cheats.count():
            choice = QMessageBox.question(
                self, "Unsaved Progress", "Discard unsaved group modifications?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
            )
            if choice == QMessageBox.StandardButton.No:
                with SuppressEvents(self):
                    self.lst_cheats.setCurrentRow(self.core.last_selected_index)
                return

        self.core.last_selected_index = row
        selected_desc = self.lst_cheats.item(row).text()
        
        with SuppressEvents(self):
            flattened = self.core.cheat_database[selected_desc].codes
            self.txt_editor.setPlainText("\n".join(flattened))
            self.core.is_dirty = False

    def on_editor_text_changed(self):
        if self.suppress_events:
            return
        self.core.is_dirty = True

    def on_save_group_clicked(self):
        current_item = self.lst_cheats.currentItem()
        if not current_item:
            return
        selected_desc = current_item.text().strip()
        
        target_key = None
        if selected_desc in self.core.cheat_database:
            target_key = selected_desc
        else:
            for k in self.core.cheat_database.keys():
                if k.strip().lower() == selected_desc.lower():
                    target_key = k
                    break
        
        if not target_key:
            self.core.write_log(f"Error: Group '{selected_desc}' not found.", "ERROR")
            return

        selected_mod = self.cmb_input_module.currentText()
        target_sys = self.cmb_target_regex.currentText() if selected_mod == "RetroArch (Global)" else None
        module = self.core.input_modules[selected_mod]

        def pf(text):
            if selected_mod == "RetroArch (Global)":
                return module["parse"](text, target_sys)
            return module["parse"](text)

        clean_codes = pf(self.txt_editor.toPlainText())
        updated_codes = list(clean_codes) if clean_codes else []

        entry = self.core.cheat_database[target_key]
        detected_type = self.core.get_code_type(updated_codes[0] if updated_codes else None)
        final_key = target_key

        if entry.code_type != detected_type and entry.code_type != "Unknown" and detected_type != "Unknown":
            base_desc = entry.base_desc if entry.base_desc else re.sub(r'\s*\[.*\]$', '', target_key)
            final_key = f"{base_desc} [{detected_type}]"

            del self.core.cheat_database[target_key]
            self.core.cheat_database[final_key] = CheatEntry(base_desc, detected_type, updated_codes)

            with SuppressEvents(self):
                current_item.setText(final_key)
        else:
            if entry.code_type == "Unknown" and detected_type != "Unknown":
                entry.code_type = detected_type
            entry.codes = updated_codes
            self.core.cheat_database[target_key] = entry

        with SuppressEvents(self):
            self.txt_editor.setPlainText("\n".join(updated_codes))
        
        self.core.is_dirty = False
        self.core.write_log(f"Group '{final_key}' data updated successfully.")

    def on_new_group_clicked(self):
        new_title = self.txt_new_group.text().strip()
        if not new_title:
            return
        if new_title in self.core.cheat_database:
            self.core.write_log(f"Group name '{new_title}' already exists.", "WARN")
            return
        if not self.save_selection_if_dirty():
            return

        self.core.add_cheat_to_database(new_title, [])
        self.txt_new_group.clear()

        with SuppressEvents(self):
            self.lst_cheats.addItem(new_title)
            self.lst_cheats.setCurrentRow(self.lst_cheats.count() - 1)
            self.core.last_selected_index = self.lst_cheats.currentRow()
            self.txt_editor.clear()
            self.core.is_dirty = False
        self.update_ui_state()
        self.core.write_log(f"Added new group '{new_title}'.")

    def on_delete_group_clicked(self):
        row = self.lst_cheats.currentRow()
        if row < 0:
            return
        selected_desc = self.lst_cheats.currentItem().text()

        choice = QMessageBox.question(
            self, "Confirm Delete", f"Delete group '{selected_desc}'?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )
        if choice == QMessageBox.StandardButton.No:
            return

        del self.core.cheat_database[selected_desc]
        self.core.is_dirty = False

        with SuppressEvents(self):
            self.lst_cheats.takeItem(row)
            if self.lst_cheats.count() > 0:
                new_row = row if row < self.lst_cheats.count() else self.lst_cheats.count() - 1
                self.lst_cheats.setCurrentRow(new_row)
                self.core.last_selected_index = new_row
                next_desc = self.lst_cheats.currentItem().text()
                flattened = self.core.cheat_database[next_desc].codes
                self.txt_editor.setPlainText("\n".join(flattened))
            else:
                self.core.last_selected_index = -1
                self.txt_editor.clear()
        self.update_ui_state()
        self.core.write_log(f"Deleted group '{selected_desc}'.")

    def move_cheat_group(self, direction):
        row = self.lst_cheats.currentRow()
        if row < 0:
            return
        target_row = row + direction
        if not (0 <= target_row < self.lst_cheats.count()):
            return
        if not self.save_selection_if_dirty():
            return

        keys = list(self.core.cheat_database.keys())
        keys[row], keys[target_row] = keys[target_row], keys[row]

        new_db = {k: self.core.cheat_database[k] for k in keys}
        self.core.cheat_database = new_db

        with SuppressEvents(self):
            self.lst_cheats.clear()
            for k in self.core.cheat_database.keys():
                self.lst_cheats.addItem(k)
            self.lst_cheats.setCurrentRow(target_row)
            self.core.last_selected_index = target_row
            self.core.is_dirty = False

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())
