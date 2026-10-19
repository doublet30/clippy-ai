#!/usr/bin/env python3
"""Local voice calibration and wake-phrase training for Revvy AI."""
import json
import math
import os
import re
import subprocess
import sys
import time
from array import array
from datetime import datetime, timezone
from difflib import SequenceMatcher

from PyQt6.QtCore import QTimer, Qt
from PyQt6.QtWidgets import (
    QApplication, QHBoxLayout, QLabel, QLineEdit, QMainWindow, QMessageBox,
    QPushButton, QVBoxLayout, QWidget,
)

import sounddevice
from vosk import KaldiRecognizer, Model, SetLogLevel

ROOT = os.environ.get("REVVY_AI_ROOT", "/opt/ttos/revvy-ai")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
                      "revvy-ai", "config.json")
MODEL = os.path.join(ROOT, "voice-model", "vosk-model-small-en-us-0.15")
LISTENER = os.path.join(ROOT, "bin", "revvy-ai-voice-listener")
RATE = 16000
MAX_SECONDS = 22

WAKE_REPETITIONS = 3


def display_hotword(value):
    """Return the configured phrase in a form suitable for a spoken prompt."""
    phrase = str(value or "").strip()
    phrase = phrase.rstrip(".!? ")
    return phrase or "Hey Revvy"


def passages_for(hotword):
    """Build a local calibration script for the user's *current* wake phrase.

    Vosk's compact model may spell a custom name phonetically.  The dedicated
    repetitions intentionally let the trainer collect that decoder rendering
    before it evaluates the longer command examples.
    """
    phrase = display_hotword(hotword)
    passages = []
    for number in range(1, WAKE_REPETITIONS + 1):
        passages.append({
            "title": "Wake phrase calibration %d" % number,
            "text": phrase,
            "anchors": (),
            "wake": True,
            "wakeSample": True,
        })
    passages.extend((
        {
            "title": "Wake phrase and weather",
            "text": "%s! What's the weather forecast for today?" % phrase,
            "anchors": ("what", "weather", "forecast", "today"),
            "wake": True,
        },
        {
            "title": "Wake phrase and launching",
            "text": "%s! Launch wordcraft!" % phrase,
            "anchors": ("launch", "wordcraft"),
            "wake": True,
        },
        {
            "title": "Wake phrase and a detailed request",
            "text": ("%s! Attach the document demoReport.docx to a new email "
                     "and send it to johndoe@gmail.com") % phrase,
            "anchors": ("attach", "document", "email", "send"),
            "wake": True,
        },
        {
            "title": "Phonetic coverage",
            "text": "The quick brown fox jumps over the lazy dog.",
            "anchors": (),
            "wake": False,
        },
    ))
    return tuple(passages)


def normalized(value):
    return " ".join(re.sub(r"[^a-z0-9 ]+", " ", value.lower()).split())


def read_config():
    try:
        with open(CONFIG, encoding="utf-8") as source:
            return json.load(source)
    except (OSError, json.JSONDecodeError):
        return {}


def save_config(data):
    folder = os.path.dirname(CONFIG)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    temporary = CONFIG + ".tmp"
    with open(temporary, "w", encoding="utf-8") as target:
        os.chmod(temporary, 0o600)
        json.dump(data, target, indent=2, sort_keys=True)
        target.write("\n")
    os.replace(temporary, CONFIG)


def run_systemctl(*args):
    return subprocess.run(["systemctl", "--user", *args], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, check=False).returncode


def pulse_device():
    for index, device in enumerate(sounddevice.query_devices()):
        if device.get("max_input_channels", 0) > 0 and \
                device.get("name", "").strip().lower() == "pulse":
            return index
    return None


def pcm_metrics(data):
    samples = array("h")
    samples.frombytes(data)
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        return 0.0, 0.0
    squared = sum(value * value for value in samples)
    rms = math.sqrt(squared / len(samples)) / 32768.0
    peak = max(abs(value) for value in samples) / 32768.0
    return rms, peak


