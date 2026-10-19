#!/usr/bin/env python3
"""Offline Vosk hotword listener for Revvy AI."""
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import time
from array import array

ROOT = os.environ.get("REVVY_AI_ROOT", "/opt/ttos/revvy-ai")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "revvy-ai", "config.json")
MODEL = os.path.join(ROOT, "voice-model", "vosk-model-small-en-us-0.15")
REVVY = os.environ.get("REVVY_AI_BIN", "/usr/local/bin/revvy-ai")
RATE = 16000
AUTO_SOURCE = "revvy_auto_mic"


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


def aliases(hotword, trained_aliases=()):
    phrase = normalized(hotword) or "hey revvy"
    values = {phrase}
    name = phrase[4:] if phrase.startswith("hey ") else phrase
    if name in {"revvy", "revy"}:
        # The small general-English model does not contain "Revvy". These
        # cover its common phonetic transcriptions of the spoken wake phrase.
        values.update({"hey revy", "hey ready", "hey riley", "hey ruby",
                       "hey remy", "hey ravi", "the red meat", "the remedy"})
    for candidate in trained_aliases:
        candidate = normalized(str(candidate))
        # A profile is local user data, but keep its aliases bounded so a
        # malformed config cannot turn arbitrary speech into a wake phrase.
        if 1 <= len(candidate.split()) <= 4:
            values.add(candidate)
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


def pactl(*args, json_output=False):
    """Run pactl without making a missing Pulse compatibility server fatal."""
    if not shutil.which("pactl"):
        return None
    command = ["pactl"]
    if json_output:
        command += ["-f", "json"]
    command += list(args)
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                check=False, timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    if json_output:
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return None
    return result.stdout.strip()


def actual_sources():
    """Return microphone-like Pulse sources, never a sink monitor."""
    sources = pactl("list", "sources", json_output=True) or []
    return [source for source in sources
            if source.get("name") and not source["name"].endswith(".monitor")]


def source_volume_percent(source):
    values = source.get("volume", {}).values()
    levels = []
    for value in values:
        match = re.match(r"(\d+)%", str(value.get("value_percent", "")))
        if match:
            levels.append(int(match.group(1)))
    return min(levels) if levels else 100


def first_alsa_capture_device():
    """Choose the first real capture PCM only when Pulse exposes no mic."""
    if not shutil.which("arecord"):
        return None
    try:
        listing = subprocess.run(["arecord", "-l"], capture_output=True, text=True,
                                 check=False, timeout=8).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.search(r"card (\d+):.*?device (\d+):", listing)
    return "hw:%s,%s" % match.groups() if match else None


def choose_microphone():
    """Ensure a physical capture source exists and make it Pulse's default.

    Some RevolutionUI logins restore an output-only card profile.  Pulse then
    exposes only an ``*.monitor`` source, which causes PortAudio's ALSA
    ``default`` device to record desktop audio instead of the microphone.
    A private module-alsa-source preserves the user's output profile while
    exposing the hardware capture PCM for Revvy.
    """
    sources = actual_sources()
    if not sources:
        device = first_alsa_capture_device()
        if device:
            module = pactl("load-module", "module-alsa-source", "device=" + device,
                           "source_name=" + AUTO_SOURCE)
            if module:
                log("created microphone source %s from %s" % (AUTO_SOURCE, device))
                for _ in range(20):
                    time.sleep(0.25)
                    sources = actual_sources()
                    if sources:
                        break
    if not sources:
        log("no physical microphone source is available; waiting for PipeWire")
        return None

    info = pactl("info", json_output=True) or {}
    default_name = info.get("default_source_name", "")
    source = next((item for item in sources if item["name"] == default_name), None)
    if source is None:
        # Prefer our capture source, then an actively-running real input.
        source = next((item for item in sources if item["name"] == AUTO_SOURCE), None)
        source = source or next((item for item in sources if item.get("state") == "RUNNING"), sources[0])
    name = source["name"]
    pactl("set-default-source", name)
    pactl("set-source-mute", name, "0")
    if source_volume_percent(source) < 80:
        pactl("set-source-volume", name, "85%")
    log("using microphone source: %s (unmuted; volume %s%%)" %
        (name, max(source_volume_percent(source), 80)))
    return name


