# Revvy AI — a QML/Quickshell desktop AI agent

A transparent, always-on-top animated character (Clippit + 9 other classic Agent characters)
that opens a speech bubble → search bar, asks an LLM, pastes the answer into the bubble word by
word while speaking it aloud and acting it out.

```bash
./scripts/revvy-ai --service  # start one resident Quickshell instance
./scripts/revvy-ai --agent-list
./scripts/revvy-ai --agent tux -a Wave -p "what's the weather?"
```
The default character is **Tux**; pick another from the right-click menu or
with `revvy-ai --agent NAME`. The command wrapper routes requests to the
resident service over Quickshell IPC and never opens a second assistant.
Requires: Quickshell ≥ 0.3 (Wayland layer-shell), Qt 6 with QtMultimedia, `espeak-ng` (voice; any
command works via `tts.command`). Click Clippy to ask, drag to move, right-click for brain/character menu.


## Using it
- **Move it anywhere** by dragging; the spot is remembered. Right-click -> *Reset position* (or **Reset widget position** in `clippy-ai-config`,
  or `clippy-ai-config --reset-position` from a terminal) re-centres it. It can't be dragged off-screen.
- **Above / below other windows**: right-click -> *Keep above windows* / *Keep below windows*. In "below" mode it rises just while you type a question.
- **What it can do** (works well even with tiny local models, thanks to a built-in intent router): weather for your current location or any city,
  the time, *find files* in your home folder, *open files* in their default app or a named one ("open my budget spreadsheet with libreoffice"),
  *launch programs* ("open firefox"), web search, and terminal commands (asks first).
- **Voice**: natural Piper voice when installed - see [`docs/VOICES.md`](docs/VOICES.md).
- **Compositor / app control** (RevolutionWM) is designed in [`docs/COMPOSITOR_API.md`](docs/COMPOSITOR_API.md); `qml/Desktop.qml` already speaks the protocol
  and `tests/mock_wm.py` is a reference server.

## Backends (right-click → Brain, or `provider` in config)
ChatGPT/OpenAI, Claude, Gemini, Grok, Meta Llama (Llama API), and **local** models via any
OpenAI-compatible server (Ollama default `localhost:11434`, llama.cpp, LM Studio). `auto` picks the
first with a key. Keys come from `~/.config/revvy-ai/config.json` or env vars
(`ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY XAI_API_KEY LLAMA_API_KEY`). Default model names
are in `qml/js/providers.js` — override in config (see `examples/config.json`).

## Tools now
time (any timezone), weather (wttr.in, no key), web search (DuckDuckGo), fetch web page, and
terminal (`run_terminal`, asks Allow/Deny by default). See `docs/FUTURE_API.md` for how
compositor/app control, alarms, mail, calendar and phone dialing plug in.

## Layout
- `shell.qml` – the only Quickshell-window-specific file (transparent centered layer-shell window, click-through mask, IPC).
- `qml/Assistant.qml` – drop this into any other Quickshell config as a widget.
- `qml/CharSprite.qml`, `Agent.qml` – ports of clippy.js Animator/Agent/Queue (branching, exit branching, idle, loops).
- `qml/VisualAgent.qml` – renderer-aware adapter. Sprite themes use `Agent.qml`; Circle AI uses its Canvas renderer without entering the sprite path.
- `qml/appearances/CircleAiAnimation.qml` – Circle AI renderer. It appears with a plug-in fade, animates only while processing/speaking, settles to a full ring, and hides after 20 seconds idle.
- `qml/Bubble.qml` – pop → search bar → thinking dots → answer → confirm.
- `qml/Brain.qml` + `qml/js/providers.js` – backend-agnostic tool-calling loop.
- `qml/Tools.qml`, `Speech.qml`, `Sys.qml` – tools, TTS, process layer.
- `themes/` – 10 classic Agent characters (from pithings/clippy) + Linux mascots Tux, Konqi (new & classic), Wilber, Larry; credits/licences in `themes/CREDITS.md`.
- `tools/mascots/build.py` – generates mascot themes from SVG/PNG art (Tux is rigged: wings, eyes, blink, beak).

Config reference: `examples/config.json`. Themes: `docs/THEMING.md`.

### Circle AI renderer

`circle-ai` is a built-in Revvy appearance, selectable exactly like a normal
agent: `revvy-ai --agent circle-ai --prompt "Hello"`, or set
`"theme": "circle-ai"` in `~/.config/revvy-ai/config.json`. It uses the
manifest renderer type rather than a sprite sheet, so classic agent themes and
their animations remain fully compatible. The initial appearance plug-in set
contains `fade`; future transitions can be declared in its manifest without
changing the request lifecycle.

## Configuration utility (C++/Qt)
```bash
cmake -S config-tool -B build -G Ninja && cmake --build build
./build/revvy-ai-config
```
Edits `~/.config/revvy-ai/config.json`: active backend, per-backend key/model/base URL
(with **Test connection** and **Fetch models**), terminal policy, character, size, voice, location.
Unknown keys are preserved and the file is written atomically with mode 0600.

