.pragma library

// Provider adapters. The agent loop speaks one neutral message format:
//   {role:"user"|"assistant"|"tool", content, toolCalls:[{id,name,args}], toolCallId, name}
// Each adapter converts that to/from a vendor wire format.
//   build(p, system, msgs, tools) -> {url, headers, body}
//   parse(json)                   -> {text, toolCalls}
// p = {id, apiKey, model, baseUrl}.  Models/URLs are defaults; override in config.json.

var DEFAULTS = {
    openai:    { kind: "openai",    baseUrl: "https://api.openai.com/v1",            model: "gpt-4.1-mini", env: ["OPENAI_API_KEY"],  label: "ChatGPT" },
    anthropic: { kind: "anthropic",  baseUrl: "https://api.anthropic.com",            model: "claude-sonnet-5-5", env: ["ANTHROPIC_API_KEY"], label: "Claude" },
    gemini:    { kind: "gemini",     baseUrl: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash", env: ["GEMINI_API_KEY", "GOOGLE_API_KEY"], label: "Gemini" },
    llama:     { kind: "openai",    baseUrl: "https://api.llama.com/compat/v1",      model: "Llama-4-Maverick-17B-128E-Instruct-FP8", env: ["LLAMA_API_KEY"], label: "Meta Llama" },
    grok:      { kind: "openai",    baseUrl: "https://api.x.ai/v1",                  model: "grok-4", env: ["XAI_API_KEY", "GROK_API_KEY"], label: "Grok" },
    // Ollama / llama.cpp / LM Studio / vLLM: anything OpenAI-compatible, no key needed.
    local:     { kind: "openai",    baseUrl: "http://localhost:11434/v1",            model: "llama3.2", env: [], label: "Local model", keyless: true }
}

function safeParse(s) { try { return typeof s === "string" ? JSON.parse(s || "{}") : (s || {}) } catch (e) { return {} } }

// ---------- OpenAI-compatible (OpenAI, Grok, Llama API, Ollama, ...) ----------
function openaiBuild(p, system, msgs, tools) {
    var m = [{ role: "system", content: system }]
    msgs.forEach(function (x) {
        if (x.role === "assistant") {
            var o = { role: "assistant", content: x.content || null }
            if (x.toolCalls && x.toolCalls.length)
                o.tool_calls = x.toolCalls.map(function (c) {
                    return { id: c.id, type: "function", function: { name: c.name, arguments: JSON.stringify(c.args || {}) } }
                })
            m.push(o)
        } else if (x.role === "tool") m.push({ role: "tool", tool_call_id: x.toolCallId, content: x.content })
        else m.push({ role: "user", content: x.content })
    })
    var body = { model: p.model, messages: m }
    if (tools.length) body.tools = tools.map(function (t) {
        return { type: "function", function: { name: t.name, description: t.description, parameters: t.parameters } }
    })
    var h = {}
    if (p.apiKey) h["Authorization"] = "Bearer " + p.apiKey
    return { url: p.baseUrl.replace(/\/$/, "") + "/chat/completions", headers: h, body: body }
}
function openaiParse(j) {
    if (j.error) throw new Error(j.error.message || JSON.stringify(j.error))
    var c = j.choices[0].message
    return { text: c.content || "", toolCalls: (c.tool_calls || []).map(function (t, i) {
        return { id: t.id || ("call_" + i), name: t.function.name, args: safeParse(t.function.arguments) } }) }
}

// ---------- Anthropic Messages ----------
function anthropicBuild(p, system, msgs, tools) {
    var m = []
    msgs.forEach(function (x) {
        if (x.role === "assistant") {
            var blocks = []
            if (x.content) blocks.push({ type: "text", text: x.content })
            ;(x.toolCalls || []).forEach(function (c) { blocks.push({ type: "tool_use", id: c.id, name: c.name, input: c.args || {} }) })
            m.push({ role: "assistant", content: blocks })
        } else if (x.role === "tool") {
            var blk = { type: "tool_result", tool_use_id: x.toolCallId, content: x.content }
            var last = m[m.length - 1]
            if (last && last.role === "user" && Array.isArray(last.content) && last.content[0].type === "tool_result") last.content.push(blk)
            else m.push({ role: "user", content: [blk] })
        } else m.push({ role: "user", content: x.content })
    })
    var body = { model: p.model, max_tokens: 1024, system: system, messages: m }
    if (tools.length) body.tools = tools.map(function (t) { return { name: t.name, description: t.description, input_schema: t.parameters } })
    return { url: p.baseUrl.replace(/\/$/, "") + "/v1/messages",
             headers: { "x-api-key": p.apiKey, "anthropic-version": "2023-06-01" }, body: body }
}
function anthropicParse(j) {
    if (j.type === "error") throw new Error(j.error.message)
    var text = "", calls = []
    ;(j.content || []).forEach(function (b) {
        if (b.type === "text") text += b.text
        else if (b.type === "tool_use") calls.push({ id: b.id, name: b.name, args: b.input || {} })
    })
    return { text: text, toolCalls: calls }
}

// ---------- Google Gemini ----------
function geminiBuild(p, system, msgs, tools) {
    var c = []
    msgs.forEach(function (x) {
        if (x.role === "assistant") {
            var parts = []
            if (x.content) parts.push({ text: x.content })
            ;(x.toolCalls || []).forEach(function (t) { parts.push({ functionCall: { name: t.name, args: t.args || {} } }) })
            c.push({ role: "model", parts: parts })
        } else if (x.role === "tool") {
            var part = { functionResponse: { name: x.name, response: { result: x.content } } }
            var last = c[c.length - 1]
            if (last && last.role === "user" && last.parts[0].functionResponse) last.parts.push(part)
            else c.push({ role: "user", parts: [part] })
        } else c.push({ role: "user", parts: [{ text: x.content }] })
    })
    var body = { systemInstruction: { parts: [{ text: system }] }, contents: c }
    if (tools.length) body.tools = [{ functionDeclarations: tools.map(function (t) {
        var d = { name: t.name, description: t.description }
        if (Object.keys(t.parameters.properties || {}).length) d.parameters = t.parameters
        return d }) }]
    return { url: p.baseUrl.replace(/\/$/, "") + "/models/" + p.model + ":generateContent",
             headers: { "x-goog-api-key": p.apiKey }, body: body }
}
function geminiParse(j) {
    if (j.error) throw new Error(j.error.message)
    var cand = (j.candidates || [])[0]
    if (!cand || !cand.content) throw new Error("Gemini returned no content" + (cand ? " (" + cand.finishReason + ")" : ""))
    var text = "", calls = []
    ;(cand.content.parts || []).forEach(function (pt, i) {
        if (pt.text) text += pt.text
        if (pt.functionCall) calls.push({ id: "g" + i + "_" + pt.functionCall.name, name: pt.functionCall.name, args: pt.functionCall.args || {} })
    })
    return { text: text, toolCalls: calls }
}

var ADAPTERS = {
    openai: { build: openaiBuild, parse: openaiParse },
    anthropic: { build: anthropicBuild, parse: anthropicParse },
    gemini: { build: geminiBuild, parse: geminiParse }
}

// Resolve provider settings from config + environment.
//   cfgProviders: config.json "providers" object, env(name) -> string
function resolve(id, cfgProviders, env) {
    var d = DEFAULTS[id]
    if (!d) return null
    var c = (cfgProviders || {})[id] || {}
    var key = c.apiKey || ""
    for (var i = 0; !key && i < d.env.length; i++) key = env(d.env[i])
    return { id: id, kind: d.kind, label: d.label, keyless: !!d.keyless, apiKey: key,
             model: c.model || d.model, baseUrl: c.baseUrl || d.baseUrl,
             ready: !!key || !!d.keyless }
}
