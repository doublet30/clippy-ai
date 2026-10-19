// revvy-ai-config: GUI editor for ~/.config/revvy-ai/config.json
// Keeps unknown keys, writes atomically with 0600 permissions (it holds API keys),
// and can test a backend / list its models using the values currently in the form.
#include <QtWidgets>
#include <QtNetwork>

struct ProviderInfo {
    QString id, label, kind, baseUrl, model;
    QStringList env, models;
    bool keyless = false;
};

static const QList<ProviderInfo> kProviders = {
    {"anthropic", "Claude (Anthropic)", "anthropic", "https://api.anthropic.com", "claude-sonnet-5-5", {"ANTHROPIC_API_KEY"}, {"claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"}, false},
    {"openai", "ChatGPT (OpenAI)", "openai", "https://api.openai.com/v1", "gpt-4.1-mini", {"OPENAI_API_KEY"}, {"gpt-4.1", "gpt-4.1-mini", "gpt-4o"}, false},
    {"gemini", "Google Gemini", "gemini", "https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-flash", {"GEMINI_API_KEY", "GOOGLE_API_KEY"}, {"gemini-2.5-pro", "gemini-2.5-flash"}, false},
    {"grok", "Grok (xAI)", "openai", "https://api.x.ai/v1", "grok-4", {"XAI_API_KEY", "GROK_API_KEY"}, {"grok-4"}, false},
    {"llama", "Meta Llama API", "openai", "https://api.llama.com/compat/v1", "Llama-4-Maverick-17B-128E-Instruct-FP8", {"LLAMA_API_KEY"}, {"Llama-4-Maverick-17B-128E-Instruct-FP8", "Llama-4-Scout-17B-16E-Instruct-FP8"}, false},
    {"local", "Local model (Ollama / llama.cpp / LM Studio)", "openai", "http://localhost:11434/v1", "llama3.2", {}, {"llama3.2", "qwen2.5", "mistral"}, true},
};

struct ProviderPage {
    ProviderInfo info;
    QLineEdit *key = nullptr, *baseUrl = nullptr;
    QComboBox *model = nullptr;
    QLabel *status = nullptr;
};

class ConfigWindow : public QMainWindow {
public:
    ConfigWindow() {
        setWindowTitle("Revvy AI – Configuration");
        resize(720, 560);
        auto *tabs = new QTabWidget;
        tabs->addTab(buildBrainTab(), "AI backend");
        tabs->addTab(buildGeneralTab(), "General");
        tabs->addTab(buildVoiceRecognitionTab(), "Voice Recognition");
        auto *bb = new QDialogButtonBox(QDialogButtonBox::Save | QDialogButtonBox::Reset | QDialogButtonBox::Close);
        bb->button(QDialogButtonBox::Reset)->setText("Revert");
        connect(bb, &QDialogButtonBox::accepted, this, [] {});
        connect(bb->button(QDialogButtonBox::Save), &QPushButton::clicked, this, [this] { save(); });
        connect(bb->button(QDialogButtonBox::Reset), &QPushButton::clicked, this, [this] { load(); });
        connect(bb->button(QDialogButtonBox::Close), &QPushButton::clicked, this, &QWidget::close);
        auto *w = new QWidget; auto *l = new QVBoxLayout(w);
        l->addWidget(tabs); l->addWidget(bb);
        pathLabel = new QLabel; pathLabel->setStyleSheet("color:gray");
        l->addWidget(pathLabel);
        setCentralWidget(w);
        load();
    }

    void saveNow() { save(); }
private:
    QJsonObject root;
    QString path = QDir::homePath() + "/.config/revvy-ai/config.json";
    QLabel *pathLabel;
    QComboBox *active, *terminal, *theme, *pin, *launch;
    QStackedWidget *stack;
    QListWidget *list;
    QList<ProviderPage> pages;
    QDoubleSpinBox *scale; QLineEdit *location, *userName;
    QComboBox *voice;
    QCheckBox *greeting, *hideChatBubble, *ttsOn; QSpinBox *rate, *pitch;
    QCheckBox *hotwordEnabled, *conversationMode;
    QLineEdit *hotword;
    QSpinBox *commandSeconds, *cooldownSeconds;
    QComboBox *hotwordSensitivity;
    QNetworkAccessManager nam;

