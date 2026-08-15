#include <QtWidgets>
#include <QDomDocument>
#include <QRegularExpression>
#include <QRegularExpressionMatchIterator>
#include <functional>
#include <optional>
#include <variant>

// Multi-Emulator Cheat Reformatter - Qt 6 port
// Monolithic port of the supplied Avalonia / PySide6 program.

struct CheatEntry {
    QString baseDesc;
    QString format;
    QStringList codes;
    double health = 1.0;
    bool isHeading = false;
    int accumulatedRawLength = 0;
    int accumulatedMatchLength = 0;
};

struct ParseResult {
    QString code;
    QString format;
    int matchLength = 0;
};

struct ParsedCodes {
    QStringList codes;
    int rawLength = 0;
    int matchLength = 0;
};

struct ParseOutput {
    bool valid = false;
    QStringList codes;
    int rawLength = 0;
    int matchLength = 0;
};

struct InputModule {
    QString name;
    QString filter;
    std::function<ParseOutput(const QString&, const QString&)> parse;
    std::function<void(const QString&, const QString&, const std::function<ParseOutput(const QString&, const QString&)>&)> import;
};

struct OutputModule {
    QString name;
    QString filter;
    std::function<void(const QString&)> exportFunc;
};

struct Pattern {
    QString key;
    QRegularExpression regex;
};

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    MainWindow() {
        setWindowTitle("Multi-Emulator Cheat Reformatter");
        resize(FormWidth, FormHeight);
        setMinimumSize(FormMinWidth, FormMinHeight);

        buildPatternLibrary();
        registerModules();
        buildUi();
        wireEvents();
        updateOutputModuleChoices();
        if (cmbInputModule->count() > 0) cmbInputModule->setCurrentIndex(0);
        updateOutputModuleChoices();
        writeLog("Application initialized.");
    }