def transcribe(model, data):
    recognizer = KaldiRecognizer(model, RATE)
    step = RATE * 2 // 5  # 400 ms of 16-bit mono PCM
    pieces = []
    for offset in range(0, len(data), step):
        if recognizer.AcceptWaveform(data[offset:offset + step]):
            text = json.loads(recognizer.Result()).get("text", "").strip()
            if text:
                pieces.append(text)
    final = json.loads(recognizer.FinalResult()).get("text", "").strip()
    if final:
        pieces.append(final)
    return " ".join(pieces).strip()


def similarity(expected, actual):
    return SequenceMatcher(None, normalized(expected), normalized(actual)).ratio()


def wake_alias(transcript, passage):
    """Extract a safe, user-specific transcription of the wake phrase."""
    if not passage["wake"]:
        return ""
    words = normalized(transcript).split()
    if passage.get("wakeSample"):
        return " ".join(words[:5]) if words else ""
    positions = [words.index(anchor) for anchor in passage["anchors"] if anchor in words]
    if positions:
        alias = " ".join(words[:min(positions)])
    else:
        # Command-anchor words are sometimes missed even when the wake phrase
        # was decoded.  This recording was explicitly made for calibration, so
        # retain a short prefix for review instead of silently losing it.
        alias = " ".join(words[:min(5, len(words))])
    return alias if 1 <= len(alias.split()) <= 5 else ""


class TrainerWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Revvy AI Voice Calibration")
        self.setMinimumSize(720, 460)
        self.index = 0
        self.samples = []
        self.frames = bytearray()
        self.stream = None
        self.current = None
        self.started = 0.0
        self.timer = QTimer(self)
        self.timer.setInterval(100)
        self.timer.timeout.connect(self.refresh_clock)
        self.config = read_config()
        speech = self.config.get("speechRecognition", {})
        self.hotword = display_hotword(speech.get("hotword", "Hey Revvy!"))
        self.passages = passages_for(self.hotword)
        self.speech_enabled = bool(speech.get("enabled", False))
        self.listener_was_active = run_systemctl("is-active", "--quiet",
                                                 "revvy-ai-voice.service") == 0

        # Training must never turn spoken passages into real AI requests.
        if self.listener_was_active:
            run_systemctl("stop", "revvy-ai-voice.service")
        subprocess.run([LISTENER, "--prepare-microphone"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)

        SetLogLevel(-1)
        self.model = Model(MODEL)
        self.build_ui()
        self.show_passage()

    def build_ui(self):
        content = QWidget(self)
        layout = QVBoxLayout(content)
        layout.setSpacing(14)
        self.step = QLabel()
        self.step.setStyleSheet("font-size: 16px; font-weight: 600;")
        self.title = QLabel()
        self.title.setStyleSheet("font-size: 22px; font-weight: 700;")
        self.passage = QLabel()
        self.passage.setWordWrap(True)
        self.passage.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.passage.setStyleSheet(
            "font-size: 20px; line-height: 1.4; padding: 20px; "
            "border-radius: 12px; background: palette(alternate-base);"
        )
        self.instructions = QLabel(
            "Revvy’s live listener is suspended while calibration runs. Speak normally, at a "
            "comfortable volume, then click Finish recording. Raw audio is analyzed "
            "locally and discarded; only local decoder aliases and level calibration are saved."
        )
        self.instructions.setWordWrap(True)
        self.status = QLabel()
        self.status.setWordWrap(True)
        self.status.setStyleSheet("color: palette(mid);")
        self.alias_label = QLabel("Revvy heard the wake phrase as:")
        self.alias = QLineEdit()
        self.alias.setToolTip(
            "This is the local speech decoder's spelling of the phrase you just read. "
            "Keeping that spelling lets Revvy recognize your pronunciation even when a "
            "custom name is not in its built-in vocabulary."
        )
        self.alias_label.hide()
        self.alias.hide()
        controls = QHBoxLayout()
        self.record = QPushButton("Start recording")
        self.finish = QPushButton("Finish recording")
        self.next = QPushButton("Use this recording")
        self.finish.setEnabled(False)
        self.next.setEnabled(False)
        self.record.clicked.connect(self.start_recording)
        self.finish.clicked.connect(self.finish_recording)
        self.next.clicked.connect(self.advance)
        controls.addWidget(self.record)
        controls.addWidget(self.finish)
        controls.addStretch()
        controls.addWidget(self.next)
        layout.addWidget(self.step)
        layout.addWidget(self.title)
        layout.addWidget(self.passage)
        layout.addWidget(self.instructions)
        layout.addWidget(self.status)
        layout.addWidget(self.alias_label)
        layout.addWidget(self.alias)
        layout.addStretch()
        layout.addLayout(controls)
        self.setCentralWidget(content)

    def show_passage(self):
        passage = self.passages[self.index]
        self.step.setText("Passage %d of %d" % (self.index + 1, len(self.passages)))
        self.title.setText(passage["title"])
        self.passage.setText("“%s”" % passage["text"])
        self.status.setText("Ready to record.")
        self.alias.clear()
        self.alias_label.setVisible(bool(passage["wake"]))
        self.alias.setVisible(bool(passage["wake"]))
        if passage["wake"]:
            self.alias.setPlaceholderText("Record the phrase to see its local decoder alias")
        self.record.setEnabled(True)
        self.finish.setEnabled(False)
        self.next.setEnabled(False)

    def start_recording(self):
        if run_systemctl("is-active", "--quiet", "revvy-ai-voice.service") == 0:
            QMessageBox.critical(
                self, "Live listener still active",
                "The live Revvy listener could not be suspended. Training will not "
                "record while it might send spoken passages as AI requests."
            )
            return
        device = pulse_device()
        if device is None:
            QMessageBox.critical(self, "Microphone unavailable",
                                 "No Pulse/PipeWire input device is available. "
                                 "Check your microphone and try again.")
            return
        self.frames = bytearray()
        try:
            self.stream = sounddevice.RawInputStream(
                device=device, samplerate=RATE, blocksize=1600,
                dtype="int16", channels=1, callback=self.collect_audio,
            )
            self.stream.start()
        except Exception as error:
            self.stream = None
            QMessageBox.critical(self, "Recording failed", str(error))
            return
        self.started = time.monotonic()
        self.timer.start()
        self.record.setEnabled(False)
        self.finish.setEnabled(True)
        self.status.setText("Recording… read the passage, then click Finish recording.")

    def collect_audio(self, indata, _frames, _time, status):
        if not status:
            self.frames.extend(bytes(indata))

    def refresh_clock(self):
        elapsed = time.monotonic() - self.started
        if elapsed >= MAX_SECONDS:
            self.finish_recording()
            return
        self.status.setText("Recording… %0.1f seconds (maximum %d seconds)." %
                            (elapsed, MAX_SECONDS))

    def finish_recording(self):
        if self.stream is None:
            return
        self.timer.stop()
        self.stream.stop()
        self.stream.close()
        self.stream = None
        data = bytes(self.frames)
        self.finish.setEnabled(False)
        self.record.setEnabled(True)
        if len(data) < RATE * 2 * 2:
            self.status.setText("That sample was too short. Please record at least two seconds.")
            return
        passage = self.passages[self.index]
        transcript = transcribe(self.model, data)
        score = similarity(passage["text"], transcript)
        rms, peak = pcm_metrics(data)
        self.current = {
            "expected": passage["text"],
            "transcript": transcript,
            "similarity": round(score, 3),
            "rms": round(rms, 4),
            "peak": round(peak, 4),
            "hotwordAlias": wake_alias(transcript, passage),
            "wakeSample": bool(passage.get("wakeSample")),
        }
        quality = "Good" if score >= 0.45 else "Needs another try"
        level = "quiet" if rms < 0.025 else ("loud" if peak > 0.98 else "good")
        if passage["wake"]:
            self.alias.setText(self.current["hotwordAlias"])
            alias_note = ("Revvy will use the decoder spelling above as a local wake alias. "
                          "That is expected for a custom name or accent.")
        else:
            alias_note = "You can retry the passage or use this recording."
        self.status.setText(
            "%s match (%d%%); input level: %s. Recognized: “%s”\n%s" %
            (quality, round(score * 100), level, transcript or "nothing", alias_note)
        )
        # A non-empty, audible sample is a successful read. Recognition score
        # is shown as coaching rather than becoming a dead-end for accents or
        # an unfamiliar app name such as Wordcraft.
        self.next.setEnabled(bool(transcript) and rms >= 0.01)

    def advance(self):
        if self.current is None:
            return
        passage = self.passages[self.index]
        if passage["wake"]:
            alias = normalized(self.alias.text())
            if not alias:
                QMessageBox.warning(
                    self, "Wake phrase not heard",
                    "Revvy needs a non-empty local decoder alias for this wake phrase. "
                    "Please retry this short recording."
                )
                return
            self.current["hotwordAlias"] = alias
        self.samples.append(dict(self.current))
        self.index += 1
        if self.index < len(self.passages):
            self.show_passage()
            return
        self.finish_training()

    def finish_training(self):
        aliases = []
        for sample in self.samples:
            alias = normalized(sample.get("hotwordAlias", ""))
            if alias and alias not in aliases:
                aliases.append(alias)
        # Use the newest on-disk config so a settings save during calibration
        # cannot be overwritten with an old in-memory copy.  Profiles are
        # keyed by phrase so aliases learned for a prior hotword are never
        # reused accidentally after the user changes it.
        current_config = read_config()
        speech = current_config.get("speechRecognition", {})
        profile_key = normalized(self.hotword)
        profiles = speech.get("voiceProfiles", {})
        profiles = dict(profiles) if isinstance(profiles, dict) else {}
        existing_profile = profiles.get(profile_key, {})
        existing = existing_profile.get("aliases", []) if isinstance(existing_profile, dict) else []
        aliases = list(dict.fromkeys(
            [normalized(alias) for alias in existing + aliases if normalized(alias)]
        ))[:16]
        levels = sorted(sample["rms"] for sample in self.samples if sample["rms"] > 0.003)
        median = levels[len(levels) // 2] if levels else 0.10
        # Only raise quiet input. Do not lower a working microphone or amplify
        # it beyond a modest, clipped-safe 3× corrective gain.
        gain = round(max(1.0, min(3.0, 0.12 / max(median, 0.01))), 2)
        profile = {
            "version": 2,
            "trainedAt": datetime.now(timezone.utc).isoformat(),
            "hotword": self.hotword,
            "aliases": aliases,
            "inputGain": gain,
            "samples": self.samples,
            "averageSimilarity": round(sum(item["similarity"] for item in self.samples) /
                                       len(self.samples), 3),
            "rawAudioStored": False,
        }
        profiles[profile_key] = profile
        speech["voiceProfiles"] = profiles
        active_hotword = display_hotword(speech.get("hotword", self.hotword))
        if normalized(active_hotword) == profile_key:
            # Keep these compatibility fields for the listener installed by
            # earlier Revvy packages, while newer versions select the keyed
            # profile above.
            speech["hotwordAliases"] = aliases
            speech["inputGain"] = gain
            speech["trainedHotword"] = self.hotword
            speech["voiceProfile"] = profile
        current_config["speechRecognition"] = speech
        self.config = current_config
        save_config(current_config)
        self.resume_listener()
        QMessageBox.information(
            self, "Voice calibration complete",
            "Revvy saved %d local wake-phrase alias(es) and a microphone level "
            "calibration. The listener has restarted with them. No raw recording "
            "was retained." % len(aliases)
        )
        self.close()

    def resume_listener(self):
        if bool(read_config().get("speechRecognition", {}).get("enabled", self.speech_enabled)):
            run_systemctl("start", "revvy-ai-voice.service")

    def closeEvent(self, event):
        if self.stream is not None:
            self.timer.stop()
            self.stream.stop()
            self.stream.close()
            self.stream = None
        self.resume_listener()
        event.accept()


def main():
    if not os.path.isdir(MODEL):
        print("Revvy AI voice model is unavailable.", file=sys.stderr)
        return 1
    app = QApplication(sys.argv)
    window = TrainerWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