    QWidget *buildBrainTab() {
        auto *w = new QWidget; auto *v = new QVBoxLayout(w);
        auto *f = new QFormLayout;
        active = new QComboBox; active->addItem("Auto (first backend that has a key)", "auto");
        for (auto &p : kProviders) active->addItem(p.label, p.id);
        f->addRow("Active backend:", active);
        v->addLayout(f);

        auto *h = new QHBoxLayout;
        list = new QListWidget; list->setMaximumWidth(230);
        stack = new QStackedWidget;
        for (auto &p : kProviders) {
            list->addItem(p.label);
            ProviderPage pg; pg.info = p;
            auto *page = new QWidget; auto *pf = new QFormLayout(page);
            pg.key = new QLineEdit; pg.key->setEchoMode(QLineEdit::Password);
            QString envHint = p.env.isEmpty() ? "no key needed" : "or set $" + p.env.join(" / $");
            pg.key->setPlaceholderText(p.keyless ? "(optional)" : envHint);
            auto *show = new QCheckBox("Show");
            connect(show, &QCheckBox::toggled, pg.key, [k = pg.key](bool on) { k->setEchoMode(on ? QLineEdit::Normal : QLineEdit::Password); });
            auto *kr = new QHBoxLayout; kr->addWidget(pg.key); kr->addWidget(show);
            pg.model = new QComboBox; pg.model->setEditable(true); pg.model->addItems(p.models);
            pg.baseUrl = new QLineEdit; pg.baseUrl->setPlaceholderText(p.baseUrl);
            pg.status = new QLabel; pg.status->setWordWrap(true);
            auto *test = new QPushButton("Test connection");
            auto *fetch = new QPushButton("Fetch models");
            auto *br = new QHBoxLayout; br->addWidget(test); br->addWidget(fetch); br->addStretch();
            pf->addRow("API key:", kr);
            pf->addRow("Model:", pg.model);
            pf->addRow("Base URL:", pg.baseUrl);
            pf->addRow(br);
            pf->addRow(pg.status);
            int idx = pages.size();
            connect(test, &QPushButton::clicked, this, [this, idx] { testConnection(idx); });
            connect(fetch, &QPushButton::clicked, this, [this, idx] { fetchModels(idx); });
            stack->addWidget(page);
            pages.append(pg);
        }
        connect(list, &QListWidget::currentRowChanged, stack, &QStackedWidget::setCurrentIndex);
        list->setCurrentRow(0);
        h->addWidget(list); h->addWidget(stack, 1);
        v->addLayout(h, 1);
        auto *note = new QLabel("Keys are stored in config.json (mode 0600). Leave the key empty to use the environment variable.");
        note->setWordWrap(true); note->setStyleSheet("color:gray");
        v->addWidget(note);
        return w;
    }

    QWidget *buildGeneralTab() {
        auto *w = new QWidget; auto *f = new QFormLayout(w);
        theme = new QComboBox; theme->setEditable(true);
        // Themes are optional packages: list whatever is installed (system dir, next to the build, per-user).
        QStringList themes;
        QStringList roots = {"/opt/ttos/revvy-ai/themes", QCoreApplication::applicationDirPath() + "/../themes",
                             QCoreApplication::applicationDirPath() + "/../../themes", QCoreApplication::applicationDirPath() + "/../../../themes",
                             QDir::homePath() + "/.config/revvy-ai/themes"};
        for (auto &r : roots)
            for (auto &e : QDir(r).entryList(QDir::Dirs | QDir::NoDotAndDotDot))
                if (QFile::exists(r + "/" + e + "/agent.json") && !themes.contains(e)) themes << e;
        themes.sort();
        theme->addItems(themes);
        scale = new QDoubleSpinBox; scale->setRange(0.5, 6); scale->setSingleStep(0.5);
        terminal = new QComboBox;
        terminal->addItem("Ask me before every command", "confirm");
        terminal->addItem("Allow without asking (dangerous)", "allow");
        terminal->addItem("Disable terminal access", "deny");
        pin = new QComboBox;
        pin->addItem("Above other windows", "above");
        pin->addItem("Below other windows (above the wallpaper)", "below");
        launch = new QComboBox;
        launch->addItem("Open known apps/files directly, ask for anything else", "auto");
        launch->addItem("Always ask before launching or opening", "confirm");
        launch->addItem("Never ask (dangerous)", "allow");
        location = new QLineEdit; location->setPlaceholderText("City for weather (empty = auto-detect)");
        userName = new QLineEdit;
        greeting = new QCheckBox("Say hello on startup");
        hideChatBubble = new QCheckBox("Hide chat bubble");
        hideChatBubble->setToolTip("Keep Revvy's speech and animation, but hide normal prompt, thinking, and answer bubbles. Safety confirmation prompts remain visible.");
        ttsOn = new QCheckBox("Speak answers aloud");
        voice = new QComboBox;
        voice->setToolTip("Choose automatic voice selection, an installed Piper neural voice, or an eSpeak fallback.");
        populateVoiceChoices();
        rate = new QSpinBox; rate->setRange(80, 400);
        pitch = new QSpinBox; pitch->setRange(0, 99);
        f->addRow("Character:", theme);
        f->addRow("Size multiplier:", scale);
        f->addRow("Stacking:", pin);
        f->addRow("Launching apps/files:", launch);
        f->addRow("Terminal access:", terminal);
        f->addRow("Default location:", location);
        f->addRow("Your name:", userName);
        f->addRow(greeting);
        f->addRow(hideChatBubble);
        f->addRow(ttsOn);
        f->addRow("Voice:", voice);
        f->addRow("Speech rate (wpm):", rate);
        f->addRow("Pitch:", pitch);
        return w;
    }

