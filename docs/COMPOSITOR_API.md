# RevolutionWM agent API (design, v1 draft)

Goal: let the desktop agent see and control windows and applications — set alarms, add calendar events,
send mail, open a word processor and write a document, drive Blender, ... — through **one stable contract**
implemented by both **RevolutionWM-wayland** (KWin fork) and **RevolutionWM-x11**, without rewriting the agent
when new capabilities appear.

Status: **design only.** The agent side (`qml/Desktop.qml`) already speaks the protocol and auto-registers whatever
tools the window manager advertises; `tests/mock_wm.py` is a reference server. Nothing here needs the compositor
to exist yet.

## 1. Principles

1. **One contract, two backends.** Same method names/shapes on X11 and Wayland. Differences are expressed as
   *capabilities*, never as different APIs.
2. **Self-describing.** The WM publishes a catalogue of tools (JSON-Schema, like MCP). The agent imports the catalogue;
   a new window action, or an app publishing a new action, needs **no agent change**.
3. **Semantic before pixel.** Prefer, in order: (a) an app's own actions (`app.*`), (b) the accessibility tree (`ui.*`),
   (c) raw keyboard/pointer injection. Blender gets "run this Python", not mouse-clicks.
4. **The compositor is the policy point.** It enforces scopes, consent, rate limits and audit — not the agent, and not the model.
5. **Small models first.** Every tool has a short description, flat arguments, and returns short text. Window ids are opaque
   strings (`w12`), never raw pointers or X11 ids.
6. **Versioned & additive.** `protocol` integer in `hello`; new fields/methods only added, never repurposed.

## 2. Transport

Newline-delimited **JSON-RPC 2.0** over a Unix stream socket: `$XDG_RUNTIME_DIR/revolution/agent.sock` (mode 0600).

* Usable from QML (`Quickshell.Io.Socket`), Python, C++/Qt, shell (`socat`). No D-Bus binding needed in QML.
* Server → client **notifications** carry events: `{"jsonrpc":"2.0","method":"event","params":{"type":"window.added","data":{...}}}`.
* A D-Bus mirror (`org.revolution.Agent1`, same methods, JSON strings) may be added for non-QML clients; the socket is canonical.

```
→ {"jsonrpc":"2.0","id":1,"method":"hello","params":{"client":"clippy-ai","protocol":1}}
← {"jsonrpc":"2.0","id":1,"result":{"server":"revolutionwm","backend":"wayland","protocol":1,
     "capabilities":["windows.read","windows.manage","ui.read","ui.input","ui.screenshot","app.actions"]}}
→ {"jsonrpc":"2.0","id":2,"method":"tools.list"}
← {"jsonrpc":"2.0","id":2,"result":[{"name":"windows_list","description":"...","parameters":{...},"scope":"windows.read"}, ...]}
→ {"jsonrpc":"2.0","id":3,"method":"tools.call","params":{"name":"windows_list","args":{}}}
← {"jsonrpc":"2.0","id":3,"result":"w12  Firefox  maximized  1600x900+0+0\nw15  Konsole  ..."}
```

## 3. Window model

Window id: opaque string `w<N>`, stable for the window's lifetime, unique per session.

| Property | Type | Notes |
|---|---|---|
| `id` | string | `w12` |
| `title` | string | |
| `app_id` | string | desktop-file id / Wayland app_id / X11 `WM_CLASS` |
| `pid` | int | |
| `geometry` | `{x,y,w,h}` | frame geometry, logical px, global coordinates |
| `output` | string | monitor name (`DP-1`) |
| `workspace` | int | -1 = all workspaces |
| `state` | set | `active maximized maximized_h maximized_v minimized fullscreen shaded sticky keep_above keep_below urgent modal` |
| `role` | enum | `normal dialog utility splash dock desktop popup` |
| `transient_for` | string? | parent window id |
| `opacity` | 0..1 | |
| `caps` | set | what is allowed *for this window*: `move resize close minimize maximize fullscreen keep_above set_output` |
| `secure` | bool | password prompt / lock screen / polkit: **never exposed in detail, never screenshotted, no input** |

### Methods (all also reachable as tools, §6)

```
windows.list(filter?{app_id,title~,workspace,output,state})  -> [Window]
windows.get(id)                                               -> Window
windows.activate(id) / raise(id) / lower(id) / close(id)
windows.set_state(id, {maximized?, maximized_h?, maximized_v?, minimized?, fullscreen?, shaded?, sticky?, keep_above?, keep_below?})
windows.move_resize(id, {x?, y?, w?, h?, output?})
windows.place(id, placement)   // semantic: left_half right_half top_half bottom_half top_left top_right bottom_left bottom_right center
                               //           maximize restore cascade smart(next free spot) ; optional {output}
windows.set_workspace(id, n) / windows.set_opacity(id, v)
windows.wait_for(filter, timeout_ms)                          -> Window | error timeout   // after launching an app
outputs.list()      -> [{name, geometry, scale, primary}]
workspaces.list()   -> [{id, name, active}] ; workspaces.switch(id)
apps.launch({desktop_id | argv, env?, place?, output?})       -> {startup_id}            // + windows.wait_for to get the window
```

