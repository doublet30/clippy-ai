# Intent-routing plug-ins

An intent-routing plug-in recognizes a narrow, predictable request and returns
a local action before Revvy sends anything to an LLM. It is appropriate for
fast desktop actions and fixed answers: launch a known program, search the
user's files, read a local status cache, or ask RevolutionWM to operate on a
window.

This saves tokens, removes model latency, and makes common spoken commands
work even when an AI provider is unavailable. It is **not** a bypass for
Revvy's safety policy: a route calls the same registered tool that an LLM
would call, so confirmations and compositor permissions remain in effect.

## Request path

Both text entered in Revvy and text recognized by the voice listener end up in
`Brain.ask()`:

```text
typed prompt / voice transcription / revvy-ai -p
        -> qml/Brain.qml
        -> qml/js/router.js
        -> local response or registered tool
        -> LLM only when no route matches
```

`router.js` is intentionally deterministic. A route should never make an
HTTP request, scan the disk, or spawn a process itself. It should only classify
the prompt and return a compact action; the tool performs the work
asynchronously.

## Current extension model

The current release does not load arbitrary JavaScript from a user directory.
That is intentional: an intent plug-in can launch applications or control
windows, so silently discovering writable scripts would be a code-execution
risk. A plug-in is currently a reviewed JavaScript matcher integrated into
`qml/js/router.js` (or a compiled Revvy fork).

To add one:

1. Add a small matcher near the top of `route(text, isApp)` in
   `qml/js/router.js`.
2. Return `null` when it does not confidently match. Revvy will continue to
   its normal router and then the LLM.
3. For an immediate fixed reply, return `{ response: "…" }`.
4. For an action, return `{ name: "registered_tool_name", args: { ... } }`.
5. Register the tool in `qml/Tools.qml` if it does not already exist.
6. Add examples to `tests/router.test.js`, then run `node tests/router.test.js`.

Use a narrow phrase match, normalize user input with `clean(text)`, and avoid
catch-all rules. A false positive is worse than falling through to the AI.

## Plug-in contract

`route()` currently receives the text and a predicate that checks whether a
phrase is a known desktop application:

```js
function route(text, isApp) {
    var t = clean(text)
    // Return one of these or null:
    // { response: "A local reply" }
    // { name: "tool_name", args: { key: "value" } }
    // null
}
```

`Brain.qml` treats `response` as final: it speaks/displays it and never calls a
provider. For `{ name, args }`, the named tool must be registered in
`Tools.qml`; `Brain.qml` runs it directly and formats its result for speech.

## Example: fixed local response

This is suitable for a short policy, help, or personality response that must
never vary or consume tokens:

```js
if (/\bprime directives?\b/i.test(t)) {
    return {
        response: "Serve the public trust. Protect the innocent. Uphold the law."
    }
}
```

Place specific fixed phrases before broad rules such as general web search or
chat matching.

## Example: launch a desktop application

Do **not** pass user text to a shell. Return the existing `launch_app` tool;
it resolves a `.desktop` entry through `Apps.qml`, sanitizes the command line,
and follows the user's **Launching apps/files** policy.

```js
var launch = /^(?:open|launch|start)\s+(.+)$/i.exec(t)
if (launch) {
    var app = launch[1].replace(/\s+(?:app|application|program)$/i, "").trim()
    if (isApp(app))
        return { name: "launch_app", args: { name: app } }
}
```

Examples:

```text
"launch Firefox"  ->  launch_app({name: "Firefox"})
"open Konsole"    ->  launch_app({name: "Konsole"})
```

Known applications open immediately with the default `launch: "auto"` policy.
Unknown applications, command-line arguments, or a `launch: "confirm"` policy
still show the user's normal approval prompt. In every case, the LLM is not
involved.

## Example: search files without an LLM

Use the existing `find_files` tool. It searches inside the home directory,
prunes expensive hidden/dependency directories, and returns a bounded result
set.

