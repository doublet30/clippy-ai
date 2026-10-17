# Themes

The default theme is **tux** (shipped in `clippy-ai-themes-free`). If the configured theme isn't installed the first installed one is used.

A theme is a folder with `agent.json`, `map.png` (sprite sheet) and optional `sounds/<n>.mp3`.
Built-in: clippy, bonzi, f1, genie, genius, links, merlin, peedy, rocky, rover (`themes/`).
Drop your own in `~/.config/clippy-ai/themes/<name>/` and pick it from the right-click menu
(or `"theme"` in config.json).

`agent.json` format (clippy.js format):
```json
{ "framesize": [124, 93], "overlayCount": 1, "sounds": ["1"],
  "animations": { "Wave": { "useExitBranching": false, "frames": [
     { "duration": 100, "images": [[x, y]], "sound": "1",
       "branching": { "branches": [{ "frameIndex": 3, "weight": 50 }] }, "exitBranch": 5 } ] } } }
```
The assistant looks for animations by name and degrades gracefully if missing:
`Show Greeting GetAttention Thinking Processing Searching CheckingSomething Writing GetTechy
Explain GestureLeft/Right/Up/Down Alert Congratulate RestPose Idle* Look*`.

## High-resolution (vector) themes
Add `"sheetScale": 2` to agent.json when the sheet was drawn at 2 sheet-pixels per logical pixel
(`framesize` stays in logical px). The sprite is then drawn smoothed instead of pixel-sharp.
`tools/mascots/build.py` generates such themes from SVG/PNG art (Tux is rigged from its layers;
the others use squash/stretch/tilt puppetry). Add a mascot by dropping art in `tools/mascots/art/`
and an entry in `MASCOTS`.
