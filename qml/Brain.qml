import QtQuick
import Quickshell
import "js/providers.js" as P
import "js/http.js" as Http

// The agent loop: user text -> LLM -> (tool calls -> LLM)* -> final answer.
// Backend-agnostic: all vendor differences live in js/providers.js.
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

    function systemPrompt() {
        var now = new Date().toLocaleString(Qt.locale(), "dddd, MMMM d yyyy, h:mm AP")
        return "You are Clippy, a friendly, concise desktop assistant that lives on the user's Linux desktop"
            + (Config.userName ? " and is talking to " + Config.userName : "") + ". "
            + "Your answers are shown in a small speech bubble and read aloud, so reply in 1-4 short plain sentences: "
            + "no markdown, no lists, no emoji, no URLs unless asked. "
            + "Use tools for live information (weather, time, web) instead of guessing. "
            + "Current local time: " + now + "."
    }


    // ---- fallback for models without native tool/function calling ----
    // Tools are described in the system prompt and invoked as <tool>{"name":..,"args":{..}}</tool>.
    function textToolPrompt() {
        var lines = Tools.specs().map(t => "- " + t.name + " " + JSON.stringify(Object.keys(t.parameters.properties || {})) + ": " + t.description)
        return "\n\nYou can use tools. To call one, reply with ONLY a line like "
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
    function parseTextTools(text) {
        var calls = [], re = /<tool>([\s\S]*?)<\/tool>/g, m, i = 0
        while ((m = re.exec(text))) {
            try { var o = JSON.parse(m[1]); calls.push({ id: "t" + (i++), name: o.name, args: o.args || {} }) } catch (e) {}
        }
        return { calls: calls, text: text.replace(re, "").trim() }
    }
    function looksLikeCapabilityError(msg) {
        return /tool|function|capabilit|not support|unsupported/i.test(msg || "")
    }

    function ask(text) {
        if (busy) return
        busy = true
        history = history.concat([{ role: "user", content: text }]).slice(-24)
        _step(0)
    }
    function reset() { history = []; busy = false }

    function _fail(msg) { busy = false; failed(msg) }

    function _step(n) {
        var p = provider
        if (!p.ready) return _fail("I don't have an API key for " + p.label + ". Set " + (P.DEFAULTS[p.id].env[0] || "a key") + " or pick another brain (right-click me).")
        var ad = P.ADAPTERS[p.kind]
        var textMode = !!textTools[_key]
        var req
        try {
            req = textMode ? ad.build(p, systemPrompt() + textToolPrompt(), toTextHistory(history), [])
                           : ad.build(p, systemPrompt(), history, Tools.specs())
        } catch (e) { return _fail("Request build failed: " + e) }
        Http.postJson(req.url, req.headers, req.body, (err, txt, st) => {
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
            if (textMode) { var pt = parseTextTools(r.text); r = { text: pt.text, toolCalls: pt.calls } }
            history = history.concat([{ role: "assistant", content: r.text, toolCalls: r.toolCalls }])
            if (!r.toolCalls.length) {
                busy = false
                return answered(r.text.trim() || "Hmm, I have nothing to say about that.")
            }
            if (n + 1 >= maxSteps) return _fail("I got stuck in a loop of tool calls.")
            _runTools(r.toolCalls, 0, n)
        }, 90000)
    }

    function _runTools(calls, i, n) {
        if (i >= calls.length) return _step(n + 1)
        var c = calls[i], t = Tools.get(c.name)
        var finish = out => {
            history = history.concat([{ role: "tool", toolCallId: c.id, name: c.name, content: String(out) }])
            _runTools(calls, i + 1, n)
        }
        if (!t) return finish("Error: unknown tool " + c.name)
        var go = () => { toolStarted(c.name); Tools.run(c.name, c.args, finish) }
        if (t.dangerous) confirmRequested(t.describe ? t.describe(c.args) : c.name + " " + JSON.stringify(c.args),
                                          ok => ok ? go() : finish("The user denied this action."))
        else go()
    }
}