    QWidget *buildVoiceRecognitionTab() {
        auto *w = new QWidget;
        auto *v = new QVBoxLayout(w);
        auto *f = new QFormLayout;
        hotwordEnabled = new QCheckBox("Enable hotword detection");
        hotwordEnabled->setToolTip("Run an offline background listener only while this option is enabled.");
        conversationMode = new QCheckBox("Conversation mode");
        conversationMode->setToolTip("Allow broader follow-up speech recognition after Revvy responds. "
                                     "Leave this off to require your configured wake phrase for every request.");
        hotword = new QLineEdit;
        hotword->setPlaceholderText("Hey Revvy!");
        hotword->setToolTip("The phrase that activates a short voice-command listening window.");
        commandSeconds = new QSpinBox;
        commandSeconds->setRange(2, 30);
        commandSeconds->setSuffix(" seconds");
        commandSeconds->setToolTip("How long Revvy listens for your request after hearing the hotword.");
        cooldownSeconds = new QSpinBox;
        cooldownSeconds->setRange(0, 60);
        cooldownSeconds->setSuffix(" seconds");
        cooldownSeconds->setToolTip("Minimum pause after a request before hotword listening resumes.");
        hotwordSensitivity = new QComboBox;
        hotwordSensitivity->addItem("More sensitive", "1e-20");
        hotwordSensitivity->addItem("Balanced", "1e-30");
        hotwordSensitivity->addItem("Stricter", "1e-40");
        hotwordSensitivity->setToolTip("Balance between recognizing the hotword in noise and avoiding accidental activation.");
        auto *trainer = new QPushButton("Open Voice Calibration…");
        trainer->setToolTip("Save the current voice settings, then read a few local passages to calibrate Revvy's microphone and selected wake phrase recognition.");
        connect(trainer, &QPushButton::clicked, this, [this] {
            // The calibration tool reads config.json directly.  Persist the
            // current form first so it always uses the hotword shown above.
            if (!save())
                return;
            if (!QProcess::startDetached(QStringLiteral("/usr/local/bin/revvy-ai-voice-trainer"))) {
                QMessageBox::critical(this, "Revvy AI Voice Calibration",
                                      "The Voice Calibration tool could not be started.");
            }
        });
        f->addRow(hotwordEnabled);
        f->addRow(conversationMode);
        f->addRow("Hotword:", hotword);
        f->addRow("Listen after hotword:", commandSeconds);
        f->addRow("Cooldown:", cooldownSeconds);
        f->addRow("Detection sensitivity:", hotwordSensitivity);
        f->addRow("Voice calibration:", trainer);
        v->addLayout(f);
        auto *note = new QLabel("Speech recognition runs locally with Vosk. Audio is used only for hotword detection and the short command window, then the recognized text is sent to the running Revvy AI service.");
        note->setWordWrap(true);
        note->setStyleSheet("color:gray");
        v->addWidget(note);
        v->addStretch();
        return w;
    }

    static QString str(const QJsonValue &v, const QString &d = {}) { return v.isString() ? v.toString() : d; }

