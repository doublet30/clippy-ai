import QtQuick
import Quickshell
import "js/providers.js" as P
import "js/http.js" as Http
import "js/router.js" as Router
import "js/toolparse.js" as ToolParse

// The agent loop: user text -> [intent router] -> LLM -> (tool calls -> LLM)* -> final answer.
// Backend-agnostic: all vendor differences live in js/providers.js.
//
// Small local models are helped three ways:
//   1. the intent router answers common requests (weather, time, find/open files, launch apps) directly;
//   2. the system prompt carries few-shot tool examples;
//   3. tool calls are salvaged from plain text when the model doesn't use the tool_calls API.
Item {
    id: root

    property var history: []          // neutral messages, see providers.js
    property bool busy: false
    property int maxSteps: 6
    // "provider:model" -> true once a backend has rejected native tool calling
    property var textTools: ({})
    readonly property string _key: provider ? provider.id + ":" + provider.model : ""
    readonly property var provider: pickProvider()
    readonly property string providerLabel: provider ? provider.label + " · " + provider.model : "no provider"

    // Quickshell singletons are lazy: touch them at startup so they begin working.
    Component.onCompleted: { Apps.refresh(); Desktop.start(); Speech.init() }

    signal toolStarted(string name)
    // The UI must call decide(true/false). Auto-allowed tools never emit this.
    signal confirmRequested(string description, var decide)
    signal answered(string text)
    signal failed(string message)

    function pickProvider() {
        var want = Config.provider
        var cp = Config.cfg.providers || {}
        if (want && want !== "auto") return P.resolve(want, cp, Sys.env)
        var order = ["anthropic", "openai", "gemini", "grok", "llama", "local"]
        for (var i = 0; i < order.length; i++) {
            var r = P.resolve(order[i], cp, Sys.env)
            if (r.ready && !r.keyless) return r
        }
        return P.resolve("local", cp, Sys.env)
    }

    // ---------------------------------------------------------------- prompts
    function _example(name, q, args, textMode) {
        return "User: " + q + "\nAssistant: " + (textMode
            ? "<tool>{\"name\":\"" + name + "\",\"args\":" + args + "}</tool>"
            : "(call " + name + " with " + args + ")")
    }
    // Few-shot examples teach small models the call format. Kept short: prompt size is latency on CPU-only servers.
    readonly property var exampleTools: ["get_weather", "find_files", "open_file", "launch_app"]
    function examplesBlock(textMode) {
        var out = []
        exampleTools.forEach(n => {
            var t = Tools.get(n)
            if (t && t.examples && t.examples.length) out.push(_example(n, t.examples[0][0], t.examples[0][1], textMode))
        })
        return out.length ? "\n\nExamples:\n" + out.join("\n") : ""
    }

    function systemPrompt(textMode) {
        var now = new Date().toLocaleString(Qt.locale(), "dddd, MMMM d yyyy, h:mm AP")
        return "You are Clippy, a friendly, concise desktop assistant on the user's Linux computer"
            + (Config.userName ? " (the user is " + Config.userName + ")" : "") + ". "
            + "Your answers appear in a small speech bubble and are read aloud: reply in 1-3 short plain sentences, "
            + "no markdown, no lists, no emoji, no URLs unless asked.\n"
            + "You have tools. ALWAYS use a tool when the user asks about the weather, the time, files on this computer, "
            + "opening a file, launching a program, running a command, or anything that needs current web information. Never guess these. "
            + "To open a file or launch a program, call open_file or launch_app - do not explain how to do it yourself. "
            + "After a tool result, answer briefly using only facts from the result. "
            + "If a tool says it could not do something, say so plainly.\n"
            + "Current local time: " + now + "."
            + examplesBlock(textMode)
    }

    // ---------------------------------------------------------------- text-tool mode
    // For models that reject the tools API: tools are described in the prompt and called as <tool>{...}</tool>.
    function textToolPrompt() {
        var lines = Tools.specs().map(t => "- " + t.name + " " + JSON.stringify(Object.keys(t.parameters.properties || {})) + ": " + t.description)
        return "\n\nTo call a tool, reply with ONLY one line like "
            + "<tool>{\"name\":\"get_time\",\"args\":{}}</tool> and wait for the result. Available tools:\n" + lines.join("\n")
    }
    function toTextHistory(msgs) {
        return msgs.map(m => {
            if (m.role === "assistant" && m.toolCalls && m.toolCalls.length)
                return { role: "assistant", content: (m.content || "") + m.toolCalls.map(c => "<tool>" + JSON.stringify({ name: c.name, args: c.args }) + "</tool>").join("") }
            if (m.role === "tool") return { role: "user", content: "Tool result (" + m.name + "):\n" + m.content }
            return { role: m.role, content: m.content }
        })
    }
    function looksLikeCapabilityError(msg) {
        return /tool|function|capabilit|not support|unsupported/i.test(msg || "")
    }

    // ---------------------------------------------------------------- entry points
    function _ctx() { return { confirm: (desc, cb) => confirmRequested(desc, cb) } }

    function ask(text) {
        if (busy) return
        busy = true
        history = history.concat([{ role: "user", content: text }]).slice(-16)
        var r = Config.useRouter ? Router.route(text, w => Apps.isApp(w)) : null
        // A router response is fully deterministic and intentionally does
        // not enter the provider pipeline, so it has zero model/token cost.
        if (r && r.response) return _say(r.response)
        if (r && Tools.get(r.name)) return _direct(r)
        _step(0)
    }
    function reset() { history = []; busy = false }

    function _fail(msg) { busy = false; console.log("clippy-ai FAILED: " + msg); failed(msg) }
    function _say(text) {
        history = history.concat([{ role: "assistant", content: text }])
        busy = false
        console.log("clippy-ai answer: " + text)
        answered(text)
    }

    // Router hit: run the tool ourselves and speak its formatted result - no LLM round trip.
    function _direct(r) {
        console.log("clippy-ai routed: " + r.name + " " + JSON.stringify(r.args))
        var t = Tools.get(r.name)
        var go = () => {
            toolStarted(r.name)
            Tools.run(r.name, r.args, out => {
                console.log("clippy-ai tool result: " + String(out).slice(0, 300).replace(/\n/g, " | "))
                _say(Tools.format(r.name, out, r.args))
            }, _ctx())
        }
        if (t.dangerous) confirmRequested(t.describe ? t.describe(r.args) : r.name, ok => ok ? go() : _say("Okay, I won't do that."))
        else go()
    }

    function _step(n) {
        var p = provider
        if (!p.ready) return _fail("I don't have an API key for " + p.label + ". Set " + (P.DEFAULTS[p.id].env[0] || "a key") + " or pick another brain (right-click me).")
        var ad = P.ADAPTERS[p.kind]
        var textMode = !!textTools[_key]
        var req
        try {
            req = textMode ? ad.build(p, systemPrompt(true) + textToolPrompt(), toTextHistory(history), [])
                           : ad.build(p, systemPrompt(false), history, Tools.specs())
        } catch (e) { return _fail("Request build failed: " + e) }
        var t0 = Date.now()
        console.log("clippy-ai request -> " + p.id + ":" + p.model + (textMode ? " (text tools)" : "") + ", prompt chars " + JSON.stringify(req.body).length)
        Http.postJson(req.url, req.headers, req.body, (err, txt, st) => {
            console.log("clippy-ai response after " + (Date.now() - t0) + " ms, status " + st)
            if (err) return _fail(p.keyless ? "I couldn't reach the local model at " + p.baseUrl + ". Is Ollama (or your server) running?" : err)
            var j, r, perr = null
            try { j = JSON.parse(txt) } catch (e) { perr = "Bad response (" + st + "): " + txt.slice(0, 160) }
            if (!perr) { try { r = ad.parse(j) } catch (e) { perr = p.label + " error: " + e.message } }
            if (perr) {
                // Capability error (model can't do native tool calls): retry once in text-tool mode.
                if (!textMode && (st >= 400 || st === 0) && looksLikeCapabilityError(perr)) {
                    var t = Object.assign({}, textTools); t[_key] = true; textTools = t
                    console.warn("clippy-ai: " + _key + " rejected native tools (" + perr + "); falling back to text tools")
                    return _step(n)
                }
                return _fail(perr)
            }
            // Small models often write the call as text instead of using tool_calls: salvage it.
            if (!r.toolCalls.length) {
                var x = ToolParse.extract(r.text, Tools.names())
                if (x.calls.length) { console.log("clippy-ai: salvaged tool call from text"); r = { text: x.text, toolCalls: x.calls } }
            }
            r.toolCalls.forEach(c => console.log("clippy-ai tool call: " + c.name + " " + JSON.stringify(c.args)))
            history = history.concat([{ role: "assistant", content: r.text, toolCalls: r.toolCalls }])
            if (!r.toolCalls.length) {
                busy = false
                var text = r.text.trim() || "Hmm, I have nothing to say about that."
                console.log("clippy-ai answer: " + text)
                return answered(text)
            }
            if (n + 1 >= maxSteps) return _fail("I got stuck in a loop of tool calls.")
            _runTools(r.toolCalls, 0, n)
        }, 90000)
    }

    function _runTools(calls, i, n) {
        if (i >= calls.length) return _step(n + 1)
        var c = calls[i], t = Tools.get(c.name)
        var finish = out => {
            console.log("clippy-ai tool result: " + String(out).slice(0, 300).replace(/\n/g, " | "))
            history = history.concat([{ role: "tool", toolCallId: c.id, name: c.name, content: String(out) }])
            _runTools(calls, i + 1, n)
        }
        if (!t) return finish("Error: unknown tool " + c.name)
        var go = () => { toolStarted(c.name); Tools.run(c.name, c.args, finish, _ctx()) }
        if (t.dangerous) confirmRequested(t.describe ? t.describe(c.args) : c.name + " " + JSON.stringify(c.args),
                                          ok => ok ? go() : finish("The user denied this action."))
        else go()
    }
}