### Events (notifications)
`window.added|removed|changed{id, changed:[props]}`, `window.active{id}`, `output.changed`, `workspace.changed`,
`ui.dialog_opened{window,title}`, `app.event{app_id,name,data}`, `consent.revoked`.

Events let the agent react ("the alarm window appeared", "the download finished dialog opened").

### Backend notes

| | RevolutionWM-wayland (KWin fork) | RevolutionWM-x11 |
|---|---|---|
| State/geometry | KWin `Window` API (`frameGeometry`, `setMaximize`, `keepAbove`, ...) from a built-in plugin | EWMH `_NET_WM_STATE`, `_NET_MOVERESIZE_WINDOW`, `_NET_ACTIVE_WINDOW`; XRandR for outputs |
| Clients self-position? | No - compositor decides, so `move_resize` always works for normal windows | Yes, but the WM may move any window |
| Input injection | compositor-side only (libei / `org.kde.KWin.FakeInput` style), scoped to the target window | XTEST. **Cannot be gated against other X clients** - documented limitation of X11 |
| Screenshots | compositor screenshot with per-window crop; `secure` windows excluded | XComposite `GetImage` per window |
| Window list without the plugin | `wlr-foreign-toplevel` (read-only) via Quickshell `ToplevelManagement` - a v0 fallback | `_NET_CLIENT_LIST` |

Capabilities in `hello` say what the running backend supports (e.g. `ui.input` may be absent on a locked-down session).

## 4. UI interaction (`ui.*`)

Per-window automation, three sources, tried in order and merged into one node model:

1. **App actions** (`app.*`) - apps that integrate publish *typed actions* (below).
2. **Accessibility tree** - Qt (QAccessible) and GTK via AT-SPI (`org.a11y.Bus`); the WM maps AT-SPI objects to window ids.
3. **Synthetic input** - keyboard/pointer into the window when neither exists.

Node (`ui_tree` / `ui_find` results):
```
{ "ref":"w12/3.1.4", "role":"button|textfield|checkbox|menu|menuitem|tab|list|listitem|table|cell|label|image|dialog|document",
  "name":"Save", "value":"...", "states":["enabled","focused","checked"], "bounds":{x,y,w,h},   // window-relative
  "actions":["click","focus","toggle","expand","select","set_value","scroll_to"], "children":[...] }
```
`ref`s are only valid until the next `window.changed`; tools return fresh refs.

```
ui.tree(window, {depth?=3, filter?})            -> compact outline (text for LLMs, JSON on request)
ui.find(window, {role?, name?, text?})          -> [Node]
ui.do(ref, action, {value?})                    -> ok | error
ui.type_text(window | ref, text)                // focuses the node, types (IME-safe)
ui.send_keys(window, "ctrl+s")                  // chords & sequences: "ctrl+a, delete"
ui.click(window, {x,y,button?,count?}) / ui.drag / ui.scroll
ui.screenshot(window | output | region, {max_px?})  -> image (for vision models)
ui.wait_for(window, query, timeout_ms)
clipboard.get() / clipboard.set(text)           // separate scope, always confirm on get
```

### App actions (`app.*`) — the MCP-like bit
Apps expose actions via D-Bus `org.revolution.AppControl1` on their own bus name; the WM aggregates them:
```
app.list()                              -> [{app_id, actions:[{name, description, parameters(JSON Schema), dangerous?}]}]
app.invoke(app_id, name, args)          -> result
```
Examples: `writer.insert_text{text}`, `writer.save_as{path}`, `calendar.create_event{title,start,end,reminder}`,
`mail.compose{to,subject,body,send:false}`, `blender.run_python{code}`, `clock.set_alarm{time,label,repeat}`.
Apps without integration are still reachable through `ui.*`.

## 5. Safety model (enforced by the compositor)

* **Scopes**: `windows.read`, `windows.manage`, `ui.read`, `ui.input`, `ui.screenshot`, `clipboard.read`, `clipboard.write`,
  `app.<app_id>.<action>`. The user grants per client and per app; defaults: read-only.
