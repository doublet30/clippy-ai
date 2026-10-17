# Growing toward terminal / app / compositor control

Everything the model can *do* is a **tool** in `qml/Tools.qml`:

```js
Tools.register({
  name: "list_windows",
  description: "List open application windows.",
  parameters: { type: "object", properties: {} },
  dangerous: false,                 // true => bubble asks Allow/Deny first
  anim: "GetTechy",                 // character animation while it runs
  describe: a => "…",               // text shown in the confirm prompt
  run: (args, done) => done(JSON.stringify(windows))
})
```

The Brain (`Brain.qml`) never knows tool names; `js/providers.js` converts the
neutral tool specs into OpenAI / Anthropic / Gemini wire formats. So future
capabilities are *additive*:

| Capability | Where it plugs in |
|---|---|
| Terminal | `run_terminal` already exists (`terminal: confirm|allow|deny`). Next step: a persistent PTY session object behind the same tool. |
| RevolutionWM (KWin fork) | Write `qml/api/Compositor.qml` exposing windows/activate/move/close + events (KWin scripting over DBus, or a Wayland protocol). Register `list_windows`, `focus_window`, `get_active_window` from it. |
| Qt app UI introspection | Apps publish an accessibility-like tree (AT-SPI today, or a custom DBus `org.revolution.UiTree`). Register `describe_app_ui`, `click_element`, `type_into`. |
| Events -> agent | `Assistant.say()` / `Assistant.ask()` are exposed over `quickshell ipc call clippy …`, so the compositor or daemons can push events (alarms, new mail) into the character. |
| Alarms / calendar / email / phone | Each is a service singleton + 1-3 tools. Mark side-effecting ones `dangerous: true` (e.g. dial, send mail). |

Security model: reads are free, side effects need `dangerous: true` so the user
sees an Allow/Deny bubble. Web page text is untrusted data — keep tool results as
data and never auto-approve based on it.
