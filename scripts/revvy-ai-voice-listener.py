#!/usr/bin/env python3
"""Offline Vosk hotword listener for Revvy AI."""
import json
import os
import queue
import re
import subprocess
import sys
import time

ROOT = os.environ.get("REVVY_AI_ROOT", "/opt/ttos/revvy-ai")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "revvy-ai", "config.json")
MODEL = os.path.join(ROOT, "voice-model", "vosk-model-small-en-us-0.15")
REVVY = os.environ.get("REVVY_AI_BIN", "/usr/local/bin/revvy-ai")
RATE = 16000


def log(message):
    print("revvy-ai-voice: " + message, file=sys.stderr, flush=True)


def normalized(value):
    return " ".join(re.sub(r"[^a-z ]+", " ", value.lower()).split())


def settings():
    values = {"enabled": False, "hotword": "Hey Revvy!", "commandSeconds": 8,
              "cooldownSeconds": 2}
    try:
        with open(CONFIG, encoding="utf-8") as source:
            values.update(json.load(source).get("speechRecognition", {}))
    except Exception:
        pass
    return values


def aliases(hotword):
    phrase = normalized(hotword) or "hey revvy"
    values = {phrase}
    name = phrase[4:] if phrase.startswith("hey ") else phrase
    if name in {"revvy", "revy"}:
        # The small general-English model does not contain "Revvy". These
        # cover its common phonetic transcriptions of the spoken wake phrase.
        values.update({"hey revy", "hey ready", "hey riley", "hey ruby",
                       "hey remy", "hey ravi", "the red meat", "the remedy"})
    return values


def hotword_in(text, variants):
    phrase = normalized(text)
    return any(variant and variant in phrase for variant in variants)


def animate(name):
    subprocess.run([REVVY, "-a", name], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)


def dispatch(prompt):
    return subprocess.run([REVVY, "-p", prompt], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, check=False).returncode == 0


def make_stream(sounddevice):
    audio = queue.Queue(maxsize=48)

    def callback(indata, _frames, _time, status):
        if status:
            return
        try:
            audio.put_nowait(bytes(indata))
        except queue.Full:
            try:
                audio.get_nowait()
                audio.put_nowait(bytes(indata))
            except queue.Empty:
                pass
            except queue.Full:
                pass

    stream = sounddevice.RawInputStream(samplerate=RATE, blocksize=1600,
                                        dtype="int16", channels=1,
                                        callback=callback)
    return stream, audio


def listen_for_hotword(sounddevice, recognizer, variants):
    stream, audio = make_stream(sounddevice)
    with stream:
        while True:
            data = audio.get()
            if recognizer.AcceptWaveform(data):
                text = json.loads(recognizer.Result()).get("text", "")
            else:
                text = json.loads(recognizer.PartialResult()).get("partial", "")
            if hotword_in(text, variants):
                return


def capture_command(sounddevice, model, seconds):
    from vosk import KaldiRecognizer
    recognizer = KaldiRecognizer(model, RATE)
    stream, audio = make_stream(sounddevice)
    deadline = time.monotonic() + max(2, min(30, int(seconds)))
    pieces = []
    with stream:
        while time.monotonic() < deadline:
            try:
                data = audio.get(timeout=0.25)
            except queue.Empty:
                continue
            if recognizer.AcceptWaveform(data):
                text = json.loads(recognizer.Result()).get("text", "").strip()
                if text:
                    pieces.append(text)
    final = json.loads(recognizer.FinalResult()).get("text", "").strip()
    if final:
        pieces.append(final)
    return " ".join(pieces).strip()


def test_wav(path, model, variants):
    import wave
    from vosk import KaldiRecognizer
    with wave.open(path, "rb") as source:
        recognizer = KaldiRecognizer(model, source.getframerate())
        pieces = []
        while True:
            data = source.readframes(4000)
            if not data:
                break
            if recognizer.AcceptWaveform(data):
                pieces.append(json.loads(recognizer.Result()).get("text", ""))
        pieces.append(json.loads(recognizer.FinalResult()).get("text", ""))
    text = " ".join(piece for piece in pieces if piece).strip()
    print(text)
    return 0 if hotword_in(text, variants) else 1


def main():
    try:
        import sounddevice
        from vosk import Model, KaldiRecognizer, SetLogLevel
    except Exception as error:
        log("Vosk runtime unavailable: " + str(error))
        return 1
    if not os.path.isdir(MODEL):
        log("Vosk English model is unavailable")
        return 1
    SetLogLevel(-1)
    cfg = settings()
    if not cfg.get("enabled", False):
        return 0
    model = Model(MODEL)
    variants = aliases(str(cfg.get("hotword", "Hey Revvy!")))
    if len(sys.argv) == 3 and sys.argv[1] == "--test-wav":
        return test_wav(sys.argv[2], model, variants)
    log("listening for hotword: " + str(cfg.get("hotword", "Hey Revvy!")))
    while True:
        try:
            recognizer = KaldiRecognizer(model, RATE)
            listen_for_hotword(sounddevice, recognizer, variants)
            log("hotword detected; opening command window")
            animate("Processing")
            prompt = capture_command(sounddevice, model, cfg.get("commandSeconds", 8))
            if prompt and dispatch(prompt):
                log("recognized a command; dispatched it to Revvy")
            else:
                log("no command recognized; returning to idle")
                animate("Idle")
            time.sleep(max(0, min(60, int(cfg.get("cooldownSeconds", 2)))))
        except Exception as error:
            log("audio or recognition error: " + str(error))
            time.sleep(2)


if __name__ == "__main__":
    raise SystemExit(main())
