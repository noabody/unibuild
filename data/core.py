import os
import re
import struct
import xml.etree.ElementTree as ET
from datetime import datetime

class CheatEntry:
    def __init__(self, base_desc, code_type="Unknown", codes=None):
        self.base_desc = base_desc
        self.code_type = code_type
        self.codes = codes if codes is not None else []

class CoreEngine:
    def __init__(self):
        self.cheat_database = {}  # Dict preserving insertion order (Python 3.7+)
        self.is_dirty = False
        self.last_selected_index = -1
        self.log_callback = None

        # Compiled Regex Patterns Registry
        self.regex_patterns = {
            "AddressAndValue": re.compile(r'([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4,8})'),
            "TripleGroupHyphen": re.compile(r'([0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}-[0-9A-Fa-f]{3})'),
            "SnesCombined": re.compile(r'([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}=[0-9A-Fa-f]{2}|[0-9A-Fa-f]{8})'),
            "SmsMdExtended": re.compile(r'([0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}|[0-9A-Fa-f]{6}:[0-9A-Fa-f]{4}|[0-9A-Z]{4}-[0-9A-Z]{4})'),
            "GbcCombined": re.compile(r'([0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}|[0-9A-Fa-f]{8})'),
            "NesCombined": re.compile(r'([A-Na-nO-Zo-z0-9]{6,8}|[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2})?)')
        }

        self.module_output_map = {
            "Game Boy / GBC": "GBC.emu (.gbcht)",
            "Game Boy Advance / GBA": "VBA-M (.clt)",
            "Super Nintendo / SNES": "Snes9x (.cht)",
            "Nintendo DS": "melonDS (.mch)",
            "Nintendo NES": "nes.emu (.cht)",
            "Sega Master System / SMS": "md.emu SMS (.pat)",
            "Sega Mega Drive / MD": "md.emu MD (.pat)",
            "Sega Saturn": "Kronos (.yct)",
            "Sony PlayStation / PSX (PCSXR)": "PCSXR (.cht)",
            "Sony PlayStation / PSX (ePSXe)": "ePSXe (.txt)"
        }

        self.input_modules = {}
        self.output_modules = {}
        self._register_modules()

    def write_log(self, message, level="INFO"):
        timestamp = datetime.now().strftime("%H:%M:%S")
        log_entry = f"[{timestamp}] [{level}] {message}"
        if self.log_callback:
            self.log_callback(log_entry)
        else:
            print(log_entry)

    def invoke_universal_regex_parser(self, raw_text, pattern_key, formatter=None):
        if not raw_text or not raw_text.strip():
            return []
        pattern = self.regex_patterns.get(pattern_key)
        if not pattern:
            pattern = re.compile(pattern_key, re.IGNORECASE)
        
        matches = pattern.finditer(raw_text)
        extracted_codes = []
        for m in matches:
            if formatter:
                parsed = formatter(m)
            else:
                parsed = m.group(0).upper().strip()
            if parsed and parsed.strip():
                extracted_codes.append(parsed)
        return extracted_codes

    def get_code_type(self, code):
        if not code or not code.strip():
            return "Unknown"
        if "-" in code:
            return "GG"
        clean_split = code.split()
        if clean_split and len(clean_split[-1]) == 4:
            return "SHORT"
        return "RAW"

    def add_cheat_to_database(self, description, codes, type_override=None):
        detected_type = "Unknown"
        if codes:
            detected_type = type_override if type_override else self.get_code_type(codes[0])
        elif type_override:
            detected_type = type_override

        if description not in self.cheat_database:
            self.cheat_database[description] = CheatEntry(description, detected_type, list(codes))
            return

        if not codes:
            return

        existing_entry = self.cheat_database[description]
        if existing_entry.code_type == detected_type or existing_entry.code_type == "Unknown":
            if existing_entry.code_type == "Unknown":
                existing_entry.code_type = detected_type
            for c in codes:
                if c not in existing_entry.codes:
                    existing_entry.codes.append(c)
            return

        type_key = f"{description} [{detected_type}]"
        if type_key not in self.cheat_database:
            self.cheat_database[type_key] = CheatEntry(description, detected_type, list(codes))
        else:
            for c in codes:
                if c not in self.cheat_database[type_key].codes:
                    self.cheat_database[type_key].codes.append(c)

    # --- Shared Engine Parsers ---
    def import_retroarch_cht_engine(self, file_path, parse_func, prompt_callback):
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        
        desc_map = {}
        code_map = {}
        category_header = "Unassigned Code Block"

        desc_re = re.compile(r'^cheat(\d+)_desc\s*=\s*"(.*)"', re.IGNORECASE)
        code_re = re.compile(r'^cheat(\d+)_code\s*=\s*"(.*)"', re.IGNORECASE)

        for line in lines:
            m_desc = desc_re.match(line.strip())
            if m_desc:
                desc_map[m_desc.group(1)] = m_desc.group(2).strip()
            m_code = code_re.match(line.strip())
            if m_code:
                code_map[m_code.group(1)] = m_code.group(2).strip()

        has_orphans = any(k not in code_map for k in desc_map.keys())
        merge_categories = False
        if has_orphans and prompt_callback:
            merge_categories = prompt_callback(
                "Cheat descriptions found without matching codes.\n\n"
                "Treat empty labels as parent categories and group subsequent blocks?"
            )

        for k in sorted(desc_map.keys(), key=int):
            desc_text = desc_map[k]
            if k not in code_map:
                if merge_categories:
                    category_header = desc_text
                continue

            clean_codes = parse_func(code_map[k])
            if not clean_codes:
                continue

            final_title = f"{category_header} - {desc_text}" if merge_categories else desc_text
            final_title = final_title.replace("'", "").strip()
            if not final_title:
                final_title = "Unassigned Code Block"

            self.add_cheat_to_database(final_title, clean_codes)

    def import_vba_clt_engine(self, file_path, parse_func):
        with open(file_path, 'rb') as f:
            file_bytes = f.read()
        
        if len(file_bytes) < 12:
            return
        
        total_records = struct.unpack('<I', file_bytes[8:12])[0]
        remaining_bytes = len(file_bytes) - 12
        stride = 84
        if total_records > 0:
            if (remaining_bytes / total_records) == 80:
                stride = 80

        grouped_cheats = {}
        for i in range(total_records):
            record_start = 12 + (i * stride)
            if record_start + stride > len(file_bytes):
                break

            code_offset = record_start + 28 if stride == 80 else record_start + 32
            desc_offset = record_start + 48 if stride == 80 else record_start + 52

            raw_code = file_bytes[code_offset:code_offset+20].split(b'\x00')[0].decode('ascii', errors='ignore')
            raw_desc = file_bytes[desc_offset:desc_offset+32].split(b'\x00')[0].decode('ascii', errors='ignore')

            clean_desc = raw_desc.replace("'", "").strip()
            if not clean_desc:
                clean_desc = "Unassigned Code Block"

            clean_codes = parse_func(raw_code)
            if clean_codes:
                if clean_desc not in grouped_cheats:
                    grouped_cheats[clean_desc] = []
                grouped_cheats[clean_desc].extend(clean_codes)

        for desc, codes in grouped_cheats.items():
            self.add_cheat_to_database(desc, codes)

    def import_myboy_cht_engine(self, file_path, parse_func):
        tree = ET.parse(file_path)
        root = tree.getroot()
        for cheat in root.findall('cheat'):
            if cheat.get('type') == 'cb':
                name_node = cheat.find('name')
                if name_node is None or not name_node.text:
                    continue
                clean_desc = name_node.text.replace("'", "").strip()
                if not clean_desc:
                    clean_desc = "Unassigned Code Block"

                code_elements = cheat.findall('code')
                raw_code_block = " ".join([c.text for c in code_elements if c.text])
                normalized_codes = parse_func(raw_code_block)
                if normalized_codes:
                    self.add_cheat_to_database(clean_desc, normalized_codes)

    def import_kronos_yct_engine(self, file_path, parse_func):
        with open(file_path, 'rb') as f:
            file_bytes = f.read()
        
        if len(file_bytes) < 8:
            return
        magic = file_bytes[0:4].decode('ascii', errors='ignore')
        if magic != "YCHT":
            return
        
        total_records = file_bytes[7]
        offset = 8
        intermediate_list = []

        for _ in range(total_records):
            if offset + 13 > len(file_bytes):
                break
            
            type_byte = file_bytes[offset + 3]
            prefix = "D"
            if type_byte == 0x02:
                prefix = "3"
            elif type_byte == 0x03:
                prefix = "1"

            addr_bytes = file_bytes[offset + 4:offset + 8]
            addr1 = f"{(addr_bytes[0] & 0x0F):X1}"
            addr2 = f"{addr_bytes[1]:02X}"
            addr3 = f"{addr_bytes[2]:02X}"
            addr4 = f"{addr_bytes[3]:02X}"
            full_addr = prefix + addr1 + addr2 + addr3 + addr4

            val_bytes = file_bytes[offset + 10:offset + 12]
            val1 = f"{val_bytes[0]:02X}"
            val2 = f"{val_bytes[1]:02X}"
            raw_code_string = f"{full_addr} {val1}{val2}"

            offset += 12
            name_length_byte = file_bytes[offset]
            name_length = max(1, name_length_byte - 1)
            offset += 1

            if offset + name_length + 5 > len(file_bytes):
                break

            raw_desc = file_bytes[offset:offset + name_length].split(b'\x00')[0].decode('ascii', errors='ignore')
            offset += name_length + 5

            intermediate_list.append({"desc": raw_desc, "code": raw_code_string})

        for item in intermediate_list:
            clean_codes = parse_func(item["code"])
            if not clean_codes:
                continue
            final_title = item["desc"].replace("'", "").strip()
            if not final_title:
                final_title = "Unassigned Code Block"
            self.add_cheat_to_database(final_title, clean_codes)

    # --- NES Game Genie Core Translators ---
    def convert_unmap_nes_char(self, c):
        cu = c.upper()
        mapping = {'A':0, 'P':1, 'Z':2, 'L':3, 'G':4, 'I':5, 'T':6, 'Y':7,
                   'E':8, 'O':9, 'X':10, 'U':11, 'K':12, 'S':13, 'V':14, 'N':15}
        return mapping.get(cu, 0)

    def convert_map_nes_char(self, v):
        mapping = {0:'A', 1:'P', 2:'Z', 3:'L', 4:'G', 5:'I', 6:'T', 7:'Y',
                   8:'E', 9:'O', 10:'X', 11:'U', 12:'K', 13:'S', 14:'V', 15:'N'}
        return mapping.get(v, '?')

    def invoke_game_genie_decode_nes(self, gg):
        gg = gg.strip().upper()
        if len(gg) not in (6, 8):
            return None
        data = [self.convert_unmap_nes_char(c) for c in gg]
        
        address = 0x8000
        address |= (data[1] & 8) << 4
        address |= (data[2] & 7) << 4
        address |= (data[3] & 7) << 12
        address |= (data[3] & 8) << 0
        address |= (data[4] & 7) << 0
        address |= (data[4] & 8) << 8
        address |= (data[5] & 7) << 8
        
        have_check = (len(gg) == 8)
        value = 0
        check = 0
        
        if have_check:
            value |= (data[0] & 7) << 0
            value |= (data[0] & 8) << 4
            value |= (data[1] & 7) << 4
            value |= (data[7] & 8) << 0
            
            check |= (data[5] & 8) << 0
            check |= (data[6] & 7) << 0
            check |= (data[6] & 8) << 4
            check |= (data[7] & 7) << 4
            return f"{address:04X}:{value:02X}:{check:02X}"
        else:
            value |= (data[0] & 7) << 0
            value |= (data[0] & 8) << 4
            value |= (data[1] & 7) << 4
            value |= (data[5] & 8) << 0
            return f"{address:04X}:{value:02X}"

    def invoke_game_genie_encode_nes(self, raw):
        parts = raw.split(':')
        if len(parts) < 2:
            return None
        try:
            address = int(parts[0], 16)
            value = int(parts[1], 16)
            check = 0
            have_check = False
            if len(parts) == 3:
                check = int(parts[2], 16)
                have_check = True
        except ValueError:
            return None

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
        return "".join([self.convert_map_nes_char(data[i]) for i in range(length)])

    # --- Structural Registration Matrix ---
    def _register_modules(self):
        # 1. Sega Saturn
        def saturn_parse(text):
            clean = re.sub(r'(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', r'\1\3', text)
            clean = re.sub(r'[:\+]', ' ', clean)
            return self.invoke_universal_regex_parser(clean, "AddressAndValue", lambda m: f"{m.group(1).upper()} {m.group(2).upper()}")
        
        def saturn_import(fp, pf, p_cb):
            sniff = ""
            if os.path.exists(fp):
                with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                    sniff = " ".join([f.readline() for _ in range(3)]).strip()
            if re.match(r'^cheats\s*=', sniff, re.I) or re.match(r'^cheat\d+_', sniff, re.I):
                self.import_retroarch_cht_engine(fp, pf, p_cb)
            else:
                self.import_kronos_yct_engine(fp, pf)

        self.input_modules["Sega Saturn"] = {"filter": "Saturn Cheat Files (*.yct)", "parse": saturn_parse, "import": saturn_import}

        def kronos_export(fp):
            if os.path.exists(fp):
                os.remove(fp)
            total_flat = 0
            for key in self.cheat_database.keys():
                for code_item in self.cheat_database[key].codes:
                    if re.match(r'^[Dd13][0-9A-Fa-f]{7}', code_item):
                        total_flat += 1

            with open(fp, 'wb') as f:
                f.write(bytes([0x59, 0x43, 0x48, 0x54, 0x00, 0x00, 0x00]))
                f.write(bytes([min(total_flat, 255)]))
                
                for desc in self.cheat_database.keys():
                    cnam = re.sub(r'[^\x20-\x7E]', '', desc)[:255]
                    chdg_count = len(cnam) + 1
                    cnam_bytes = cnam.encode('ascii', errors='ignore')

                    for code_item in self.cheat_database[desc].codes:
                        parts = code_item.split()
                        if len(parts) < 2:
                            continue
                        part1 = parts[0].upper().ljust(8, '0')[:8]
                        part2 = parts[1].upper().ljust(4, '0')[:4]
                        ctyp = part1[0]
                        if ctyp not in ("D", "1", "3"):
                            continue
                        type_str = "01" if ctyp == "D" else ("02" if ctyp == "3" else "03")
                        
                        hex_string = "000000" + type_str + "0" + part1[1:8] + "0000" + part2
                        chunk = bytes.fromhex(hex_string)
                        f.write(chunk)
                        f.write(bytes([chdg_count]))
                        f.write(cnam_bytes)
                        f.write(bytes([0x00, 0x00, 0x00, 0x00, 0x00]))

        self.output_modules["Kronos (.yct)"] = {"filter": "Kronos Cheat Files (*.yct)", "export": kronos_export}

        # 2. Game Boy Advance / GBA
        def gba_parse(text):
            clean = re.sub(r'(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', r'\1\3', text)
            clean = re.sub(r'[:\+]', ' ', clean)
            return self.invoke_universal_regex_parser(clean, "AddressAndValue", lambda m: f"{m.group(1).upper()} {m.group(2).upper()}")

        def gba_import(fp, pf, p_cb):
            sniff = ""
            if os.path.exists(fp):
                with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                    sniff = " ".join([f.readline() for _ in range(3)]).strip()
            if re.match(r'^cheats\s*=', sniff, re.I) or re.match(r'^cheat\d+_', sniff, re.I):
                self.import_retroarch_cht_engine(fp, pf, p_cb)
            elif '<?xml' in sniff and '<cheats>' in sniff:
                self.import_myboy_cht_engine(fp, pf)
            else:
                if os.path.exists(fp) and os.path.getsize(fp) >= 12:
                    with open(fp, 'rb') as f:
                        header = f.read(12)
                    hex_sig = " ".join([f"{b:02X}" for b in header])
                    if re.match(r'^01 00 00 00 (01|00) 00 00 00 [0-9A-Fa-f]{2} 00 00 00', hex_sig):
                        self.import_vba_clt_engine(fp, pf)
                    else:
                        raise Exception("Unknown binary signature template mismatch.")
                else:
                    raise Exception("File bounds truncated below headers.")

        self.input_modules["Game Boy Advance / GBA"] = {"filter": "GBA Cheat Files (*.cht *.clt)", "parse": gba_parse, "import": gba_import}

        def vba_export(fp):
            if os.path.exists(fp):
                os.remove(fp)
            mask_map = {'0':0xFF, '1':0x70, '2':0x21, '3':0x00, '4':0x09, '5':0x24, '6':0x0B, '7':0x08, '8':0x01, '9':0xFF, 'A':0x0A, 'B':0x23, 'C':0x22, 'D':0x07, 'E':0x20, 'F':0x32}
            
            total_flattened = sum(len(self.cheat_database[k].codes) for k in self.cheat_database.keys())
            
            with open(fp, 'wb') as f:
                f.write(struct.pack('<III', 1, 1, total_flattened))
                
                data_lines_remaining = 0
                is_slide_next_line = False

                for desc in self.cheat_database.keys():
                    safe_desc = re.sub(r'[^\x20-\x7E]', '', desc).ljust(32, '\x00')[:32].encode('ascii')
                    
                    for code_item in self.cheat_database[desc].codes:
                        parts = code_item.split()
                        if len(parts) < 2:
                            continue
                        part1 = parts[0].upper().ljust(8, '0')[:8]
                        part2 = parts[1].upper().ljust(4, '0')[:4]
                        ctyp = part1[0]

                        cd8 = int(part1, 16)
                        cd8z = int("0" + part1[1:], 16)
                        cd4 = int(part2, 16)

                        is_multiline_override = False
                        if data_lines_remaining > 0:
                            is_multiline_override = True
                            data_lines_remaining -= 1
                        elif is_slide_next_line:
                            is_multiline_override = True
                            is_slide_next_line = False

                        mask_val = 0xFF if is_multiline_override else mask_map.get(ctyp, 0x00)
                        if mask_val == 0xFF:
                            cd8z = cd8

                        code_str_bytes = code_item.ljust(20, '\x00')[:20].encode('ascii')

                        f.write(bytes([0x00, 0x02, 0x00, 0x00]))
                        if is_multiline_override or ctyp in ('0', '9'):
                            f.write(bytes([0xFF, 0xFF, 0xFF, 0xFF]))
                        else:
                            f.write(bytes([mask_val, 0x00, 0x00, 0x00]))
                        
                        f.write(struct.pack('<IIIIH', 0, 0, cd8, cd8z, cd4))
                        f.write(bytes([0x00] * 6))
                        f.write(code_str_bytes)
                        f.write(safe_desc)

                        if not is_multiline_override:
                            if ctyp == '5':
                                hw_count = int(part2, 16)
                                data_lines_remaining = int(((hw_count - 1 & 0xFFFF) // 3) + 1)
                            elif ctyp == '4':
                                is_slide_next_line = True

        self.output_modules["VBA-M (.clt)"] = {"filter": "VBA Cheat Files (*.clt)", "export": vba_export}

        # 3. Super Nintendo / SNES
        def snes_parse(text):
            return self.invoke_universal_regex_parser(text, "SnesCombined", lambda m: m.group(0).upper().replace("=", ""))
            
        def snes_import(fp, pf, p_cb):
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
            raw_cheats = []
            current = None
            for line in lines:
                m_name = re.match(r'^\s*name:\s*(.*)', line, re.I)
                if m_name:
                    desc = m_name.group(1).strip()
                    if not desc:
                        desc = "Unassigned Code Block"
                    current = {"desc": desc, "lines": []}
                    raw_cheats.append(current)
                elif re.match(r'^\s*code:\s*(.*)', line, re.I):
                    if current is not None:
                        current["lines"].append(re.match(r'^\s*code:\s*(.*)', line, re.I).group(1).strip())

            for block in raw_cheats:
                if not block["lines"]:
                    continue
                parsed_codes = []
                corrupt = False
                for line in block["lines"]:
                    res = pf(line)
                    if not res:
                        corrupt = True
                        break
                    parsed_codes.extend(res)
                if not corrupt and len(parsed_codes) == len(block["lines"]):
                    self.add_cheat_to_database(block["desc"], parsed_codes)
                else:
                    self.write_log(f"SNES Import: Discarded block '{block['desc']}' due to anomalies.", "WARN")

        self.input_modules["Super Nintendo / SNES"] = {"filter": "SNES Cheat Files (*.cht)", "parse": snes_parse, "import": snes_import}

        def snes_export(fp):
            with open(fp, 'w', encoding='utf-8') as f:
                for desc in self.cheat_database.keys():
                    for code_item in self.cheat_database[desc].codes:
                        out = code_item
                        if len(out) == 8 and "-" not in out:
                            out = out[0:6] + "=" + out[6:8]
                        f.write(f"cheat\n  name: {desc}\n  code: {out}\n\n")

        self.output_modules["Snes9x (.cht)"] = {"filter": "Snes9x Cheat Files (*.cht)", "export": snes_export}

        # 4. Sega Master System / SMS
        def sms_parse(text):
            clean = re.sub(r'(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', r'\1\3', text)
            return self.invoke_universal_regex_parser(clean, "TripleGroupHyphen")

        def sms_import(fp, pf, p_cb):
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    trimmed = line.strip()
                    if not trimmed:
                        continue
                    m = re.match(r'^([0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3})\s+(.*)', trimmed)
                    if m:
                        raw_code = m.group(1).strip()
                        desc = m.group(2).replace("'", "").strip()
                        if not desc:
                            desc = "Unassigned Code Block"
                        clean = pf(raw_code)
                        if clean:
                            self.add_cheat_to_database(desc, clean)

        self.input_modules["Sega Master System / SMS"] = {"filter": "Master System Cheats (*.pat)", "parse": sms_parse, "import": sms_import}

        def md_emu_export(fp):
            with open(fp, 'w', encoding='utf-8') as f:
                for desc in self.cheat_database.keys():
                    for code_item in self.cheat_database[desc].codes:
                        f.write(f"{code_item}\t{desc}\n")

        self.output_modules["md.emu SMS (.pat)"] = {"filter": "md.emu Cheat Files (*.pat)", "export": md_emu_export}

        # 5. Sony PlayStation / PSX (PCSXR)
        def psx_parse(text):
            clean = re.sub(r'(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', r'\1\3', text)
            clean = re.sub(r'[:\+]', ' ', clean)
            return self.invoke_universal_regex_parser(clean, "AddressAndValue", lambda m: f"{m.group(1).upper()} {m.group(2).upper()}")

        def pcsxr_import(fp, pf, p_cb):
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
            blocks = []
            current_hdr = "Unassigned Code Block"
            current_codes = []
            has_orphans = False

            for line in lines:
                trimmed = line.strip()
                if not trimmed:
                    continue
                if trimmed.startswith("[") and trimmed.endswith("]"):
                    if not current_codes and current_hdr != "Unassigned Code Block":
                        has_orphans = True
                    if current_codes:
                        blocks.append({"hdr": current_hdr, "codes": current_codes})
                        current_codes = []
                    extracted = trimmed[1:-1].replace("\\", ", ").replace("'", "").strip()
                    extracted = re.sub(r'^\*\s*', '', extracted)
                    current_hdr = extracted if extracted else "Unassigned Code Block"
                else:
                    current_codes.append(trimmed)
            if current_codes:
                blocks.append({"hdr": current_hdr, "codes": current_codes})
            elif current_hdr != "Unassigned Code Block":
                has_orphans = True

            merge_categories = False
            if has_orphans and p_cb:
                merge_categories = p_cb("Cheat descriptions found without matching codes.\n\nTreat empty labels as parent categories?")

            cat_header = "Unassigned Code Block"
            for b in blocks:
                if merge_categories and not b["codes"]:
                    cat_header = b["hdr"]
                    continue
                valid = []
                corrupt = False
                for c_line in b["codes"]:
                    c_res = pf(c_line)
                    if not c_res:
                        corrupt = True
                        break
                    valid.extend(c_res)
                if corrupt:
                    self.write_log(f"PSX Import: Dropped block '{b['hdr']}' due to errors.", "WARN")
                    continue
                final_title = f"{cat_header} - {b['hdr']}" if (merge_categories and cat_header != "Unassigned Code Block") else b["hdr"]
                self.add_cheat_to_database(final_title, valid)

        self.input_modules["Sony PlayStation / PSX (PCSXR)"] = {"filter": "PCSXR Cheat Files (*.cht)", "parse": psx_parse, "import": pcsxr_import}

        def pcsxr_export(fp):
            with open(fp, 'w', encoding='utf-8') as f:
                for desc in self.cheat_database.keys():
                    if not self.cheat_database[desc].codes:
                        continue
                    f.write(f"[{desc}]\n")
                    for c in self.cheat_database[desc].codes:
                        f.write(f"{c}\n")

        self.output_modules["PCSXR (.cht)"] = {"filter": "PCSXR Cheat Files (*.cht)", "export": pcsxr_export}

        # 6. Sony PlayStation / PSX (ePSXe)
        def epsxe_import(fp, pf, p_cb):
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
            blocks = []
            current_hdr = "Unassigned Code Block"
            current_codes = []
            has_orphans = False

            for line in lines:
                trimmed = line.strip()
                if not trimmed:
                    continue
                if trimmed.startswith("#"):
                    if not current_codes and current_hdr != "Unassigned Code Block":
                        has_orphans = True
                    if current_codes:
                        blocks.append({"hdr": current_hdr, "codes": current_codes})
                        current_codes = []
                    current_hdr = trimmed[1:].replace("'", "").strip()
                    if not current_hdr:
                        current_hdr = "Unassigned Code Block"
                else:
                    current_codes.append(trimmed)
            if current_codes:
                blocks.append({"hdr": current_hdr, "codes": current_codes})
            elif current_hdr != "Unassigned Code Block":
                has_orphans = True

            merge_categories = False
            if has_orphans and p_cb:
                merge_categories = p_cb("Cheat descriptions found without matching codes.\n\nTreat empty labels as parent categories?")

            cat_header = "Unassigned Code Block"
            for b in blocks:
                if merge_categories and not b["codes"]:
                    cat_header = b["hdr"]
                    continue
                valid = []
                corrupt = False
                for c_line in b["codes"]:
                    c_res = pf(c_line)
                    if not c_res:
                        corrupt = True
                        break
                    valid.extend(c_res)
                if corrupt:
                    self.write_log(f"PSX Import: Dropped block '{b['hdr']}' due to errors.", "WARN")
                    continue
                final_title = f"{cat_header} - {b['hdr']}" if (merge_categories and cat_header != "Unassigned Code Block") else b["hdr"]
                self.add_cheat_to_database(final_title, valid)

        self.input_modules["Sony PlayStation / PSX (ePSXe)"] = {"filter": "ePSXe Cheat Files (*.txt)", "parse": psx_parse, "import": epsxe_import}

        def epsxe_export(fp):
            with open(fp, 'w', encoding='utf-8') as f:
                for desc in self.cheat_database.keys():
                    if not self.cheat_database[desc].codes:
                        continue
                    f.write(f"#{desc}\n")
                    for c in self.cheat_database[desc].codes:
                        f.write(f"{c}\n")

        self.output_modules["ePSXe (.txt)"] = {"filter": "ePSXe Cheat Files (*.txt)", "export": epsxe_export}

        # 7. Game Boy / GBC
        def gbc_parse(text):
            return self.invoke_universal_regex_parser(text, "GbcCombined")

        def gbc_import(fp, pf, p_cb):
            with open(fp, 'rb') as f:
                fb = f.read()
            if len(fb) < 4:
                return
            total_records = fb[1]
            offset = 3
            for _ in range(total_records):
                if offset + 3 > len(fb):
                    break
                # skip status
                desc_len = fb[offset + 1]
                offset += 3
                if offset + desc_len > len(fb):
                    break
                raw_desc = fb[offset:offset+desc_len].decode('ascii', errors='ignore')
                offset += desc_len
                
                if offset + 1 > len(fb):
                    break
                prefix_byte = fb[offset]
                code_len = 11 if prefix_byte == 0x0B else 8
                offset += 1
                
                if offset + code_len > len(fb):
                    break
                raw_code = fb[offset:offset+code_len].decode('ascii', errors='ignore')
                offset += code_len

                clean = pf(raw_code)
                if clean:
                    final_title = raw_desc.replace("'", "").strip()
                    if not final_title:
                        final_title = "Unassigned Code Block"
                    self.add_cheat_to_database(final_title, clean)

        self.input_modules["Game Boy / GBC"] = {"filter": "GBC Cheat Files (*.gbcht)", "parse": gbc_parse, "import": gbc_import}

        def gbc_export(fp):
            total = sum(len(self.cheat_database[d].codes) for d in self.cheat_database.keys())
            with open(fp, 'wb') as f:
                f.write(bytes([0x00, min(total, 255), 0x00]))
                processed = 0
                for desc in self.cheat_database.keys():
                    if processed >= 255:
                        break
                    safe_desc = re.sub(r'[^\x20-\x7E]', '', desc).encode('ascii', errors='ignore')
                    for code in self.cheat_database[desc].codes:
                        if processed >= 255:
                            break
                        prefix = 0x0B if "-" in code else 0x08
                        code_bytes = code.encode('ascii', errors='ignore')
                        f.write(bytes([0x00, len(safe_desc), 0x00]))
                        f.write(safe_desc)
                        f.write(bytes([prefix]))
                        f.write(code_bytes)
                        processed += 1

        self.output_modules["GBC.emu (.gbcht)"] = {"filter": "GBC Cheat Files (*.gbcht)", "export": gbc_export}

        # 8. Sega Mega Drive / MD
        def md_parse(text):
            clean = re.sub(r'(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', r'\1\3', text)
            return self.invoke_universal_regex_parser(clean, "SmsMdExtended")

        def md_import(fp, pf, p_cb):
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    trimmed = line.strip()
                    if not trimmed:
                        continue
                    m = re.match(r'^(?P<code>(?:[0-9A-Fa-f]{6}:[0-9A-Fa-f]{4})|(?:[0-9A-Z]{4}-[0-9A-Z]{4}))\s+(?P<desc>.*)', trimmed)
                    if m:
                        raw_code = m.group('code').strip()
                        desc = m.group('desc').replace("'", "").strip()
                        if not desc:
                            desc = "Unassigned Code Block"
                        clean = pf(raw_code)
                        if clean:
                            self.add_cheat_to_database(desc, clean)

        self.input_modules["Sega Mega Drive / MD"] = {"filter": "MD Cheats (*.pat)", "parse": md_parse, "import": md_import}
        self.output_modules["md.emu MD (.pat)"] = {"filter": "md.emu Cheat Files (*.pat)", "export": md_emu_export}

        # 9. Nintendo DS
        def nds_parse(text):
            clean = re.sub(r'(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', r'\1\3', text)
            clean = re.sub(r'[:\+]', ' ', clean)
            return self.invoke_universal_regex_parser(clean, "AddressAndValue", lambda m: f"{m.group(1).upper()} {m.group(2).upper()}")

        def nds_import(fp, pf, p_cb):
            with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
            current_desc = "Unassigned Code Block"
            current_lines = []

            def commit_ds_block(d, l):
                if not l:
                    return
                valid = []
                for line in l:
                    res = pf(line)
                    if not res:
                        self.write_log(f"NDS Import: Corrupted line in '{d}'. Dropping block.", "WARN")
                        return
                    valid.extend(res)
                self.add_cheat_to_database(d, valid)

            for line in lines:
                trimmed = line.strip()
                if not trimmed:
                    continue
                m = re.match(r'^CODE\s+\d+\s*(.*)', trimmed, re.I)
                if m:
                    commit_ds_block(current_desc, current_lines)
                    current_desc = m.group(1).strip()
                    current_lines = []
                    continue
                if not re.match(r'^CAT\s+', trimmed, re.I):
                    current_lines.append(trimmed)
            commit_ds_block(current_desc, current_lines)

        self.input_modules["Nintendo DS"] = {"filter": "NDS Cheat Files (*.mch)", "parse": nds_parse, "import": nds_import}

        def nds_export(fp):
            with open(fp, 'w', encoding='utf-8') as f:
                f.write("CAT Cheats\n")
                for desc in self.cheat_database.keys():
                    f.write(f"CODE 0 {desc}\n")
                    for c in self.cheat_database[desc].codes:
                        f.write(f"{c}\n")

        self.output_modules["melonDS (.mch)"] = {"filter": "melonDS Cheat Files (*.mch)", "export": nds_export}

        # 10. Nintendo NES
        def nes_parse(text):
            def form(m):
                raw_code = m.group(0).upper()
                if re.match(r'^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$', raw_code):
                    parts = raw_code.split(':')
                    if int(parts[0], 16) >= 0x8000:
                        encoded = self.invoke_game_genie_encode_nes(raw_code)
                        if encoded:
                            return encoded
                return raw_code
            return self.invoke_universal_regex_parser(text, "NesCombined", form)

        def nes_import(fp, pf, p_cb):
            sniff = ""
            if os.path.exists(fp):
                with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                    sniff = " ".join([f.readline() for _ in range(3)]).strip()
            if re.match(r'^cheats\s*=', sniff, re.I) or re.match(r'^cheat\d+_', sniff, re.I):
                self.import_retroarch_cht_engine(fp, pf, p_cb)
            else:
                with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        tokens = [t.strip() for t in line.split(':') if t.strip()]
                        if len(tokens) >= 2:
                            desc = tokens[-1].replace("'", "").strip()
                            if not desc:
                                desc = "Unassigned Code Block"
                            code_parts = []
                            for token in tokens[:-1]:
                                token_clean = token.upper()
                                if token_clean in ('SC', 'C', 'S'):
                                    continue
                                code_parts.append(token_clean)
                            code_str = ":".join(code_parts)
                            if code_str:
                                proc = pf(code_str)
                                if proc:
                                    self.add_cheat_to_database(desc, proc)

        self.input_modules["Nintendo NES"] = {"filter": "NES Cheat Files (*.cht)", "parse": nes_parse, "import": nes_import}

        def nes_export(fp):
            with open(fp, 'w', encoding='utf-8') as f:
                for desc in self.cheat_database.keys():
                    clean_desc = desc.strip()
                    for code_item in self.cheat_database[desc].codes:
                        sub_codes = [sc.strip() for sc in code_item.split('+') if sc.strip()]
                        for sub_code in sub_codes:
                            raw_code = sub_code.lstrip(':')
                            if len(raw_code) == 9 and re.match(r'^[A-Z]{9}$', raw_code):
                                raw_code = raw_code[1:]
                            if len(raw_code) in (6, 8) and re.match(r'^[A-Z]{6}$|^[A-Z]{8}$', raw_code):
                                decoded = self.invoke_game_genie_decode_nes(raw_code)
                                if decoded:
                                    raw_code = decoded
                            m = re.match(r'^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$', raw_code)
                            if m:
                                addr_str, val_str, cmp_str = m.group(1), m.group(2), m.group(3)
                                addr_int = int(addr_str, 16)
                                is_high = addr_int >= 0x8000
                                has_comp = bool(cmp_str)
                                if is_high:
                                    prefix = "SC:" if has_comp else "S:"
                                else:
                                    prefix = "C:" if has_comp else ":"
                                body = f"{addr_str}:{val_str}:{cmp_str}" if has_comp else f"{addr_str}:{val_str}"
                                f.write(f"{prefix}{body}:{clean_desc}\n")
                            else:
                                fallback = raw_code if raw_code.startswith(':') else f":{raw_code}"
                                f.write(f"{fallback}:{clean_desc}\n")

        self.output_modules["nes.emu (.cht)"] = {"filter": "nes.emu Cheat Files (*.cht)", "export": nes_export}

        # 11. Global RetroArch
        def ra_parse(text, target_module=None):
            if not target_module or target_module not in self.input_modules:
                return None
            return self.input_modules[target_module]["parse"](text)

        self.input_modules["RetroArch (Global)"] = {
            "filter": "RetroArch Cheat Files (*.cht)",
            "parse": ra_parse,
            "import": lambda fp, pf, p_cb: self.import_retroarch_cht_engine(fp, pf, p_cb)
        }

        def ra_export(fp):
            with open(fp, 'w', encoding='utf-8') as f:
                f.write(f"cheats = {len(self.cheat_database)}\n\n")
                for idx, desc in enumerate(self.cheat_database.keys()):
                    joined = "+".join(self.cheat_database[desc].codes)
                    f.write(f'cheat{idx}_desc = "{desc}"\n')
                    f.write(f'cheat{idx}_code = "{joined}"\n')
                    f.write(f'cheat{idx}_enable = false\n\n')

        self.output_modules["RetroArch (.cht)"] = {"filter": "RetroArch Cheat Files (*.cht)", "export": ra_export}