    void populateVoiceChoices() {
        voice->clear();
        // Keep the existing out-of-the-box behavior available, while making a
        // specific installed neural voice a deliberate and durable choice.
        voice->addItem("Automatic (best available Piper voice)", "auto");
        voice->insertSeparator(voice->count());

        QSet<QString> seen;
        const QStringList roots = {
            QDir::homePath() + "/.local/share/clippy-ai/voices",
            QDir::homePath() + "/.local/share/ttos/assistant/piper",
            "/opt/ttos/revvy-ai/voices",
            "/usr/share/piper-voices"
        };
        for (const QString &root : roots) {
            const QFileInfoList models = QDir(root).entryInfoList({"*.onnx"},
                QDir::Files | QDir::Readable, QDir::Name | QDir::IgnoreCase);
            for (const QFileInfo &model : models) {
                const QString path = model.canonicalFilePath().isEmpty()
                    ? model.absoluteFilePath() : model.canonicalFilePath();
                if (seen.contains(path))
                    continue;
                seen.insert(path);
                QString label = model.completeBaseName();
                label.replace('_', '-');
                voice->addItem("Piper — " + label, "piper:" + path);
            }
        }

        voice->insertSeparator(voice->count());
        voice->addItem("eSpeak NG — English (US)", "espeak:en-us");
        voice->addItem("eSpeak NG — English (British)", "espeak:en-gb");
    }

    void selectVoice(const QJsonObject &tts) {
        const QString engine = str(tts["engine"], "auto");
        const QJsonObject piper = tts["piper"].toObject();
        QString selection;
        if (engine == "piper" && !str(piper["model"]).isEmpty())
            selection = "piper:" + str(piper["model"]);
        else if (engine == "espeak")
            selection = "espeak:" + str(tts["voice"], "en-us");
        else
            selection = "auto";

        int index = voice->findData(selection);
        if (index < 0 && selection.startsWith("piper:")) {
            const QString model = selection.mid(QString("piper:").size());
            voice->insertItem(1, "Piper — " + QFileInfo(model).completeBaseName()
                              + " (not installed)", selection);
            index = 1;
        }
        if (index < 0 && selection.startsWith("espeak:")) {
            const QString espeakVoice = selection.mid(QString("espeak:").size());
            voice->addItem("eSpeak NG — " + espeakVoice, selection);
            index = voice->count() - 1;
        }
        voice->setCurrentIndex(index < 0 ? 0 : index);
    }

    void load() {
        root = {};
        QFile f(path);
        if (f.open(QIODevice::ReadOnly)) {
            QJsonParseError e; auto d = QJsonDocument::fromJson(f.readAll(), &e);
            if (e.error != QJsonParseError::NoError) QMessageBox::warning(this, "config.json", "Could not parse existing config: " + e.errorString());
            else root = d.object();
        }
        pathLabel->setText(path + (f.exists() ? "" : "  (will be created)"));
        int ai = active->findData(str(root["provider"], "auto")); active->setCurrentIndex(ai < 0 ? 0 : ai);
        auto provs = root["providers"].toObject();
        for (auto &pg : pages) {
            auto o = provs[pg.info.id].toObject();
            pg.key->setText(str(o["apiKey"]));
            pg.model->setCurrentText(str(o["model"], pg.info.model));
            pg.baseUrl->setText(str(o["baseUrl"]));
            pg.status->clear();
        }
        theme->setCurrentText(str(root["theme"], "tux"));
        scale->setValue(root["scale"].toDouble(2));
        int pi = pin->findData(str(root["pin"], "above")); pin->setCurrentIndex(pi < 0 ? 0 : pi);
        int li = launch->findData(str(root["launch"], "auto")); launch->setCurrentIndex(li < 0 ? 0 : li);
        int ti = terminal->findData(str(root["terminal"], "confirm")); terminal->setCurrentIndex(ti < 0 ? 0 : ti);
        location->setText(str(root["location"]));
        userName->setText(str(root["userName"]));
        greeting->setChecked(root["greeting"].toBool(true));
        hideChatBubble->setChecked(root["hideChatBubble"].toBool(false));
        auto tts = root["tts"].toObject();
        ttsOn->setChecked(tts["enabled"].toBool(true));
        selectVoice(tts);
        rate->setValue(tts["rate"].toInt(170));
        pitch->setValue(tts["pitch"].toInt(60));
        const QJsonObject speech = root["speechRecognition"].toObject();
        hotwordEnabled->setChecked(speech["enabled"].toBool(false));
        // Privacy-preserving default: every request needs a deliberate wake
        // phrase. Existing configurations without this key receive that
        // safer behavior automatically.
        conversationMode->setChecked(speech["conversationMode"].toBool(false));
        hotword->setText(str(speech["hotword"], "Hey Revvy!"));
        commandSeconds->setValue(speech["commandSeconds"].toInt(8));
        cooldownSeconds->setValue(speech["cooldownSeconds"].toInt(2));
        const int sensitivity = hotwordSensitivity->findData(str(speech["keywordThreshold"], "1e-30"));
        hotwordSensitivity->setCurrentIndex(sensitivity < 0 ? 1 : sensitivity);
    }