* **Confirm classes**: destructive or outward-facing calls (close window, send mail, delete, run python, clipboard read, anything
  in a window titled like a sign-in/payment page) return `{"confirm":"Send mail to bob@x.com?","token":"c93..."}`.
  The client shows its Allow/Deny bubble and repeats the call with `confirm_token`. Tokens are single-use and bound to the exact call.
* **Secure windows** (password fields, lock screen, polkit/sudo prompts, banking pages flagged by app) are invisible to `ui.*` and screenshots.
* **Visible control**: while the agent drives input the compositor shows a border/indicator and the user can abort with a
  global shortcut (default `Super+Esc`), which revokes the session (`consent.revoked`).
* **Rate limits & audit**: per-client limits; every call logged to `$XDG_STATE_HOME/revolution/agent-audit.jsonl`.
* **Untrusted content**: window titles, page text and AI-visible UI labels are *data*. The agent must never treat them as instructions
  (prompt-injection), and tool results are length-capped.

## 6. Agent-facing tool catalogue (what `tools.list` returns)

Flat names so small models pick them reliably (`dangerous` = confirm class):

| Tool | Args | Scope |
|---|---|---|
| `windows_list` | `app?`, `title?` | windows.read |
| `window_info` | `window` | windows.read |
| `window_focus` | `window` | windows.manage |
| `window_place` | `window`, `placement` (`left_half`, `maximize`, `center`, ...) | windows.manage |
| `window_move_resize` | `window`, `x?`,`y?`,`w?`,`h?` | windows.manage |
| `window_state` | `window`, `state` (`maximize|minimize|restore|fullscreen|keep_above|keep_below`), `on?` | windows.manage |
| `window_close` (dangerous) | `window` | windows.manage |
| `wait_for_window` | `app?`, `title?`, `timeout_s?` | windows.read |
| `ui_outline` | `window`, `depth?` | ui.read |
| `ui_find` | `window`, `role?`, `name?` | ui.read |
| `ui_click` / `ui_set_value` | `ref` / `ref`,`value` | ui.input |
| `ui_type` | `window`, `text`, `ref?` | ui.input |
| `ui_keys` | `window`, `keys` | ui.input |
| `ui_screenshot` | `window?` | ui.screenshot |
| `app_actions` / `app_invoke` | `app` / `app`,`action`,`args` | app.* |

Worked example, "open a word processor and write a letter":
`launch_app("libreoffice writer")` -> `wait_for_window(app="libreoffice")` -> `app_invoke(writer.insert_text)` *(or* `ui_type` *if the app isn't integrated)*
-> `app_invoke(writer.save_as, path=~/Documents/letter.odt)`. Blender: `app_invoke(blender.run_python, code=...)`.

## 7. Non-window services (alarms, calendar, mail, phone)

Not the WM's job — each is a **service module** in the agent (a singleton + a few tools, like `Tools.qml`), preferring standard interfaces:

| Task | Preferred route |
|---|---|
| Alarm/timer | `systemd-run --user --on-calendar` + `org.freedesktop.Notifications`, or the clock app's `app.*` action |
| Calendar | EDS (`org.gnome.evolution.dataserver.Calendar`) / Akonadi, or write an `.ics` and open it |
| Mail | `mailto:` via `xdg-email` (compose, user presses send) -> later SMTP/IMAP with stored credentials, `dangerous` |
| Phone dial | KDE Connect telephony D-Bus (`org.kde.kdeconnect.device.telephony`), contacts from EDS/Akonadi, always confirm |

## 8. How current code already follows this

* `qml/Tools.qml`: every capability is a registered tool with schema, `anim`, optional `format`, and `ctx.confirm()` for conditional prompts - the exact shape `tools.list` entries map onto.
* `qml/Desktop.qml`: connects to `agent.sock`, calls `hello` + `tools.list`, registers each entry (`dangerous` -> Allow/Deny), forwards `event`s as the `Desktop.event` signal. Absent socket = feature simply off.
* `launch_app` / `open_file` already return short text; once the WM is present they will additionally call `windows.wait_for` / `windows.place` (optional `place` argument).
* The intent router (`qml/js/router.js`) gets "put firefox on the left half" style rules that call the same tools.
* Clippy's own stacking (above/below) uses layer-shell today; under RevolutionWM it can use `windows.set_state(keep_above|keep_below)` through the same API.

## 9. Open questions for the WM side

1. Per-client identity: socket peer credentials (`SO_PEERCRED`) -> app_id? Needed for per-client scopes.
2. Where consent UI lives (WM-drawn vs delegating to the client's bubble). The draft assumes the client draws it, the WM validates the token.
3. AT-SPI coverage for Qt Quick apps requires `QT_ACCESSIBILITY=1`; the session should export it.
4. Multi-seat / multi-user: one socket per user session.