## Building Debian packages
```bash
./build-debs.sh        # builds config tool + dist/*.deb (nothing is installed on the build machine)
```
| Package | Contents |
|---|---|
| `revvy-ai` | the program in `/opt/ttos/revvy-ai/`, launcher `/usr/local/bin/revvy-ai` (and `revvy-ai-config`), `.desktop` entries, icon |
| `revvy-ai-themes-free` | DFSG-free characters: Tux, Konqi, Konqi (classic), Wilber, Larry |
| `revvy-ai-themes-non-free` | Microsoft Agent characters (Clippit, Merlin, Bonzi, Genie, Genius, F1, Links, Peedy, Rocky, Rover) |

---

# Licenses and attributions

## This project
The program code (QML, JavaScript, C++ configuration utility, build scripts) is © its contributors and
licensed under the **GNU General Public License v3** (see [`LICENSE`](LICENSE)).

**The character artwork is NOT covered by the GPL.** Every theme's artwork, and the animation frames
derived from it, remain the property of the original artists and are licensed as listed below.
If you redistribute a theme you must follow *its* licence.

## Code and assets we build on
| Project | What we used | Licence |
|---|---|---|
| [pithings/clippy](https://github.com/pithings/clippy) (Copyright © 2012 Fireplace, Inc; © 2017 Pooya Parsa) | Animation engine design that `qml/CharSprite.qml` and `qml/Agent.qml` port to QML (animator, queue, branching / exit-branching, idle logic, balloon behaviour); the converted character data (`agent.json`), sprite maps and sounds of the ten Agent characters | MIT |
| [vchaindz/modern-clippy](https://github.com/vchaindz/modern-clippy) (© 2024 Dennis Zimmer, Codenotary, Inc.) | Sprite/loader design reference and the Clippy sprite-map layout | MIT |
| [Cosmo/Clippy](https://github.com/Cosmo/Clippy) | Reference for the Agent character format and state/branching concepts (no code copied) | no licence file in the repository |
| Microsoft Agent characters | The original artwork and sounds behind the ten classic characters | © Microsoft. **No free licence** — shipped only in `clippy-ai-themes-non-free`, personal / non-commercial use; redistribution rights are not cleared |

The MIT licence texts are in `themes/LICENCE-pithings-clippy.js` and `themes/LICENSE-modern-clippy.txt`.

## Classic Agent characters (`clippy-ai-themes-non-free`)
Clippit (`clippy`), Merlin, Bonzi, Genie, Genius, F1, Links, Peedy, Rocky and Rover — © Microsoft Corporation,
converted for the web by the MIT-licensed projects above.

## Linux mascot characters (`clippy-ai-themes-free`)
| Theme | Artwork | Artist(s) | Licence |
|---|---|---|---|
| `tux` | [Tux.svg](https://commons.wikimedia.org/wiki/File:Tux.svg) | Larry Ewing (original, made with The GIMP); SVG redraw by Garrett LeSage, cleaned up by IFo Hancroft; Simon Budig | Free to use and modify provided the artists are acknowledged |
| `konqi` | [KDE mascot Konqi](https://community.kde.org/Promo/Material/Mascots) | Tyson Tan | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| `konqi-classic` | [Konqi.svg](https://commons.wikimedia.org/wiki/File:Konqi.svg) | KDE artists (see the Commons page) | GPL (version not stated by the source) |
| `wilber` | [Gimp-wilber-scalable.svg](https://commons.wikimedia.org/wiki/File:Gimp-wilber-scalable.svg) — Wilber, the GIMP mascot | Matvizz (Wilber designed by Tuomas Kuosmanen) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) |
| `larry` | [Larry-the-cow-full.svg](https://commons.wikimedia.org/wiki/File:Larry-the-cow-full.svg) — Larry the Cow, Gentoo | Ethan Dunham, Matteo Pescarin | [CC BY-SA 2.5](https://creativecommons.org/licenses/by-sa/2.5/) |

The sprite sheets for these five were generated by `tools/mascots/build.py` (rigging Tux's layers, puppet-animating
the rest). They are adaptations of the art above and carry the same licence — including share-alike for Konqi
and Larry. Tux's SVG is also used as the application icon. Trademarks (Tux, KDE, Gentoo, GIMP) belong to their owners.

Tux acknowledgement, as requested by the artist: *Tux was created by Larry Ewing using The GIMP.*

## Third-party services used at runtime
[wttr.in](https://wttr.in) (weather), [DuckDuckGo](https://duckduckgo.com) HTML search, and whichever AI provider you
configure (OpenAI, Anthropic, Google, xAI, Meta, or a local server). Their terms apply to your use of them.
`espeak-ng` (GPL-3) is used for speech; Quickshell (LGPL-3) and Qt (LGPL-3 / GPL) provide the runtime.

**Original licence texts** are in [`licenses/`](licenses/), and every theme folder contains an `ATTRIBUTION.md` (artist, original source URL, licence, what was changed) plus a copy of its original licence. The original source art is kept in `tools/mascots/art/` (see its README).

If your work is missing from this list or credited incorrectly, please open an issue and it will be fixed.
