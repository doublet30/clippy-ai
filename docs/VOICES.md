# Speech

Answers are spoken with **Piper** (neural, natural) when available and fall back to **espeak-ng**.

## Piper
* Binary: found automatically (`tts.piper.binary`, `~/.local/share/clippy-ai/piper/piper`, `/opt/ttos/clippy-ai/piper/piper`, ...). It must run (`piper --help`).
* Voices: put `<name>.onnx` + `<name>.onnx.json` in `~/.local/share/clippy-ai/voices/`
  (from <https://huggingface.co/rhasspy/piper-voices>, MIT-licensed). Male voices are preferred, most natural first:
  `en_US-ryan-medium`, `en_US-ryan-high`, `en_US-joe-medium`, `en_GB-alan-medium`, `en_US-hfc_male-medium`, ...
* **Speed check**: each voice is benchmarked once (cache: `~/.local/state/clippy-ai/tts-bench.txt`). A voice slower than
  0.9x real time is skipped so speech never stutters. On a slow CPU use a *medium* or *low* voice
  (e.g. an i5-3320M runs ryan-medium at 0.44x but ryan-high at 2.6x). Delete the cache file to re-measure.
* Force a voice: `"tts": {"piper": {"model": "/path/voice.onnx", "speed": 1.1}}`.

## Fallbacks
`"engine": "espeak"` (robotic, always available), or `"engine": "custom"` with `"command": ["my-tts", "{text}"]`.
Mute from the right-click menu or `"tts": {"enabled": false}`.
