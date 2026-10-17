.pragma library

// Tolerant extraction of tool calls from model text. Small models often emit calls as plain
// text (Qwen's <tool_call>, our <tool>, a ```json block, or a bare JSON object) instead of
// using the API's tool_calls field. Only calls naming a known tool are accepted.
//
//   extract(text, knownNames) -> { calls:[{id,name,args}], text: remaining text }

function tryParse(s) {
    try { return JSON.parse(s) } catch (e) { return null }
}

// Pull balanced {...} objects out of a string.
function jsonObjects(s) {
    var out = [], depth = 0, start = -1, inStr = false, esc = false
    for (var i = 0; i < s.length; i++) {
        var c = s[i]
        if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === "\"") inStr = false; continue }
        if (c === "\"") inStr = true
        else if (c === "{") { if (depth === 0) start = i; depth++ }
        else if (c === "}" && depth > 0) { depth--; if (depth === 0) out.push({ s: s.slice(start, i + 1), at: start, end: i + 1 }) }
    }
    return out
}

function normalise(o, known) {
    if (!o || typeof o !== "object") return null
    var name = o.name || o.tool || o.function || (o.function && o.function.name)
    if (o.function && typeof o.function === "object") { name = o.function.name; o = o.function }
    if (typeof name !== "string") return null
    name = name.trim()
    if (known.indexOf(name) < 0) return null
    var args = o.args || o.arguments || o.parameters || o.input || {}
    if (typeof args === "string") args = tryParse(args) || {}
    return { name: name, args: args }
}

function extract(text, known) {
    text = String(text || "")
    var calls = [], remaining = text, i = 0

    // 1) tagged blocks: <tool>..</tool>, <tool_call>..</tool_call>, [TOOL_CALLS]
    var tagRe = /<(tool|tool_call|function_call)>([\s\S]*?)<\/\1>/gi, m
    while ((m = tagRe.exec(text))) {
        var inner = m[2].trim().replace(/^```(?:json)?|```$/g, "").trim()
        var list = jsonObjects(inner)
        if (!list.length) { var whole = tryParse(inner); if (whole) list = [{ s: inner }] }
        list.forEach(function (j) { var c = normalise(tryParse(j.s), known); if (c) { c.id = "t" + (i++); calls.push(c) } })
    }
    if (calls.length) return { calls: calls, text: text.replace(tagRe, "").trim() }

    // 2) fenced code block(s) or bare JSON objects anywhere in the text
    var fences = text.replace(/```(?:json|tool_call|tool)?/gi, "```")
    var objs = jsonObjects(fences)
    for (var k = 0; k < objs.length; k++) {
        var parsed = tryParse(objs[k].s)
        var arr = Array.isArray(parsed) ? parsed : [parsed]
        arr.forEach(function (p) { var c = normalise(p, known); if (c) { c.id = "t" + (i++); calls.push(c) } })
    }
    if (calls.length) {
        // strip the JSON (and fences) from the spoken text
        var rest = fences
        objs.slice().reverse().forEach(function (o) { rest = rest.slice(0, o.at) + rest.slice(o.end) })
        return { calls: calls, text: rest.replace(/```/g, "").trim() }
    }

    // 3) "name(arg=value)" / "name {json}" one-liners, e.g.  get_weather {"location":"Paris"}
    for (var n = 0; n < known.length; n++) {
        var re = new RegExp("(?:^|\\s)" + known[n] + "\\s*(?:\\(\\s*(\\{[\\s\\S]*?\\})?\\s*\\)|(\\{[\\s\\S]*\\}))?\\s*$")
        var mm = re.exec(text.trim())
        if (mm && (mm[1] || mm[2] || text.trim() === known[n])) {
            var a = tryParse(mm[1] || mm[2] || "{}") || {}
            return { calls: [{ id: "t0", name: known[n], args: a }], text: "" }
        }
    }
    return { calls: [], text: text }
}