    bool save() {
        // Voice Calibration can update speechRecognition while this window is
        // open.  Start from the newest valid on-disk document so its profile
        // and measurement fields survive a later settings save.
        QJsonObject o = root;
        QFile currentConfig(path);
        if (currentConfig.open(QIODevice::ReadOnly)) {
            QJsonParseError parseError;
            const QJsonDocument current = QJsonDocument::fromJson(currentConfig.readAll(), &parseError);
            if (parseError.error == QJsonParseError::NoError && current.isObject())
                o = current.object();
        }
        o["provider"] = active->currentData().toString();
        QJsonObject provs = o["providers"].toObject();
        for (auto &pg : pages) {
            QJsonObject p = provs[pg.info.id].toObject();
            auto put = [&](const char *k, const QString &v) { if (v.trimmed().isEmpty()) p.remove(k); else p[k] = v.trimmed(); };
            put("apiKey", pg.key->text());
            put("model", pg.model->currentText());
            put("baseUrl", pg.baseUrl->text());
            if (p.isEmpty()) provs.remove(pg.info.id); else provs[pg.info.id] = p;
        }
        o["providers"] = provs;
        o["theme"] = theme->currentText().trimmed();
        o["scale"] = scale->value();
        o["terminal"] = terminal->currentData().toString();
        o["pin"] = pin->currentData().toString();
        o["launch"] = launch->currentData().toString();
        o["location"] = location->text().trimmed();
        o["userName"] = userName->text().trimmed();
        o["greeting"] = greeting->isChecked();
        o["hideChatBubble"] = hideChatBubble->isChecked();
        QJsonObject tts = o["tts"].toObject();
        const QString selectedVoice = voice->currentData().toString();
        tts["enabled"] = ttsOn->isChecked();
        if (selectedVoice.startsWith("piper:")) {
            QJsonObject piper = tts["piper"].toObject();
            piper["model"] = selectedVoice.mid(QString("piper:").size());
            tts["piper"] = piper;
            tts["engine"] = "piper";
        } else if (selectedVoice.startsWith("espeak:")) {
            tts["voice"] = selectedVoice.mid(QString("espeak:").size());
            tts["engine"] = "espeak";
        } else {
            QJsonObject piper = tts["piper"].toObject();
            piper.remove("model");
            if (piper.isEmpty()) tts.remove("piper"); else tts["piper"] = piper;
            tts["engine"] = "auto";
        }
        tts["rate"] = rate->value(); tts["pitch"] = pitch->value();
        o["tts"] = tts;
        QJsonObject speech = o["speechRecognition"].toObject();
        speech["enabled"] = hotwordEnabled->isChecked();
        speech["conversationMode"] = conversationMode->isChecked();
        speech["hotword"] = hotword->text().trimmed().isEmpty() ? QStringLiteral("Hey Revvy!") : hotword->text().trimmed();
        speech["commandSeconds"] = commandSeconds->value();
        speech["cooldownSeconds"] = cooldownSeconds->value();
        speech["keywordThreshold"] = hotwordSensitivity->currentData().toString();
        o["speechRecognition"] = speech;

        QDir().mkpath(QFileInfo(path).absolutePath());
        QSaveFile out(path);
        out.setDirectWriteFallback(false);
        if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) { QMessageBox::critical(this, "Save failed", out.errorString()); return false; }
        out.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
        out.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        if (!out.commit()) { QMessageBox::critical(this, "Save failed", out.errorString()); return false; }
        root = o;
        // RevolutionUI's custom sessions do not consistently activate
        // graphical-session.target. Keep an XDG autostart fallback beside
        // the systemd default.target enablement for reliable X11/Wayland login.
        const QString autostartDir = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation) + "/autostart";
        const QString autostartFile = autostartDir + "/revvy-ai-voice.desktop";
        int unitResult = 0;
        if (hotwordEnabled->isChecked()) {
            QDir().mkpath(autostartDir);
            QSaveFile startup(autostartFile);
            if (startup.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                startup.write("[Desktop Entry]\n"
                              "Type=Application\n"
                              "Name=Revvy AI Voice Recognition\n"
                              "Comment=Start the Revvy AI offline hotword listener\n"
                              "Exec=systemctl --user start revvy-ai-voice.service\n"
                              "Terminal=false\n"
                              "NoDisplay=true\n"
                              "X-GNOME-Autostart-enabled=true\n");
                startup.commit();
            }
        } else {
            QFile::remove(autostartFile);
        }
        // The assistant widget owns whether Revvy exists in a session.  Do
        // not enable the listener as an independent systemd startup unit:
        // doing so used to start (or repeatedly attempt to start) Revvy even
        // after the user turned its widget off.  The XDG entry created above
        // requests a start next login only when voice is enabled, and the
        // listener's Requisite=revvy-ai.service then accepts it only after
        // widgetctl has started the enabled Revvy widget.
        QProcess::execute(QStringLiteral("systemctl"),
                          {QStringLiteral("--user"), QStringLiteral("disable"),
                           QStringLiteral("revvy-ai-voice.service")});
        if (hotwordEnabled->isChecked()) {
            // Apply changed hotword or timing settings immediately if the
            // visible assistant widget is currently active.
            unitResult = QProcess::execute(QStringLiteral("systemctl"),
                                           {QStringLiteral("--user"), QStringLiteral("restart"),
                                            QStringLiteral("revvy-ai-voice.service")});
        } else {
            unitResult = QProcess::execute(QStringLiteral("systemctl"),
                                           {QStringLiteral("--user"), QStringLiteral("stop"),
                                            QStringLiteral("revvy-ai-voice.service")});
        }
        // Older releases kept transient widget choices in state.json. Saving
        // here is an explicit choice, so drop those stale overrides.
        QString statePath = QFileInfo(path).absolutePath() + "/state.json";
        QFile sf(statePath);
        if (sf.open(QIODevice::ReadOnly)) {
            QJsonObject st = QJsonDocument::fromJson(sf.readAll()).object(); sf.close();
            if (st.contains("provider") || st.contains("theme") || st.contains("pin")) {
                st.remove("provider"); st.remove("theme"); st.remove("pin");
                QSaveFile so(statePath);
                if (so.open(QIODevice::WriteOnly | QIODevice::Truncate)) { so.write(QJsonDocument(st).toJson()); so.commit(); }
            }
        }
        statusBar()->showMessage(unitResult == 0
            ? "Saved. Voice recognition settings are active immediately."
            : "Saved. Revvy picks up changes on its next start.", 6000);
        return true;
    }

    // ---- network helpers ----
    QString keyFor(const ProviderPage &pg) {
        QString k = pg.key->text().trimmed();
        for (int i = 0; k.isEmpty() && i < pg.info.env.size(); ++i) k = qEnvironmentVariable(pg.info.env[i].toUtf8());
        return k;
    }
    QString baseFor(const ProviderPage &pg) { QString b = pg.baseUrl->text().trimmed(); if (b.isEmpty()) b = pg.info.baseUrl; while (b.endsWith('/')) b.chop(1); return b; }

    void report(int idx, QNetworkReply *r, bool ok, const QString &msg) {
        pages[idx].status->setStyleSheet(ok ? "color:#2e7d32" : "color:#c62828");
        pages[idx].status->setText(msg);
        r->deleteLater();
    }
    static QString errorText(const QByteArray &body, QNetworkReply *r) {
        auto d = QJsonDocument::fromJson(body).object();
        auto e = d["error"];
        QString m = e.isObject() ? e.toObject()["message"].toString() : e.toString();
        if (m.isEmpty()) m = r->errorString();
        return m;
    }

    QNetworkRequest makeReq(const ProviderPage &pg, const QString &url) {
        QNetworkRequest rq{QUrl(url)};
        rq.setRawHeader("Content-Type", "application/json");
        rq.setTransferTimeout(30000);
        QString k = keyFor(pg);
        if (pg.info.kind == "anthropic") { rq.setRawHeader("x-api-key", k.toUtf8()); rq.setRawHeader("anthropic-version", "2023-06-01"); }
        else if (pg.info.kind == "gemini") rq.setRawHeader("x-goog-api-key", k.toUtf8());
        else if (!k.isEmpty()) rq.setRawHeader("Authorization", ("Bearer " + k).toUtf8());
        return rq;
    }

    void testConnection(int idx) {
        auto &pg = pages[idx];
        if (!pg.info.keyless && keyFor(pg).isEmpty()) { pg.status->setStyleSheet("color:#c62828"); pg.status->setText("No API key entered and none in the environment."); return; }
        QString model = pg.model->currentText().trimmed(), base = baseFor(pg);
        QJsonObject body; QString url;
        if (pg.info.kind == "anthropic") {
            url = base + "/v1/messages";
            body = {{"model", model}, {"max_tokens", 16}, {"messages", QJsonArray{QJsonObject{{"role", "user"}, {"content", "Reply with: ok"}}}}};
        } else if (pg.info.kind == "gemini") {
            url = base + "/models/" + model + ":generateContent";
            body = {{"contents", QJsonArray{QJsonObject{{"role", "user"}, {"parts", QJsonArray{QJsonObject{{"text", "Reply with: ok"}}}}}}}};
        } else {
            url = base + "/chat/completions";
            body = {{"model", model}, {"messages", QJsonArray{QJsonObject{{"role", "user"}, {"content", "Reply with: ok"}}}}};
        }
        pg.status->setStyleSheet(""); pg.status->setText("Testing…");
        QElapsedTimer *t = new QElapsedTimer; t->start();
        auto *r = nam.post(makeReq(pg, url), QJsonDocument(body).toJson(QJsonDocument::Compact));
        connect(r, &QNetworkReply::finished, this, [=] {
            QByteArray data = r->isOpen() ? r->readAll() : QByteArray(); qint64 ms = t->elapsed(); delete t;
            if (r->error() == QNetworkReply::NoError) report(idx, r, true, QString("✔ Works (%1 ms, model %2)").arg(ms).arg(model));
            else report(idx, r, false, "✘ " + errorText(data, r) + (pg.info.keyless ? QString("\nIs the server running at %1?").arg(base) : QString()));
        });
    }

    void fetchModels(int idx) {
        auto &pg = pages[idx];
        QString base = baseFor(pg);
        QString url = pg.info.kind == "anthropic" ? base + "/v1/models" : base + "/models";
        pg.status->setStyleSheet(""); pg.status->setText("Fetching models…");
        auto *r = nam.get(makeReq(pg, url));
        connect(r, &QNetworkReply::finished, this, [=] {
            QByteArray data = r->isOpen() ? r->readAll() : QByteArray();
            if (r->error() != QNetworkReply::NoError) { report(idx, r, false, "✘ " + errorText(data, r)); return; }
            auto d = QJsonDocument::fromJson(data).object();
            QStringList ids;
            for (auto v : d["data"].toArray()) ids << v.toObject()["id"].toString();
            for (auto v : d["models"].toArray()) {
                auto o = v.toObject(); QString n = o["name"].toString();
                if (n.startsWith("models/")) n = n.mid(7);
                auto methods = o["supportedGenerationMethods"].toArray();
                if (methods.isEmpty() || methods.contains("generateContent")) ids << n;
            }
            ids.removeAll(""); ids.sort();
            QString cur = pages[idx].model->currentText();
            pages[idx].model->clear(); pages[idx].model->addItems(ids); pages[idx].model->setCurrentText(cur);
            report(idx, r, true, QString("✔ %1 models available").arg(ids.size()));
        });
    }
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setApplicationName("revvy-ai-config");
    ConfigWindow w;
    if (app.arguments().contains("--voice-trainer")) {
        return QProcess::startDetached(QStringLiteral("/usr/local/bin/revvy-ai-voice-trainer")) ? 0 : 1;
    }
    if (app.arguments().contains("--save-and-quit")) { w.saveNow(); return 0; }  // round-trip test / normalise file
    w.show();
    return app.exec();
}