def pulse_capture_device(sounddevice):
    """Use Pulse/PipeWire explicitly instead of PortAudio's ALSA default."""
    for index, device in enumerate(sounddevice.query_devices()):
        if device.get("max_input_channels", 0) < 1:
            continue
        if device.get("name", "").strip().lower() == "pulse":
            return index
    return None


def scale_pcm(data, gain):
    """Apply the trainer's small corrective gain to signed 16-bit PCM."""
    if gain <= 1.001:
        return data
    samples = array("h")
    samples.frombytes(data)
    if sys.byteorder != "little":
        samples.byteswap()
    for index, value in enumerate(samples):
        samples[index] = max(-32768, min(32767, int(value * gain)))
    if sys.byteorder != "little":
        samples.byteswap()
    return samples.tobytes()


def make_stream(sounddevice, device, gain=1.0):
    audio = queue.Queue(maxsize=48)

    def callback(indata, _frames, _time, status):
        if status:
            return
        try:
            audio.put_nowait(scale_pcm(bytes(indata), gain))
        except queue.Full:
            try:
                audio.get_nowait()
                audio.put_nowait(bytes(indata))
            except queue.Empty:
                pass
            except queue.Full:
                pass

    stream = sounddevice.RawInputStream(device=device, samplerate=RATE, blocksize=1600,
                                        dtype="int16", channels=1,
                                        callback=callback)
    return stream, audio


def listen_for_hotword(sounddevice, recognizer, variants, device, gain):
    stream, audio = make_stream(sounddevice, device, gain)
    with stream:
        while True:
            data = audio.get()
            if recognizer.AcceptWaveform(data):
                text = json.loads(recognizer.Result()).get("text", "")
            else:
                text = json.loads(recognizer.PartialResult()).get("partial", "")
            if hotword_in(text, variants):
                return


def capture_command(sounddevice, model, seconds, device, gain):
    from vosk import KaldiRecognizer
    recognizer = KaldiRecognizer(model, RATE)
    stream, audio = make_stream(sounddevice, device, gain)
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
    if len(sys.argv) == 2 and sys.argv[1] == "--prepare-microphone":
        return 0 if choose_microphone() else 1
    model = Model(MODEL)
    variants = aliases(str(cfg.get("hotword", "Hey Revvy!")),
                       cfg.get("hotwordAliases", []))
    if len(sys.argv) == 3 and sys.argv[1] == "--test-wav":
        return test_wav(sys.argv[2], model, variants)
    if not cfg.get("enabled", False):
        return 0
    microphone = choose_microphone()
    if microphone is None:
        # Do not terminate: audio hardware can appear after a late session
        # startup or USB hotplug. The retry loop below keeps the service alive.
        log("microphone setup will be retried until an input becomes available")
    log("listening for hotword: " + str(cfg.get("hotword", "Hey Revvy!")))
    try:
        gain = max(1.0, min(3.0, float(cfg.get("inputGain", 1.0))))
    except (TypeError, ValueError):
        gain = 1.0
    if gain > 1.001:
        log("using trained microphone gain: %.2fx" % gain)
    while True:
        try:
            if microphone is None:
                time.sleep(2)
                microphone = choose_microphone()
                continue
            device = pulse_capture_device(sounddevice)
            if device is None:
                raise RuntimeError("no Pulse/PipeWire capture device is available")
            recognizer = KaldiRecognizer(model, RATE)
            listen_for_hotword(sounddevice, recognizer, variants, device, gain)
            log("hotword detected; opening command window")
            animate("Processing")
            prompt = capture_command(sounddevice, model, cfg.get("commandSeconds", 8), device, gain)
            if prompt and dispatch(prompt):
                log("recognized a command; dispatched it to Revvy")
            else:
                log("no command recognized; returning to idle")
                animate("Idle")
            time.sleep(max(0, min(60, int(cfg.get("cooldownSeconds", 2)))))
        except Exception as error:
            log("audio or recognition error: " + str(error))
            microphone = None
            time.sleep(2)


if __name__ == "__main__":
    raise SystemExit(main())