private:
    // -------------------------------------------------------------------------
    // GLOBAL DATA / STATE
    // -------------------------------------------------------------------------
    QVector<QPair<QString, CheatEntry>> cheatDatabase;
    QHash<QString, InputModule> inputModules;
    QHash<QString, OutputModule> outputModules;
    // QHash is retained for fast lookup; these lists preserve the PySide6 insertion order.
    QStringList inputModuleOrder;
    QStringList outputModuleOrder;

    QHash<QString, QString> systemKeyMap{
        {"Nintendo NES", "NES"},
        {"Super Nintendo / SNES", "SNES"},
        {"Game Boy / GBC", "GBC"},
        {"Game Boy Advance / GBA", "GBA"},
        {"Nintendo DS", "NDS"},
        {"Sega Master System / SMS", "SMS"},
        {"Sega Mega Drive / MD", "MD"},
        {"Sega Saturn", "Saturn"},
        {"Sony PlayStation / PSX (PCSXR)", "PCSXR"},
        {"Sony PlayStation / PSX (ePSXe)", "ePSXe"}
    };

    QHash<QString, QVector<Pattern>> systemCodePatterns;
    QHash<QString, QString> moduleOutputMap{
        {"Game Boy / GBC", "GBC.emu (.gbcht)"},
        {"Game Boy Advance / GBA", "VBA-M (.clt)"},
        {"Super Nintendo / SNES", "Snes9x (.cht)"},
        {"Nintendo DS", "melonDS (.mch)"},
        {"Nintendo NES", "nes.emu (.cht)"},
        {"Sega Master System / SMS", "md.emu SMS (.pat)"},
        {"Sega Mega Drive / MD", "md.emu MD (.pat)"},
        {"Sega Saturn", "Kronos (.yct)"},
        {"Sony PlayStation / PSX (PCSXR)", "PCSXR (.cht)"},
        {"Sony PlayStation / PSX (ePSXe)", "ePSXe (.txt)"}
    };

    bool isDirty = false;
    int lastSelectedIndex = -1;
    bool suppressEvents = false;
    QString lastDirectory = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    const double healthThreshold = 0.80;

    // UI constants matching chtrfmtr.py
    static constexpr int FormWidth = 820;
    static constexpr int FormHeight = 585;
    static constexpr int FormMinWidth = 700;
    static constexpr int FormMinHeight = 500;
    static constexpr int ControlHeight = 29;
    static constexpr int ComboWidth = 214;
    static constexpr int ActionBtnWidth = 35;
    static constexpr int AddBtnWidth = 48;
    static constexpr int SaveBtnWidth = 420;

    QComboBox *cmbInputModule = nullptr;
    QComboBox *cmbTargetRegex = nullptr;
    QComboBox *cmbOutputModule = nullptr;
    QPushButton *btnImport = nullptr;
    QPushButton *btnExport = nullptr;
    QPushButton *btnNewGroup = nullptr;
    QPushButton *btnMoveUp = nullptr;
    QPushButton *btnMoveDown = nullptr;
    QPushButton *btnDeleteGroup = nullptr;
    QPushButton *btnSaveGroup = nullptr;
    QLineEdit *txtNewGroup = nullptr;
    QListWidget *lstCheats = nullptr;
    QPlainTextEdit *txtEditor = nullptr;
    QPlainTextEdit *txtStatusLog = nullptr;
    QLabel *lblTargetRegex = nullptr;
    QLabel *lblInput = nullptr;
    QLabel *lblOutput = nullptr;

    // -------------------------------------------------------------------------
    // REGEX / PARSING
    // -------------------------------------------------------------------------
    QRegularExpression R(const QString &p) const {
        return QRegularExpression(p, QRegularExpression::CaseInsensitiveOption);
    }

    void buildPatternLibrary() {
        systemCodePatterns["NES"] = {
            {"68gg", R(R"((?<![0-9A-Z])([AEGIKLN-PS-VX-Z]{6}|[AEGIKLN-PS-VX-Z]{8})(?![0-9A-Z]))")},
            {"422hex", R(R"(((?<![0-9A-F])[0-9A-F]{4}([\p{P}\p{S}\p{Z}][0-9A-F]{2}){1,2}(?![0-9A-F])))")}
        };
        systemCodePatterns["SNES"] = {
            {"44hex", R(R"(((?<![0-9A-F])[0-9A-F]{4}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F])))")},
            {"8hex", R(R"(((?<![0-9A-F])[0-9A-F]{8}(?![0-9A-F])))")}
        };
        systemCodePatterns["GBC"] = {
            {"8hex", R(R"(((?<![0-9A-F])[0-9A-F]{8}(?![0-9A-F])))")},
            {"333gg", R(R"(((?<![0-9A-F])[0-9A-F]{3}([\p{P}\p{S}\p{Z}][0-9A-F]{3}){2}(?![0-9A-F])))")}
        };
        systemCodePatterns["GBA"] = {
            {"84hex", R(R"(((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F])))")}
        };
        systemCodePatterns["NDS"] = {
            {"88hex", R(R"(((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{8}(?![0-9A-F])))")}
        };
        systemCodePatterns["SMS"] = {
            {"333gg", R(R"(((?<![0-9A-F])[0-9A-F]{3}([\p{P}\p{S}\p{Z}][0-9A-F]{3}){2}(?![0-9A-F])))")}
        };
        systemCodePatterns["MD"] = {
            {"64hex", R(R"(((?<![0-9A-F])[0-9A-F]{6}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F])))")},
            {"44hex", R(R"(((?<![0-9A-F])[0-9A-F]{4}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F])))")}
        };
        systemCodePatterns["Saturn"] = {
            {"84hex", R(R"(((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F])))")}
        };
        systemCodePatterns["ePSXe"] = {
            {"848hex", R(R"(((?<![0-9A-F])[0-9A-F]{8})[\p{P}\p{S}\p{Z}]([0-9A-F]{4,8}(?![0-9A-F])))")}
        };
        systemCodePatterns["PCSXR"] = systemCodePatterns["ePSXe"];
    }

    QString systemKey(const QString &profile) const { return systemKeyMap.value(profile, profile); }

    std::optional<ParseResult> invokeSystemParser(const QString &systemName, const QString &rawLine) const {
        if (rawLine.trimmed().isEmpty() || !systemCodePatterns.contains(systemName)) return std::nullopt;
        static const QRegularExpression reLeadingTrash(R"(^[*\t\s#]+)");
        QString clean = rawLine.trimmed();
        clean.remove(reLeadingTrash);
        for (const auto &p : systemCodePatterns.value(systemName)) {
            auto m = p.regex.match(clean);
            if (m.hasMatch()) return ParseResult{m.captured(0).toUpper().trimmed(), p.key, m.capturedLength(0)};
        }
        return std::nullopt;
    }

    ParseOutput simpleParser(const QString &system, const QString &input, const QString &) const {
        auto r = invokeSystemParser(system, input);
        if (!r) return {};
        return {true, {r->code}, r->matchLength, r->matchLength};
    }

    // -------------------------------------------------------------------------
    // DATABASE
    // -------------------------------------------------------------------------
    void setEditorText(const QString &text) {
        suppressEvents = true;
        txtEditor->setPlainText(text);
        isDirty = false;
        suppressEvents = false;
    }

    int findKey(const QString &key) const {
        for (int i = 0; i < cheatDatabase.size(); ++i) if (cheatDatabase[i].first == key) return i;
        return -1;
    }

    QVector<QPair<QString, CheatEntry>> visibleEntries() const {
        QVector<QPair<QString, CheatEntry>> out;
        for (const auto &kv : cheatDatabase) if (kv.second.format != "Heading") out.push_back(kv);
        return out;
    }

    void addCheatToDatabase(const QString &description, const QStringList &codes, const QString &systemName = {},
                            const QString &formatOverride = {}, int rawLength = 0, int matchLength = 0) {
        bool isHeading = rawLength == 0 && codes.isEmpty();
        double health = rawLength > 0 ? double(matchLength) / rawLength : 1.0;
        if (!isHeading && health < healthThreshold) {
            writeLog(QString("Discarded entry group '%1' due to health failure (%2% score falls below required %3% threshold).")
                         .arg(description).arg(health * 100.0, 0, 'f', 1).arg(healthThreshold * 100.0, 0, 'f', 1), "WARN");
            return;
        }

        QHash<QString, QStringList> grouped;
        for (QString code : codes) {
            QString format = formatOverride.isEmpty() ? "Unknown" : formatOverride;
            code = code.trimmed().toUpper();
            if (formatOverride.isEmpty() && !systemName.isEmpty()) {
                auto parsed = invokeSystemParser(systemName, code);
                if (parsed) { format = parsed->format; code = parsed->code; }
            }
            grouped[format].append(code);
        }
        if (isHeading) grouped["Heading"] = {};

        for (auto it = grouped.cbegin(); it != grouped.cend(); ++it) {
            QString key = description + ":::" + it.key();
            int idx = findKey(key);
            if (idx < 0) {
                CheatEntry e;
                e.baseDesc = description; e.format = it.key(); e.codes = it.value();
                e.health = health; e.isHeading = isHeading;
                e.accumulatedRawLength = rawLength; e.accumulatedMatchLength = matchLength;
                cheatDatabase.append({key, e});
            } else {
                auto &e = cheatDatabase[idx].second;
                e.codes += it.value();
                e.accumulatedRawLength += rawLength;
                e.accumulatedMatchLength += matchLength;
                if (e.accumulatedRawLength > 0) e.health = double(e.accumulatedMatchLength) / e.accumulatedRawLength;
            }
        }
    }

    // -------------------------------------------------------------------------
    // UNIVERSAL PIPELINE
    // -------------------------------------------------------------------------
    struct Metrics { int linesProcessed = 0; int codeNamesFound = 0; int codesFound = 0; };

    bool checkLine(Metrics &metrics, const QString &line, bool isDescription, const QString &systemKey) {
        ++metrics.linesProcessed;
        if (isDescription) ++metrics.codeNamesFound;
        if (invokeSystemParser(systemKey, line)) ++metrics.codesFound;
        if (metrics.linesProcessed == 50) {
            double density = metrics.codesFound / 50.0;
            if (density < 0.04 || metrics.codeNamesFound == 0) {
                writeLog(QString("File verification failed at line 50: Density=%1% (min 4%), Names Found=%2 (min 1%).")
                             .arg(density * 100.0, 0, 'f', 1).arg(metrics.codeNamesFound), "WARN");
                QMessageBox::warning(this, "Verification Guard Warning",
                                     "File verification failed: Content density or naming structure does not match the selected Input Module schema.");
                cheatDatabase.clear();
                return false;
            }
        }
        return true;
    }

    void invokeUnifiedCheatEngine(const QStringList &lines, const QString &systemName, const QString &layoutType,
                                  const QString &nameHeaderRegex = {}, const QString &codeHeaderRegex = {},
                                  const QString &delimiter = {},
                                  const std::function<ParseOutput(const QString&, const QString&)> &parseFunc = {}) {
        if (lines.isEmpty()) return;
        QString sys = systemKey(systemName);
        Metrics metrics;
        QString rollingParentCategory = "Unassigned Code Block";
        bool hasPromptedForMerge = false, mergeCategories = false;

        if (layoutType == "1to1") {
            for (const QString &line : lines) {
                QString trimmed = line.trimmed();
                if (trimmed.isEmpty() || trimmed.startsWith('#')) continue;
                QString rawCode, rawDesc = "Unassigned Code Block";
                bool isDescription = false;
                if (!delimiter.isEmpty()) {
                    auto parts = trimmed.split(delimiter, Qt::KeepEmptyParts);
                    rawCode = parts.value(0).trimmed();
                    if (parts.size() > 1) { rawDesc = parts.mid(1).join(delimiter).replace("'", "").trimmed(); isDescription = !rawDesc.isEmpty(); }
                } else if (!nameHeaderRegex.isEmpty() && !codeHeaderRegex.isEmpty()) {
                    auto nm = QRegularExpression(nameHeaderRegex).match(trimmed);
                    if (nm.hasMatch()) { rawDesc = nm.captured(1).replace("'", "").trimmed(); isDescription = true; }
                    auto cm = QRegularExpression(codeHeaderRegex).match(trimmed);
                    if (cm.hasMatch()) rawCode = cm.captured(1).trimmed();
                } else rawCode = trimmed;

                if (!checkLine(metrics, rawCode, isDescription, sys)) return;
                auto parsed = invokeSystemParser(sys, rawCode);
                QStringList codes = parsed ? QStringList{parsed->code} : QStringList{};
                int matchLength = parsed ? parsed->matchLength : 0;
                if (matchLength == 0 && !rawCode.isEmpty()) {
                    rollingParentCategory = rawDesc;
                    addCheatToDatabase(rawDesc, {}, sys);
                    continue;
                }
                QString finalTitle = mergeCategories && rollingParentCategory != "Unassigned Code Block"
                                   ? rollingParentCategory + " - " + rawDesc : rawDesc;
                addCheatToDatabase(finalTitle, codes, sys, {}, rawCode.length(), matchLength);
            }
        } else if (layoutType == "1few") {
            QString currentHeader = "Unassigned Code Block";
            QStringList currentCodes;
            int totalRawLength = 0, totalMatchLength = 0;
            auto commitBlock = [&]() {
                if (currentCodes.isEmpty()) return;
                QString finalTitle = mergeCategories && rollingParentCategory != "Unassigned Code Block"
                                   ? rollingParentCategory + " - " + currentHeader : currentHeader;
                addCheatToDatabase(finalTitle, currentCodes, sys, {}, totalRawLength, totalMatchLength);
                currentCodes.clear();
            };
            for (const QString &line : lines) {
                QString trimmed = line.trimmed(); if (trimmed.isEmpty()) continue;
                bool isDescription = false; QString chkLine = trimmed;
                QRegularExpressionMatch nm;
                if (!nameHeaderRegex.isEmpty()) nm = QRegularExpression(nameHeaderRegex).match(trimmed);
                if (nm.hasMatch()) {
                    isDescription = true; chkLine = nm.captured(1).trimmed();
                    if (!checkLine(metrics, chkLine, true, sys)) return;
                    commitBlock();
                    currentHeader = nm.captured(1).replace("'", "").trimmed();
                    if (currentHeader.isEmpty()) currentHeader = "Unassigned Code Block";
                    rollingParentCategory = currentHeader;
                    addCheatToDatabase(currentHeader, {}, sys);
                    totalRawLength = totalMatchLength = 0;
                } else {
                    QString clean = trimmed; clean.remove(QRegularExpression(R"(^[*\t\s#]+)"));
                    if (!codeHeaderRegex.isEmpty()) {
                        auto cm = QRegularExpression(codeHeaderRegex).match(trimmed);
                        if (cm.hasMatch()) clean = cm.captured(1).trimmed();
                    }
                    chkLine = clean;
                    if (!checkLine(metrics, chkLine, isDescription, sys)) return;
                    totalRawLength += clean.length();
                    auto parsed = invokeSystemParser(sys, clean);
                    if (parsed) { currentCodes.append(parsed->code); totalMatchLength += parsed->matchLength; }
                }
            }
            commitBlock();
        } else if (layoutType == "few1") {
            if (!parseFunc || nameHeaderRegex.isEmpty() || codeHeaderRegex.isEmpty()) return;
        
            QStringList descOrder; // Preserves the exact file sequence
            QHash<QString, QString> descMap, codeMap; //[cite: 9]
            
            for (const QString &line : lines) {
                bool isDescription = false;
                QString chkLine = line;
        
                auto dm = QRegularExpression(nameHeaderRegex).match(line);
                if (dm.hasMatch()) {
                    QString key = dm.captured(1);
                    QString val = dm.captured(2).trimmed();
                    
                    descOrder.append(key);
                    descMap[key] = val;
                    isDescription = true;
                    chkLine = val;
                } else {
                    auto cm = QRegularExpression(codeHeaderRegex).match(line);
                    if (cm.hasMatch()) {
                        codeMap[cm.captured(1)] = cm.captured(2).trimmed();
                        chkLine = cm.captured(2).trimmed();
                    }
                }
                if (!checkLine(metrics, chkLine, isDescription, sys)) return;
            }
        
            // Iterate through descOrder to process entries sequentially
            for (const QString &key : std::as_const(descOrder)) {
                const QString descText = descMap.value(key);
        
                if (!codeMap.contains(key)) {
                    if (!hasPromptedForMerge) {
                        hasPromptedForMerge = true;
                        mergeCategories = QMessageBox::question(
                            this, 
                            "Universal Category Layout Manager",
                            "Merge structural parent categories into code description naming blocks?",
                            QMessageBox::Yes | QMessageBox::No
                        ) == QMessageBox::Yes;
                    }
                    rollingParentCategory = descText;
                    addCheatToDatabase(descText, {}, sys);
                    continue;
                }
        
                ParseOutput result = parseFunc(codeMap.value(key), systemName);
                if (!result.valid || result.codes.isEmpty()) continue;
        
                QString finalTitle = mergeCategories && rollingParentCategory != "Unassigned Code Block"
                                   ? rollingParentCategory + " - " + descText 
                                   : descText;
                finalTitle = finalTitle.replace("'", "").trimmed();
                if (finalTitle.isEmpty()) finalTitle = "Unassigned Code Block";
        
                addCheatToDatabase(finalTitle, result.codes, sys, {}, result.rawLength, result.matchLength);
            }
        }

        if (metrics.codeNamesFound == 0) {
            int staged = visibleEntries().size();
            if (metrics.codesFound > 0 && staged == 0) {
                writeLog(QString("File verification failed: Matching codes detected (%1), but zero valid naming blocks or cheats could be structured.").arg(metrics.codesFound), "WARN");
                QMessageBox::warning(this, "Name Extraction Failure",
                                     "File verification failed: Matching codes were detected, but no valid cheat names could be parsed under the selected module rules.");
                cheatDatabase.clear(); return;
            }
            if (staged > 0) metrics.codeNamesFound = staged;
        }
        CheatEntry meta; meta.baseDesc = "File Metrics Metadata Summary Record Instance"; meta.format = "Heading"; meta.isHeading = true;
        cheatDatabase.append({":::_METRICS:::Global", meta});
        writeLog(QString("File parsing complete. Summary Metrics -> Total Lines Processed: %1 | Unique Naming Elements Identified: %2 | Format Match Codes Found: %3")
                 .arg(metrics.linesProcessed).arg(metrics.codeNamesFound).arg(metrics.codesFound));
    }

    QStringList readAllLines(const QString &path) const {
        QFile f(path); if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) throw std::runtime_error(f.errorString().toStdString());
        QTextStream in(&f); in.setEncoding(QStringConverter::Utf8);
        QStringList lines; while (!in.atEnd()) lines << in.readLine(); return lines;
    }

    QByteArray readFileBytes(const QString &path) const {
        QFile f(path); if (!f.open(QIODevice::ReadOnly)) throw std::runtime_error(f.errorString().toStdString());
        return f.readAll();
    }

    static QString readNullTerminated(const QByteArray &b) {
        int zero = b.indexOf('\0'); return QString::fromLatin1(zero < 0 ? b : b.left(zero));
    }

    void importRetroArchChtEngine(const QString &path, const QString &profile, const std::function<ParseOutput(const QString&, const QString&)> &parse) {
        invokeUnifiedCheatEngine(readAllLines(path), profile, "few1", R"REGEX(^cheat(\d+)_desc\s*=\s*"(.*)")REGEX", R"REGEX(^cheat(\d+)_code\s*=\s*"(.*)")REGEX", {}, parse);
    }

    quint32 readLE32(const QByteArray &b, int pos) const {
        if (pos + 4 > b.size()) throw std::runtime_error("Unexpected end of binary file.");
        return quint32(quint8(b[pos])) | (quint32(quint8(b[pos+1])) << 8) | (quint32(quint8(b[pos+2])) << 16) | (quint32(quint8(b[pos+3])) << 24);
    }
    quint16 readLE16(const QByteArray &b, int pos) const { return quint16(quint8(b[pos])) | (quint16(quint8(b[pos+1])) << 8); }
    void putLE16(QDataStream &out, quint16 v) { out << v; }
    void putLE32(QDataStream &out, quint32 v) { out << v; }

    void importVbaCltEngine(const QString &path) {
        QByteArray b = readFileBytes(path); if (b.size() < 12) return;
        int total = int(readLE32(b, 8)); long long remaining = b.size() - 12; int stride = 84;
        if (total > 0 && remaining / total == 80) stride = 80;
        QStringList pre;
        for (int i = 0; i < total; ++i) {
            qint64 start = 12LL + qint64(i) * stride; if (start + stride > b.size()) break;
            int codeOffset = int(start + (stride == 80 ? 28 : 32));
            int descOffset = int(start + (stride == 80 ? 48 : 52));
            QString rawCode = readNullTerminated(b.mid(codeOffset, 20));
            QString rawDesc = readNullTerminated(b.mid(descOffset, 32));
            if (rawDesc.trimmed().isEmpty()) rawDesc = "Unassigned Code Block";
            if (!rawCode.trimmed().isEmpty()) pre << rawCode + "\t" + rawDesc;
        }
        if (!pre.isEmpty()) invokeUnifiedCheatEngine(pre, "GBA", "1to1", {}, {}, "\t");
    }

    void importMyBoyChtEngine(const QString &path) {
        QFile f(path); if (!f.open(QIODevice::ReadOnly)) throw std::runtime_error(f.errorString().toStdString());
        QDomDocument doc; QString err; int line, col;
        if (!doc.setContent(&f, true, &err, &line, &col)) throw std::runtime_error(QString("Failed parsing MyBoy XML target: %1 (line %2, column %3)").arg(err).arg(line).arg(col).toStdString());
        QStringList lines;
        const auto cheats = doc.elementsByTagName("cheat");
        for (int i = 0; i < cheats.count(); ++i) {
            QDomElement cheat = cheats.at(i).toElement(); if (cheat.attribute("type") != "cb") continue;
            QString name = cheat.attribute("name"); if (name.isEmpty()) name = cheat.firstChildElement("name").text();
            name = name.replace("'", "").trimmed(); if (name.isEmpty()) name = "Unassigned Code Block";
            lines << "[NAME] " + name;
            const auto codes = cheat.elementsByTagName("code");
            for (int j = 0; j < codes.count(); ++j) if (!codes.at(j).toElement().text().trimmed().isEmpty()) lines << codes.at(j).toElement().text().trimmed();
        }
        if (!lines.isEmpty()) invokeUnifiedCheatEngine(lines, "GBA", "1few", R"(^\[NAME\]\s*(.*))");
    }

    void importKronosYctEngine(const QString &path) {
        QByteArray b = readFileBytes(path); if (b.size() < 8 || b.left(4) != "YCHT") return;
        int pos = 7; int total = quint8(b[pos++]); QStringList pre;
        for (int i = 0; i < total; ++i) {
            if (pos + 13 > b.size()) break;
            QByteArray typeBytes = b.mid(pos, 4); pos += 4; quint8 typeByte = quint8(typeBytes[3]);
            QString prefix = typeByte == 0x02 ? "3" : (typeByte == 0x03 ? "1" : "D");
            QByteArray addr = b.mid(pos, 4); pos += 4; if (addr.size() < 4) break;
            QString fullAddr = prefix + QString::number(quint8(addr[0]) & 0x0F, 16).toUpper()
                + QString("%1%2%3").arg(quint8(addr[1]),2,16,QChar('0')).arg(quint8(addr[2]),2,16,QChar('0')).arg(quint8(addr[3]),2,16,QChar('0')).toUpper();
            pos += 2; QByteArray val = b.mid(pos, 2); pos += 2; if (val.size() < 2) break;
            QString rawCode = fullAddr + " " + QString("%1%2").arg(quint8(val[0]),2,16,QChar('0')).arg(quint8(val[1]),2,16,QChar('0')).toUpper();
            if (pos >= b.size()) break; int nameLength = qMax(1, int(quint8(b[pos++])) - 1); if (pos + nameLength + 5 > b.size()) break;
            QString desc = readNullTerminated(b.mid(pos, nameLength)).trimmed(); pos += nameLength + 5;
            if (desc.isEmpty()) desc = "Unassigned Code Block"; pre << rawCode + "\t" + desc;
        }
        if (!pre.isEmpty()) invokeUnifiedCheatEngine(pre, "Saturn", "1to1", {}, {}, "\t");
    }

    void importNesChtEngine(const QString &path, const std::function<ParseOutput(const QString&, const QString&)> &parseFunc) {
        QStringList pre;
        for (const QString &line : readAllLines(path)) {
            QString trimmed = line.trimmed(); if (trimmed.isEmpty() || trimmed.startsWith('#')) continue;
            QString active = trimmed; while (active.startsWith(':')) active.remove(0,1);
            QStringList parts = active.split(':'); if (parts.size() < 2) continue;
            int addrIndex = 0; QString prefix;
            if (parts[0] == "S" || parts[0] == "SC" || parts[0] == "C") { prefix = parts[0]; addrIndex = 1; }
            if (parts.size() - addrIndex < 2) continue;
            QString addressHex = parts[addrIndex], val1 = parts[addrIndex+1], compareValue, description;
            if (parts.size() == addrIndex + 4) { compareValue = parts[addrIndex+2]; description = parts[addrIndex+3]; }
            else if (parts.size() > addrIndex + 4) { compareValue = parts[addrIndex+2]; description = parts.mid(addrIndex+3).join(":"); }
            else if (parts.size() == addrIndex + 3) description = parts[addrIndex+2]; else description = "Unassigned Code Block";
            description = description.replace("'", "").trimmed(); if (description.isEmpty()) description = "Unassigned Code Block";
            QStringList codes;
            if (QRegularExpression(R"(^[0-9A-Fa-f]{4}$)").match(addressHex).hasMatch()) {
                bool ok=false; int addressVal = addressHex.toInt(&ok,16);
                if (ok && addressVal >= 0x8000) {
                    QString rawSegment = addressHex + ":" + val1 + (compareValue.isEmpty() ? "" : ":" + compareValue);
                    QString encoded = invokeGameGenieEncodeNES(rawSegment); if (!encoded.isEmpty()) codes << encoded;
                }
            }
            if (codes.isEmpty()) {
                QString rawSegment = prefix.isEmpty() ? addressHex + ":" + val1 : prefix + ":" + addressHex + ":" + val1;
                auto parsed = invokeSystemParser("NES", rawSegment);
                if (parsed) codes << parsed->code;
                else {
                    auto fallback = parseFunc(addressHex + " " + val1, "NES"); if (fallback.valid) codes += fallback.codes;
                }
            }
            for (const QString &code : codes) pre << code + "\t" + description;
        }
        if (!pre.isEmpty()) invokeUnifiedCheatEngine(pre, "NES", "1to1", {}, {}, "\t");
    }

    // -------------------------------------------------------------------------
    // MODULE REGISTRATION
    // -------------------------------------------------------------------------
    void registerInput(const QString &name, const QString &filter,
                       const std::function<ParseOutput(const QString&, const QString&)> &parse,
                       const std::function<void(const QString&, const QString&, const std::function<ParseOutput(const QString&, const QString&)>&)> &imp) {
        inputModules.insert(name, InputModule{name, filter, parse, imp});
        if (!inputModuleOrder.contains(name)) inputModuleOrder.append(name);
    }
    void registerOutput(const QString &name, const QString &filter, const std::function<void(const QString&)> &ex) {
        outputModules.insert(name, OutputModule{name, filter, ex});
        if (!outputModuleOrder.contains(name)) outputModuleOrder.append(name);
    }

    void registerModules() {
        auto saturnParser = [this](const QString &in, const QString &target){ return simpleParser("Saturn", in, target); };
        registerInput("Sega Saturn", "Saturn Cheat Files (*.yct)", saturnParser,
            [this](const QString &path,const QString &profile,const auto &parse){
                QString sniff = readAllLines(path).mid(0,3).join(" ").trimmed();
                if (QRegularExpression(R"((^cheats\s*=)|(^cheat\d+_))").match(sniff).hasMatch()) importRetroArchChtEngine(path, profile, parse); else importKronosYctEngine(path);
            });
        registerOutput("Kronos (.yct)", "Kronos Cheat Files (*.yct)", [this](const QString&p){exportKronos(p);});

        auto gbaParser = [this](const QString &in,const QString &target){return simpleParser("GBA",in,target);};
        registerInput("Game Boy Advance / GBA", "GBA Cheat Files (*.cht *.clt)", gbaParser,
            [this](const QString &path,const QString &profile,const auto &parse){
                QString sniff=readAllLines(path).mid(0,3).join(" ").trimmed();
                if(QRegularExpression(R"((^cheats\s*=)|(^cheat\d+_))").match(sniff).hasMatch()) importRetroArchChtEngine(path,profile,parse);
                else if(sniff.contains("<?xml",Qt::CaseInsensitive)&&sniff.contains("<cheats>",Qt::CaseInsensitive)) importMyBoyChtEngine(path);
                else { QByteArray b=readFileBytes(path); if(b.size()<12) throw std::runtime_error("File is too small to contain a valid binary cheat header."); QString sig; for(int i=0;i<12;i++){if(i)sig+='-';sig+=QString("%1").arg(quint8(b[i]),2,16,QChar('0')).toUpper();} if(!QRegularExpression(R"(^01-00-00-00-(01|00)-00-00-00-[0-9A-Fa-f]{2}-00-00-00$)").match(sig).hasMatch()) throw std::runtime_error("Unknown or invalid binary cheat file format signature."); importVbaCltEngine(path); }
            });
        registerOutput("VBA-M (.clt)", "VBA Cheat Files (*.clt)", [this](const QString&p){exportVbaClt(p);});

        auto snesParser=[this](const QString&in,const QString&t){return simpleParser("SNES",in,t);};
        registerInput("Super Nintendo / SNES", "SNES Cheat Files (*.cht)", snesParser,
            [this](const QString&path,const QString&,const auto&){QStringList pre;QString current;for(const QString&line:readAllLines(path)){QString t=line.trimmed();auto nm=QRegularExpression(R"(^name:\s*(.*))").match(t);auto cm=QRegularExpression(R"(^code:\s*(.*))").match(t);if(nm.hasMatch())current=nm.captured(1).trimmed();else if(cm.hasMatch()&&!current.isEmpty()){pre<<cm.captured(1).trimmed().replace("=","")+"\t"+current;current.clear();}}invokeUnifiedCheatEngine(pre,"SNES","1to1",{},{},"\t");});
        registerOutput("Snes9x (.cht)", "Snes9x Cheat Files (*.cht)", [this](const QString&p){exportSnes(p);});

        auto smsParser=[this](const QString&i,const QString&t){return simpleParser("SMS",i,t);};
        registerInput("Sega Master System / SMS", "Master System Cheats (*.pat)", smsParser,[this](const QString&p,const QString&,const auto&){invokeUnifiedCheatEngine(readAllLines(p),"SMS","1to1",{},{},"\t");});
        registerOutput("md.emu SMS (.pat)", "md.emu Cheat Files (*.pat)", [this](const QString&p){exportTabDelimited(p);});

        auto pcsParser=[this](const QString&i,const QString&t){return simpleParser("PCSXR",i,t);};
        registerInput("Sony PlayStation / PSX (PCSXR)", "PCSXR Cheat Files (*.cht)", pcsParser,[this](const QString&p,const QString&,const auto&){invokeUnifiedCheatEngine(readAllLines(p),"PCSXR","1few",R"(^\[(.*)\])");});
        auto epsParser=[this](const QString&i,const QString&t){return simpleParser("ePSXe",i,t);};
        registerInput("Sony PlayStation / PSX (ePSXe)", "ePSXe Cheat Files (*.txt)", epsParser,[this](const QString&p,const QString&,const auto&){invokeUnifiedCheatEngine(readAllLines(p),"ePSXe","1few",R"(^#(.*))");});
        registerOutput("PCSXR (.cht)", "PCSXR Cheat Files (*.cht)", [this](const QString&p){exportPcsxr(p);});
        registerOutput("ePSXe (.txt)", "ePSXe Cheat Files (*.txt)", [this](const QString&p){exportEpsxe(p);});

        auto gbcParser=[this](const QString&i,const QString&t){return simpleParser("GBC",i,t);};
        registerInput("Game Boy / GBC", "GBC Cheat Files (*.gbcht)", gbcParser,[this](const QString&p,const QString&,const auto&){QByteArray b=readFileBytes(p);if(b.size()<4)return;int total=quint8(b[1]),pos=3;QStringList pre;for(int i=0;i<total;i++){if(pos+3>b.size())break;pos++;int dl=quint8(b[pos++]);pos++;if(pos+dl>b.size())break;QString desc=QString::fromLatin1(b.mid(pos,dl)).trimmed();pos+=dl;if(pos+1>b.size())break;int cl=(quint8(b[pos++])==0x0b)?11:8;if(pos+cl>b.size())break;QString code=QString::fromLatin1(b.mid(pos,cl)).trimmed();pos+=cl;if(desc.isEmpty())desc="Unassigned Code Block";if(!code.isEmpty())pre<<code+"\t"+desc;}invokeUnifiedCheatEngine(pre,"GBC","1to1",{},{},"\t");});
        registerOutput("GBC.emu (.gbcht)", "GBC Cheat Files (*.gbcht)", [this](const QString&p){exportGbc(p);});

        auto mdParser=[this](const QString&i,const QString&t){return simpleParser("MD",i,t);};
        registerInput("Sega Mega Drive / MD", "MD Cheats (*.pat)", mdParser,[this](const QString&p,const QString&,const auto&){invokeUnifiedCheatEngine(readAllLines(p),"MD","1to1",{},{},"\t");});
        registerOutput("md.emu MD (.pat)", "md.emu Cheat Files (*.pat)", [this](const QString&p){exportTabDelimited(p);});

        auto ndsParser=[this](const QString&i,const QString&t){return simpleParser("NDS",i,t);};
        registerInput("Nintendo DS", "NDS Cheat Files (*.mch)", ndsParser,[this](const QString&p,const QString&,const auto&){invokeUnifiedCheatEngine(readAllLines(p),"NDS","1few",R"(^CODE\s+\d+\s*(.*))");});
        registerOutput("melonDS (.mch)", "melonDS Cheat Files (*.mch)", [this](const QString&p){exportMch(p);});

        auto nesParser=[this](const QString&input,const QString&){
            if(input.isEmpty()) return ParseOutput{}; auto res=invokeSystemParser("NES",input); if(!res)return ParseOutput{};
            auto m=QRegularExpression(R"(^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$)").match(res->code);
            if(m.hasMatch()&&m.captured(1).toInt(nullptr,16)>=0x8000){QString gg=invokeGameGenieEncodeNES(res->code);if(!gg.isEmpty())return ParseOutput{true,{gg},res->matchLength,res->matchLength};}
            return ParseOutput{true,{res->code},res->matchLength,res->matchLength};
        };
        registerInput("Nintendo NES", "NES Cheat Files (*.cht)", nesParser,[this](const QString&p,const QString&,const auto&parse){QString sniff=readAllLines(p).mid(0,3).join(" ").trimmed();if(QRegularExpression(R"((^cheats\s*=)|(^cheat\d+_))").match(sniff).hasMatch())importRetroArchChtEngine(p,"NES",parse);else importNesChtEngine(p,parse);});
        registerOutput("nes.emu (.cht)", "nes.emu Cheat Files (*.cht)", [this](const QString&p){exportNes(p);});

        auto retroParser=[this](const QString&input,const QString&target){if(target.isEmpty())return ParseOutput{};QString system=systemKey(target);if(!systemCodePatterns.contains(system))return ParseOutput{};QString sanitized=input;sanitized.replace('+',' ');QStringList results;int match=0;for(const auto&p:systemCodePatterns.value(system)){auto it=p.regex.globalMatch(sanitized);while(it.hasNext()){auto m=it.next();QString c=m.captured(0).toUpper().trimmed();if(!c.isEmpty()){results<<c;match+=m.capturedLength(0);}}}return ParseOutput{!results.isEmpty(),results,input.length(),match};};
        registerInput("RetroArch (Global)", "RetroArch Cheat Files (*.cht)", retroParser,[this](const QString&p,const QString&profile,const auto&parse){importRetroArchChtEngine(p,profile,parse);});
        registerOutput("RetroArch (.cht)", "RetroArch Cheat Files (*.cht)", [this](const QString&p){exportRetroArch(p);});
    }

    // -------------------------------------------------------------------------
    // GAME GENIE NES
    // -------------------------------------------------------------------------
    static int unmapNesChar(QChar c) { switch(c.toUpper().unicode()){case 'A':return 0;case 'P':return 1;case 'Z':return 2;case 'L':return 3;case 'G':return 4;case 'I':return 5;case 'T':return 6;case 'Y':return 7;case 'E':return 8;case 'O':return 9;case 'X':return 10;case 'U':return 11;case 'K':return 12;case 'S':return 13;case 'V':return 14;case 'N':return 15;default:return 0;} }
    static QChar mapNesChar(int v) { static const QString s="APZLGITYEOXUKSVN"; return v>=0&&v<16?s[v]:QChar('?'); }

    static QString invokeGameGenieDecodeNES(QString gg) {
        gg=gg.trimmed().toUpper(); if(gg.length()!=6&&gg.length()!=8)return{}; int d[8]={};for(int i=0;i<gg.length();++i)d[i]=unmapNesChar(gg[i]);
        int address=0x8000; address|=(d[1]&8)<<4;address|=(d[2]&7)<<4;address|=(d[3]&7)<<12;address|=(d[3]&8);address|=(d[4]&7);address|=(d[4]&8)<<8;address|=(d[5]&7)<<8;
        int value=0,check=0;if(gg.length()==8){value|=d[0]&7;value|=(d[0]&8)<<4;value|=(d[1]&7)<<4;value|=d[7]&8;check|=d[5]&8;check|=d[6]&7;check|=(d[6]&8)<<4;check|=(d[7]&7)<<4;return QString("%1:%2:%3").arg(address,4,16,QChar('0')).arg(value,2,16,QChar('0')).arg(check,2,16,QChar('0')).toUpper();}
        value|=d[0]&7;value|=(d[0]&8)<<4;value|=(d[1]&7)<<4;value|=d[5]&8;return QString("%1:%2").arg(address,4,16,QChar('0')).arg(value,2,16,QChar('0')).toUpper();
    }
    static QString invokeGameGenieEncodeNES(const QString &raw) {
        try {QStringList parts=raw.split(':');if(parts.size()<2)return{};bool ok1=false,ok2=false,ok3=true;int address=parts[0].toInt(&ok1,16),value=parts[1].toInt(&ok2,16),check=0;if(parts.size()==3)check=parts[2].toInt(&ok3,16);if(!ok1||!ok2||!ok3)return{};int d[8]={};d[1]|=(address>>4)&8;d[2]|=(address>>4)&7;d[3]|=(address>>12)&7;d[3]|=address&8;d[4]|=address&7;d[4]|=(address>>8)&8;d[5]|=(address>>8)&7;if(parts.size()==3){d[0]|=value&7;d[0]|=(value>>4)&8;d[1]|=(value>>4)&7;d[2]|=8;d[7]|=value&8;d[5]|=check&8;d[6]|=check&7;d[6]|=(check>>4)&8;d[7]|=(check>>4)&7;}else{d[0]|=value&7;d[0]|=(value>>4)&8;d[1]|=(value>>4)&7;d[5]|=value&8;}QString out;int len=parts.size()==3?8:6;for(int i=0;i<len;i++)out+=mapNesChar(d[i]);return out;}catch(...){return{};}
    }

    // -------------------------------------------------------------------------
    // EXPORTERS
    // -------------------------------------------------------------------------
    static QByteArray asciiFixed(const QString &s,int n){QByteArray b=s.toLatin1();b.resize(n);return b;}
    void exportKronos(const QString &path){static const QRegularExpression reMatchAddr(R"(^[Dd13][0-9A-Fa-f]{7})");static const QRegularExpression reNonAscii(R"([^\x20-\x7E])");static const QRegularExpression reSpaces(R"(\s+)"); QFile f(path);if(!f.open(QIODevice::WriteOnly))throw std::runtime_error(f.errorString().toStdString());QDataStream w(&f);w.setByteOrder(QDataStream::LittleEndian);w.writeRawData("YCHT",4);w<<(quint8)0<<(quint8)0<<(quint8)0;int total=0;for(const auto&kv:visibleEntries())for(const auto&c:kv.second.codes)if(reMatchAddr.match(c).hasMatch())++total;w<<(quint8)qMin(total,255);for(const auto&kv:visibleEntries()){auto e=kv.second;QString name=e.baseDesc;name.remove(reNonAscii);if(name.size()>255)name=name.left(255);QByteArray nb=name.toLatin1();for(const QString&code:e.codes){QStringList parts=code.split(reSpaces);if(parts.size()<2)continue;QString p1=parts[0].toUpper().leftJustified(8,'0').left(8),p2=parts[1].toUpper().leftJustified(4,'0').left(4);QChar type=p1[0];if(type!='D'&&type!='1'&&type!='3')continue;QString typeStr=type=='3'?"02":type=='1'?"03":"01";QString hex="000000"+typeStr+"0"+p1.mid(1)+"0000"+p2;QByteArray chunk;for(int i=0;i<12;i++)chunk.append(char(hex.mid(i*2,2).toUInt(nullptr,16)));w.writeRawData(chunk.constData(),12);w<<(quint8)(nb.size()+1);w.writeRawData(nb.constData(),nb.size());QByteArray z(5,0);w.writeRawData(z.constData(),5);}}}
    void exportVbaClt(const QString &path){QFile f(path);if(!f.open(QIODevice::WriteOnly))throw std::runtime_error(f.errorString().toStdString());QDataStream w(&f);w.setByteOrder(QDataStream::LittleEndian);QHash<QChar,quint8> masks{{'0',0xFF},{'1',0x70},{'2',0x21},{'3',0x00},{'4',0x09},{'5',0x24},{'6',0x0B},{'7',0x08},{'8',0x01},{'9',0xFF},{'A',0x0A},{'B',0x23},{'C',0x22},{'D',0x07},{'E',0x20},{'F',0x32}};int total=0;for(const auto&kv:visibleEntries())total+=kv.second.codes.size();w<<(quint8)1<<(quint8)1<<(quint32)total;for(const auto&kv:visibleEntries()){QString safe=kv.second.baseDesc;safe.remove(QRegularExpression(R"([^\x20-\x7E])"));QByteArray desc=asciiFixed(safe,32);int remaining=0;bool slide=false;for(const QString&item:kv.second.codes){QStringList parts=item.split(QRegularExpression(R"(\s+)"));if(parts.size()<2)continue;QString p1=parts[0].toUpper().leftJustified(8,'0').left(8),p2=parts[1].toUpper().leftJustified(4,'0').left(4);QChar type=p1[0];bool multi=false;if(remaining>0){multi=true;--remaining;}else if(slide){multi=true;slide=false;}quint8 mask=multi?0xFF:masks.value(type,0);bool ok=false;quint32 cd8=p1.toUInt(&ok,16),cd8z=("0"+p1.mid(1)).toUInt(&ok,16);quint16 cd4=p2.toUInt(&ok,16);if(mask==0xFF)cd8z=cd8;QByteArray code=asciiFixed(item,20);QByteArray z6(6,0);w.writeRawData("\0\2\0\0",4);if(multi||type=='0'||type=='9'){QByteArray ff(4,char(0xFF));w.writeRawData(ff.constData(),4);}else{w<<(quint8)mask;QByteArray z3(3,0);w.writeRawData(z3.constData(),3);}w<<(quint16)0<<(quint16)0;w<<(quint32)cd8<<(quint32)cd8z<<(quint16)cd4;w.writeRawData(z6.constData(),6);w.writeRawData(code.constData(),20);w.writeRawData(desc.constData(),32);if(!multi){if(type=='5'){int count=p2.toInt(nullptr,16);remaining=int(std::floor(((count-1)&0xFFFF)/3.0)+1);}else if(type=='4')slide=true;}}}}
    void writeTextFile(const QString &path,const QString &text){QFile f(path);if(!f.open(QIODevice::WriteOnly|QIODevice::Text))throw std::runtime_error(f.errorString().toStdString());QTextStream out(&f);out.setEncoding(QStringConverter::Utf8);out<<text;}
    void exportSnes(const QString&p){QString s;for(const auto&kv:visibleEntries())for(QString c:kv.second.codes){if(c.size()==8&&!c.contains('-'))c=c.left(6)+"="+c.mid(6,2);s+=QString("cheat\n  name: %1\n  code: %2\n\n").arg(kv.second.baseDesc,c);}writeTextFile(p,s);}
    void exportTabDelimited(const QString&p){QString s;for(const auto&kv:visibleEntries())for(const auto&c:kv.second.codes)s+=c+"\t"+kv.second.baseDesc+"\n";writeTextFile(p,s);}
    void exportPcsxr(const QString&p){QString s;for(const auto&kv:visibleEntries()){if(kv.second.codes.isEmpty())continue;s+="["+kv.second.baseDesc+"]\n";for(const auto&c:kv.second.codes)s+=c+"\n";}writeTextFile(p,s);}
    void exportEpsxe(const QString&p){QString s;for(const auto&kv:visibleEntries()){if(kv.second.codes.isEmpty())continue;s+="#"+kv.second.baseDesc+"\n";for(const auto&c:kv.second.codes)s+=c+"\n";}writeTextFile(p,s);}
    void exportGbc(const QString&p){QFile f(p);if(!f.open(QIODevice::WriteOnly))throw std::runtime_error(f.errorString().toStdString());QDataStream w(&f);w.setByteOrder(QDataStream::LittleEndian);int total=0;for(const auto&kv:visibleEntries())total+=kv.second.codes.size();w<<(quint8)0<<(quint8)qMin(total,255)<<(quint8)0;int processed=0;for(const auto&kv:visibleEntries()){if(processed>=255)break;QString d=kv.second.baseDesc;d.remove(QRegularExpression(R"([^\x20-\x7E])"));QByteArray db=d.toLatin1();for(const auto&c:kv.second.codes){if(processed>=255)break;w<<(quint8)0<<(quint8)db.size()<<(quint8)0;w.writeRawData(db.constData(),db.size());w<<(quint8)(c.contains('-')?0x0b:0x08);QByteArray cb=c.toLatin1();w.writeRawData(cb.constData(),cb.size());++processed;}}}
    void exportMch(const QString&p){QString s="CAT Cheats\n";for(const auto&kv:visibleEntries()){s+="CODE 0 "+kv.second.baseDesc+"\n";for(const auto&c:kv.second.codes)s+=c+"\n";}writeTextFile(p,s);}
    void exportNes(const QString&p){QString s;for(const auto&kv:visibleEntries()){QString desc=kv.second.baseDesc.trimmed();for(const auto&item:kv.second.codes){for(QString raw:item.split('+',Qt::SkipEmptyParts)){raw=raw.trimmed();while(raw.startsWith(':'))raw.remove(0,1);if(raw.size()==9&&QRegularExpression(R"(^[A-Z]{9}$)").match(raw).hasMatch())raw=raw.mid(1);if(QRegularExpression(R"(^[A-Z]{6}$|^[A-Z]{8}$)").match(raw).hasMatch())raw=invokeGameGenieDecodeNES(raw);auto m=QRegularExpression(R"(^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$)").match(raw);if(m.hasMatch()){QString addr=m.captured(1),val=m.captured(2),cmp=m.captured(3);bool high=addr.toInt(nullptr,16)>=0x8000,has=!cmp.isEmpty();QString prefix=high?(has?"SC:":"S:"):(has?"C:":":");QString body=has?addr+":"+val+":"+cmp:addr+":"+val;s+=prefix+body+":"+desc+"\n";}else{s+=(raw.startsWith(':')?raw:":"+raw)+":"+desc+"\n";}}}}writeTextFile(p,s);}
    void exportRetroArch(const QString&p){auto entries=visibleEntries();QString s=QString("cheats = %1\n\n").arg(entries.size());for(int i=0;i<entries.size();++i){const auto&e=entries[i].second;s+=QString("cheat%1_desc = \"%2\"\ncheat%1_code = \"%3\"\ncheat%1_enable = false\n\n").arg(i).arg(e.baseDesc).arg(e.codes.join('+'));}writeTextFile(p,s);}

    // -------------------------------------------------------------------------
    // UI
    // -------------------------------------------------------------------------
    void buildUi(){
        auto *central = new QWidget;
        setCentralWidget(central);
        auto *main = new QVBoxLayout(central);
        main->setContentsMargins(10, 10, 10, 10);
        main->setSpacing(6);

        // Top Control Row
        auto *top = new QHBoxLayout;
        top->setSpacing(6);
        lblInput = new QLabel("Input Module:");
        cmbInputModule = new QComboBox;
        cmbInputModule->setFixedWidth(ComboWidth);

        btnImport = new QPushButton("Import File");
        btnImport->setFixedWidth(95);

        lblTargetRegex = new QLabel("Target System Regex:");
        cmbTargetRegex = new QComboBox;
        cmbTargetRegex->setFixedWidth(ComboWidth);

        top->addWidget(lblInput);
        top->addWidget(cmbInputModule);
        top->addWidget(btnImport);
        top->addWidget(lblTargetRegex);
        top->addWidget(cmbTargetRegex);
        top->addStretch(1);
        main->addLayout(top);

        // Main Splitter Area
        auto *split = new QSplitter(Qt::Horizontal);
        split->setChildrenCollapsible(false);

        // Left Pane (Grouped Cheat Descriptions + List + Group Control Row)
        auto *left = new QWidget;
        auto *leftLayout = new QVBoxLayout(left);
        leftLayout->setContentsMargins(0, 0, 0, 0);
        leftLayout->setSpacing(5);

        auto *leftTitleRow = new QHBoxLayout;
        leftTitleRow->addWidget(new QLabel("Grouped Cheat Descriptions:"));
        leftTitleRow->addStretch(1);
        leftLayout->addLayout(leftTitleRow);

        lstCheats = new QListWidget;
        lstCheats->setSelectionMode(QAbstractItemView::SingleSelection);
        leftLayout->addWidget(lstCheats, 1);

        auto *leftActions = new QHBoxLayout;
        leftActions->setSpacing(4);
        leftActions->addStretch(1);

        txtNewGroup = new QLineEdit;
        txtNewGroup->setPlaceholderText("New group name");
        txtNewGroup->setFixedWidth(206);
        txtNewGroup->setFixedHeight(ControlHeight);

        btnNewGroup = new QPushButton("Add");
        btnNewGroup->setFixedWidth(AddBtnWidth);
        btnNewGroup->setFixedHeight(ControlHeight);

        btnMoveUp = new QPushButton("▲");
        btnMoveDown = new QPushButton("▼");
        btnDeleteGroup = new QPushButton("❌");
        for (auto *b : {btnMoveUp, btnMoveDown, btnDeleteGroup}) {
            b->setFixedWidth(ActionBtnWidth);
            b->setFixedHeight(ControlHeight);
        }

        leftActions->addWidget(txtNewGroup);
        leftActions->addWidget(btnNewGroup);
        leftActions->addWidget(btnMoveUp);
        leftActions->addWidget(btnMoveDown);
        leftActions->addWidget(btnDeleteGroup);
        leftActions->addStretch(1);
        leftLayout->addLayout(leftActions);

        // Right Pane (Codes Header + Code Editor + Save Button)
        auto *right = new QWidget;
        auto *rightLayout = new QVBoxLayout(right);
        rightLayout->setContentsMargins(0, 0, 0, 0);
        rightLayout->setSpacing(5);

        auto *rightTitleRow = new QHBoxLayout;
        rightTitleRow->addWidget(new QLabel("Codes in Selected Group (One per line):"));
        rightTitleRow->addStretch(1);
        rightLayout->addLayout(rightTitleRow);

        txtEditor = new QPlainTextEdit;
        txtEditor->setLineWrapMode(QPlainTextEdit::NoWrap);
        QFont editorFont = QFontDatabase::systemFont(QFontDatabase::FixedFont);
        editorFont.setPointSize(10);
        txtEditor->setFont(editorFont);
        rightLayout->addWidget(txtEditor, 1);

        auto *saveRow = new QHBoxLayout;
        saveRow->addStretch(1);
        btnSaveGroup = new QPushButton("Update Current Modifications");
        btnSaveGroup->setFixedWidth(SaveBtnWidth);
        saveRow->addWidget(btnSaveGroup);
        saveRow->addStretch(1);
        rightLayout->addLayout(saveRow);

        split->addWidget(left);
        split->addWidget(right);
        split->setStretchFactor(0, 1);
        split->setStretchFactor(1, 1);
        main->addWidget(split, 1);

        // Enforce initial 50/50 Splitter Position
        QTimer::singleShot(0, this, [split]() {
            int availableWidth = split->width();
            if (availableWidth > 0) {
                int leftWidth = availableWidth / 2;
                int rightWidth = availableWidth - leftWidth;
                split->setSizes({leftWidth, rightWidth});
            }
        });

        // Export Control Row
        auto *exportRow = new QHBoxLayout;
        exportRow->setSpacing(6);
        lblOutput = new QLabel("Export To:");
        cmbOutputModule = new QComboBox;
        cmbOutputModule->setFixedWidth(ComboWidth);
        btnExport = new QPushButton("Export File");
        btnExport->setFixedWidth(95);

        exportRow->addWidget(lblOutput);
        exportRow->addWidget(cmbOutputModule);
        exportRow->addWidget(btnExport);
        exportRow->addStretch(1);
        main->addLayout(exportRow);

        // System Activity Log
        auto *logHeader = new QLabel("System Activity Log:");
        main->addWidget(logHeader);

        txtStatusLog = new QPlainTextEdit;
        txtStatusLog->setReadOnly(true);
        txtStatusLog->setLineWrapMode(QPlainTextEdit::WidgetWidth);
        QFont logFont = QFontDatabase::systemFont(QFontDatabase::FixedFont);
        logFont.setPointSize(8);
        txtStatusLog->setFont(logFont);
        txtStatusLog->setFixedHeight(72);
        main->addWidget(txtStatusLog);

        lblTargetRegex->setVisible(false);
        cmbTargetRegex->setVisible(false);
        cmbTargetRegex->setEnabled(false);

        // Use the same insertion order as the PySide6 OrderedDict-based implementation.
        for (const QString &k : inputModuleOrder)
            if (inputModules.contains(k)) cmbInputModule->addItem(k);

        for (const QString &k : inputModuleOrder)
            if (k != "RetroArch (Global)" && inputModules.contains(k)) cmbTargetRegex->addItem(k);
        if (cmbTargetRegex->count()) cmbTargetRegex->setCurrentIndex(0);

        btnMoveUp->setEnabled(false);
        btnMoveDown->setEnabled(false);
        btnDeleteGroup->setEnabled(false);
        btnSaveGroup->setEnabled(false);

        // Deliberately use the native Qt/platform style. The PySide6 GUI does not
        // impose a global stylesheet, and doing so makes Linux/Windows/macOS look
        // less native and can subtly change control metrics.
    }

    void wireEvents(){
        connect(cmbInputModule,&QComboBox::currentTextChanged,this,[this]{updateOutputModuleChoices();});
        connect(cmbTargetRegex,&QComboBox::currentTextChanged,this,[this]{updateOutputModuleChoices();});
        connect(txtEditor,&QPlainTextEdit::textChanged,this,[this]{if(!suppressEvents)isDirty=true;});
        connect(txtNewGroup,&QLineEdit::returnPressed,this,[this]{newGroup();});
        connect(lstCheats,&QListWidget::currentRowChanged,this,[this](int row){listSelectionChanged(row);});
        connect(btnImport,&QPushButton::clicked,this,[this]{importClicked();});
        connect(btnExport,&QPushButton::clicked,this,[this]{exportClicked();});
        connect(btnSaveGroup,&QPushButton::clicked,this,[this]{saveCurrentGroup(false);});
        connect(btnNewGroup,&QPushButton::clicked,this,[this]{newGroup();});
        connect(btnDeleteGroup,&QPushButton::clicked,this,[this]{deleteGroup();});
        connect(btnMoveUp,&QPushButton::clicked,this,[this]{moveCheatGroup(-1);});
        connect(btnMoveDown,&QPushButton::clicked,this,[this]{moveCheatGroup(1);});
    }

    void updateOutputModuleChoices(){
        if(!cmbInputModule) return;

        // Match the PySide6 implementation: rebuilding the output list must not
        // emit intermediate selection changes back into the application.
        QSignalBlocker blocker(cmbOutputModule);
        QString selected = cmbInputModule->currentText();
        cmbOutputModule->clear();
        const QString retro = "RetroArch (.cht)";

        if(selected == "RetroArch (Global)"){
            lblTargetRegex->setVisible(true);
            cmbTargetRegex->setVisible(true);
            cmbTargetRegex->setEnabled(true);

            QString target = cmbTargetRegex->currentText();
            QString mapped = moduleOutputMap.value(target);
            if(!mapped.isEmpty() && outputModules.contains(mapped))
                cmbOutputModule->addItem(mapped);
            if(outputModules.contains(retro) && cmbOutputModule->findText(retro) < 0)
                cmbOutputModule->addItem(retro);

            cmbOutputModule->setEnabled(cmbOutputModule->count() > 0);
        } else {
            if(outputModules.contains(retro))
                cmbOutputModule->addItem(retro);

            QString mapped = moduleOutputMap.value(selected);
            if(!mapped.isEmpty() && outputModules.contains(mapped) && cmbOutputModule->findText(mapped) < 0)
                cmbOutputModule->addItem(mapped);

            // The PySide6 GUI only enables the normal output selector when an
            // input-specific output exists in addition to RetroArch.
            cmbOutputModule->setEnabled(cmbOutputModule->count() > 1);
            lblTargetRegex->setVisible(false);
            cmbTargetRegex->setVisible(false);
            cmbTargetRegex->setEnabled(false);
        }

        if(cmbOutputModule->count())
            cmbOutputModule->setCurrentIndex(0);
    }

    bool confirmDiscard(const QString &message){if(!isDirty)return true;return QMessageBox::question(this,"Unsaved Progress",message,QMessageBox::Yes|QMessageBox::No,QMessageBox::No)==QMessageBox::Yes;}

    void importClicked(){if(!confirmDiscard("Discard unsaved changes?"))return;QString selected=cmbInputModule->currentText();if(!inputModules.contains(selected))return;const auto module=inputModules.value(selected);QString path=QFileDialog::getOpenFileName(this,"Import Cheat File",lastDirectory,module.filter);if(path.isEmpty())return;lastDirectory=QFileInfo(path).absolutePath();try{cheatDatabase.clear();QString target=selected=="RetroArch (Global)"?cmbTargetRegex->currentText():selected;auto parse=[module,target](const QString&t,const QString&sys){return module.parse(t,sys.isEmpty()?target:sys);};module.import(path,target,parse);refreshCheatList();txtNewGroup->clear();writeLog("Import operation finalized.");}catch(const std::exception&e){writeLog(QString("Parsing error encountered: %1").arg(e.what()),"ERROR");}}
    void exportClicked(){if(cheatDatabase.isEmpty()){writeLog("No structural configuration items inside current registry matrix to process.","WARN");return;}QString selected=cmbOutputModule->currentText();if(!outputModules.contains(selected))return;const auto module=outputModules.value(selected);QString ext=suggestedExtension(module.filter);QString path=QFileDialog::getSaveFileName(this,"Export Cheat File",lastDirectory+"/cheats"+ext,module.filter);if(path.isEmpty())return;lastDirectory=QFileInfo(path).absolutePath();try{module.exportFunc(path);writeLog("Export operation executed successfully.");}catch(const std::exception&e){writeLog(QString("Export operational crash footprint: %1").arg(e.what()),"ERROR");}}

    bool saveCurrentSelectionIfDirty(){if(!isDirty||lastSelectedIndex<0||lastSelectedIndex>=lstCheats->count())return true;auto choice=QMessageBox::warning(this,"Unsaved Progress","Save changes to the current group before proceeding?",QMessageBox::Yes|QMessageBox::No|QMessageBox::Cancel,QMessageBox::Cancel);if(choice==QMessageBox::Cancel)return false;if(choice==QMessageBox::Yes)saveCurrentGroup(true);else isDirty=false;return true;}

    void listSelectionChanged(int newIndex){if(suppressEvents||newIndex==lastSelectedIndex)return;if(isDirty&&lastSelectedIndex>=0&&lastSelectedIndex<lstCheats->count()){auto c=QMessageBox::warning(this,"Unsaved Progress","Discard unsaved group modifications?",QMessageBox::Yes|QMessageBox::No,QMessageBox::No);if(c==QMessageBox::No){suppressEvents=true;lstCheats->setCurrentRow(lastSelectedIndex);suppressEvents=false;return;}}if(newIndex<0)return;lastSelectedIndex=newIndex;auto entries=visibleEntries();if(newIndex>=entries.size())return;suppressEvents=true;txtEditor->setPlainText(entries[newIndex].second.codes.join("\n"));isDirty=false;suppressEvents=false;updateUiState();}

    void saveCurrentGroup(bool fromPrompt){int idx=lstCheats->currentRow();if(idx<0)return;auto entries=visibleEntries();if(idx>=entries.size())return;QString targetKey=entries[idx].first;CheatEntry entry=entries[idx].second;static const QRegularExpression reLineBreak(R"(\r\n|\n|\r)");if(fromPrompt) {QStringList lines = txtEditor->toPlainText().split(reLineBreak, Qt::SkipEmptyParts);entry.codes.clear();for(auto&s:lines)entry.codes<<s.trimmed().toUpper();int db=findKey(targetKey);if(db>=0)cheatDatabase[db].second=entry;isDirty=false;return;}QString selected=cmbInputModule->currentText();QString sysName=selected=="RetroArch (Global)"?cmbTargetRegex->currentText():selected;QString sys=systemKey(sysName);QStringList lines = txtEditor->toPlainText().split(reLineBreak, Qt::SkipEmptyParts), updated;bool invalid=false;QString lockedFormat;for(const auto&line:lines){QString clean=line.trimmed().toUpper();auto parsed=invokeSystemParser(sys,clean);if(parsed){if(lockedFormat.isEmpty())lockedFormat=parsed->format;if(parsed->format==lockedFormat)updated<<parsed->code;else{invalid=true;writeLog(QString("Line '%1' rejected. Block locked to structure protocol dynamic rules.").arg(line),"ERROR");}}else{invalid=true;writeLog(QString("Line '%1' tracking metric failure. Block syntax rejected.").arg(line),"ERROR");}}if(lockedFormat.isEmpty())lockedFormat=entry.format;entry.codes=updated;entry.format=lockedFormat;QString newKey=entry.baseDesc+":::"+lockedFormat;int db=findKey(targetKey);if(db>=0){if(targetKey!=newKey)cheatDatabase[db].first=newKey;cheatDatabase[db].second=entry;}suppressEvents=true;txtEditor->setPlainText(updated.join("\n"));suppressEvents=false;isDirty=false;refreshCheatList(idx);if(invalid)QMessageBox::warning(this,"Format Isolation Rule","Mismatched or invalid codes were detected and removed. A single block cannot mix different formats.");else writeLog(QString("Group '%1' successfully updated as uniform '%2' format.").arg(entry.baseDesc,lockedFormat));}

    void newGroup(){QString title=txtNewGroup->text().trimmed();if(title.isEmpty())return;if(!saveCurrentSelectionIfDirty())return;QString selected=cmbInputModule->currentText(),sysName=selected=="RetroArch (Global)"?cmbTargetRegex->currentText():selected,sys=systemKey(sysName),inherited="Unknown";if(systemCodePatterns.contains(sys)&&!systemCodePatterns.value(sys).isEmpty())inherited=systemCodePatterns.value(sys).first().key;QString key=title+":::"+inherited;if(findKey(key)<0){CheatEntry e;e.baseDesc=title;e.format=inherited;cheatDatabase.append({key,e});}txtNewGroup->clear();refreshCheatList();lstCheats->setCurrentRow(lstCheats->count()-1);lastSelectedIndex=lstCheats->currentRow();suppressEvents=true;txtEditor->clear();isDirty=false;suppressEvents=false;writeLog(QString("Added new group '%1' with inherited format standard '%2'.").arg(title,inherited));}
    void deleteGroup(){int idx=lstCheats->currentRow();if(idx<0)return;auto entries=visibleEntries();if(idx>=entries.size())return;QString key=entries[idx].first,title=entries[idx].second.baseDesc;if(QMessageBox::question(this,"Confirm",QString("Delete group '%1'?").arg(title),QMessageBox::Yes|QMessageBox::No,QMessageBox::No)==QMessageBox::No)return;int db=findKey(key);if(db>=0)cheatDatabase.remove(db);isDirty=false;refreshCheatList(qMin(idx,qMax(0,visibleEntries().size()-1)));writeLog(QString("Deleted group '%1'.").arg(title));}
    void moveCheatGroup(int direction){int idx=lstCheats->currentRow();if(idx<0)return;int target=idx+direction;if(target<0||target>=lstCheats->count())return;if(!saveCurrentSelectionIfDirty())return;auto vis=visibleEntries();if(idx>=vis.size()||target>=vis.size())return;int i1=findKey(vis[idx].first),i2=findKey(vis[target].first);if(i1>=0&&i2>=0)std::swap(cheatDatabase[i1],cheatDatabase[i2]);refreshCheatList(target);}

    void refreshCheatList(int preserveIndex=-1){suppressEvents=true;lstCheats->clear();auto entries=visibleEntries();for(const auto&kv:entries)lstCheats->addItem(kv.second.baseDesc);isDirty=false;if(!entries.isEmpty()){int idx=preserveIndex>=0?qBound(0,preserveIndex,entries.size()-1):0;lastSelectedIndex=idx;lstCheats->setCurrentRow(idx);txtEditor->setPlainText(entries[idx].second.codes.join("\n"));}else{lastSelectedIndex=-1;txtEditor->clear();}suppressEvents=false;updateUiState();}
    void updateUiState(){bool has=lstCheats->count()>0;btnMoveUp->setEnabled(has);btnMoveDown->setEnabled(has);btnDeleteGroup->setEnabled(has);btnSaveGroup->setEnabled(has);}
    void writeLog(const QString&message,const QString&level="INFO"){txtStatusLog->appendPlainText(QString("[%1] [%2] %3").arg(QTime::currentTime().toString("HH:mm:ss"),level,message));txtStatusLog->verticalScrollBar()->setValue(txtStatusLog->verticalScrollBar()->maximum());}
    static QString suggestedExtension(const QString&filter){auto patterns=filter.section('(',1,1).section(')',0,0).split(' ',Qt::SkipEmptyParts);for(const auto&p:patterns)if(p.startsWith("*."))return p.mid(1);return{};}
};

int main(int argc,char **argv){QApplication app(argc,argv);app.setApplicationName("Multi-Emulator Cheat Reformatter");MainWindow w;w.show();return app.exec();}

#include "main.moc"