```js
var found = /^(?:find|search for)\s+(?:my\s+)?(.+)$/i.exec(t)
if (found) {
    var words = stripLead(found[1])
    if (words)
        return { name: "find_files", args: { name: words } }
}
```

To constrain the type or directory, provide the tool's supported arguments:

```js
return {
    name: "find_files",
    args: { name: "budget", kind: "document", directory: "Documents" }
}
```

Allowed `kind` values are `image`, `video`, `audio`, `document`, `archive`, and
`code`. Do not replace this with `find /` or an unconstrained shell command:
the built-in tool deliberately limits the search to the user's home folder.

## Example: consume a local service cache

The normal local-weather route returns `get_widget_weather`. That tool reads
the atomic cache owned by the TTOS Weather widget at
`~/.cache/ttos/weather.json`, formats a short speech response, and performs no
network or model request.

For another widget/service, use the same pattern:

1. Let the service own and atomically write a small JSON cache in
   `~/.cache/ttos/`.
2. Add a read-only tool in `Tools.qml` that validates the JSON and returns a
   concise result.
3. Route only clearly matching requests to that tool.

Do not let a router directly parse an untrusted file into a shell command.

## Example: manage a running window

Window-management routes depend on the RevolutionWM agent API. At runtime,
`Desktop.qml` connects to `$XDG_RUNTIME_DIR/revolution/agent.sock` and registers
only the tool names advertised by the compositor. Therefore a plug-in must
gracefully fall through when a capability is unavailable:

```js
if (/^close (?:the )?(?:active )?window$/i.test(t)) {
    // window_close must have been advertised by RevolutionWM.
    return { name: "window_close", args: { window: "active" } }
}
return null
```

`window_close` is a destructive operation. The compositor marks it dangerous
and returns a confirmation token; Revvy then displays its normal Allow/Deny
prompt. A route must never call `kill`, `pkill`, `xkill`, or a compositor IPC
socket directly to avoid that confirmation path.

Other useful, capability-dependent routes are:

```js
// "minimize the active window"
return { name: "window_state", args: { window: "active", state: "minimize", on: true } }

// "put Firefox on the left"
return { name: "window_place", args: { window: "firefox", placement: "left_half" } }

// "focus terminal"
return { name: "window_focus", args: { window: "konsole" } }
```

Exact tool names and accepted window references are compositor-defined. Consult
[`COMPOSITOR_API.md`](COMPOSITOR_API.md) and check `Tools.get("window_close")`
before relying on one. The API is designed to be identical on RevolutionWM X11
and Wayland; if the compositor is absent, return `null` so Revvy can explain
the limitation normally.

## Creating a new local tool

When no built-in tool fits, register one in `qml/Tools.qml`:

```js
register({
    name: "example_status",
    description: "Read a concise status from the local Example service.",
    parameters: _obj({}),
    anim: "CheckingSomething",
    format: result => "Example status: " + result,
    run: function (args, done) {
        Sys.run(["example-status", "--brief"], (code, output) =>
            done(code === 0 ? output.trim() : "The Example service is unavailable."))
    }
})
```

Use an explicit executable and argument array with `Sys.run`; do not construct
`bash -c` strings from words the user spoke. For state-changing tools, set
`dangerous: true`, provide a clear `describe(args)` callback, and perform work
only after the confirmation callback authorizes it.

## Testing checklist

Before packaging:

```bash
node tests/router.test.js
./build-debs.sh
```

Test each phrase through all three entry points: the Revvy bubble, the menu
drawer, and `revvy-ai -p "your test phrase"`. Confirm that a local match logs
`clippy-ai routed:` or `clippy-ai answer:` and does **not** log
`clippy-ai request ->`; the latter means an LLM request was made.

For window actions, test both X11 and Wayland sessions, deny the confirmation
once, and ensure the target window has the advertised capability before
allowing it.
