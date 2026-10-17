.pragma library

// Deterministic intent router for small models.
//
// A 1-3B model is unreliable at choosing and chaining tools, so the common requests
// (weather, time, find a file, open a file, launch a program) are recognised here and
// executed directly; the LLM is only used for everything else.
//
//   route(text, isApp) -> { name, args } | null
//   isApp(word) -> bool   (does this look like an installed program?)

var FILLER = /^(?:(?:hey|hi|ok|okay|yo)\s+)?(?:clippy|tux|assistant)?[,!.\s]*(?:(?:please|pls)\s+)?(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?|i\s+(?:want|need)\s+(?:you\s+)?to\s+|i'd\s+like\s+(?:you\s+)?to\s+|go\s+ahead\s+and\s+)?(?:please\s+)?/i
var NOT_A_PLACE = /^(here|there|my (?:area|location|city|town|place|neighbou?rhood)|the area|today|tomorrow|tonight|now|outside|this (?:week|weekend|morning|afternoon|evening)|(?:the )?(?:morning|afternoon|evening|weekend))$/i
var KIND_WORDS = {
    image: /\b(?:pictures?|photos?|images?|screenshots?|pics?)\b/i,
    video: /\b(?:videos?|movies?|clips?)\b/i,
    audio: /\b(?:songs?|music|audio|mp3s?|podcasts?)\b/i,
    document: /\b(?:documents?|docs?|pdfs?|spreadsheets?|presentations?|resumes?|letters?)\b/i
}

function clean(text) {
    var t = String(text || "").trim().replace(/[?!.]+$/, "").replace(/\s+/g, " ")
    t = t.replace(/[,\s]+(?:please|pls|for me|thanks|thank you|now)$/i, "")
    var prev
    do { prev = t; t = t.replace(FILLER, "") } while (t !== prev && t.length)
    return t.trim()
}

function stripLead(s) {
    return s.replace(/^(?:the|my|a|an|that|this)\s+/i, "")
            .replace(/^(?:file|files|folder|document|picture|image|photo|video|song|pdf)\s+/i, "")
            .replace(/^(?:called|named|titled)\s+/i, "")
            .replace(/^(?:the|my)\s+/i, "")
            .replace(/^["'`]|["'`]$/g, "")
            .trim()
}

function kindOf(s) {
    for (var k in KIND_WORDS) if (KIND_WORDS[k].test(s)) return k
    return ""
}

function route(text, isApp) {
    var t = clean(text)
    if (!t || t.split(" ").length > 14) return null
    var m

    // --- weather ---------------------------------------------------------
    if (/\b(?:weather|forecast|temperature|how (?:hot|cold|warm)|will it (?:rain|snow)|is it (?:raining|snowing|going to rain)|umbrella)\b/i.test(t)) {
        var loc = ""
        m = /\b(?:in|for|at|near|around)\s+([A-Za-z][A-Za-z .,'-]{1,40}?)(?:\s+(?:today|tonight|tomorrow|this\b.*|right now|now|please)|$)/i.exec(t)
        if (m && !NOT_A_PLACE.test(m[1].trim())) loc = m[1].trim()
        return { name: "get_weather", args: loc ? { location: loc } : {} }
    }

    // --- time / date -----------------------------------------------------
    if (/\bwhat(?:'s| is)?\s+(?:the\s+)?(?:current\s+)?(?:time|date|day)\b|\bwhat time is it\b|\bwhat day is (?:it|today)\b|\btoday'?s date\b|\bcurrent (?:time|date)\b/i.test(t))
        return { name: "get_time", args: {} }

    // --- open <file> with <app> ----------------------------------------
    m = /^(?:open|show|view|display|edit|play|read|load)\s+(.+?)\s+(?:with|in|using|via)\s+([\w.+-]+(?:\s[\w.+-]+){0,2})$/i.exec(t)
    if (m) {
        var f = stripLead(m[1]), app = m[2].trim()
        if (f) return { name: "open_file", args: { file: f, app: app } }
    }

    // --- launch a program ------------------------------------------------
    m = /^(?:open|launch|start|run|fire up|execute|load)\s+(?:up\s+)?(?:the\s+|my\s+)?([\w.+-]+(?:\s[\w.+-]+)?)(?:\s+(?:app|application|program))?$/i.exec(t)
    if (m && isApp && isApp(m[1].trim())) return { name: "launch_app", args: { name: m[1].trim() } }

    // --- open a file / folder with its default program --------------------
    m = /^(open|show|view|display|play|read|pull up|bring up)\s+(.+)$/i.exec(t)
    if (m) {
        var target = stripLead(m[2])
        if (/^open$/i.test(m[1]) && isApp && isApp(target)) return { name: "launch_app", args: { name: target } }
        if (target && !/^(?:me|us|it|that|this|something|anything)\b/i.test(target)) return { name: "open_file", args: { file: target } }
    }

    // --- find files ------------------------------------------------------
    m = /^(?:find|search(?:\s+for)?|look\s+for|locate|where(?:'s| is| are)|show me|list)\s+(.+)$/i.exec(t)
    if (m) {
        var q = m[1]
        var dir = ""
        var dm = /\s+(?:in|inside|under|from|within)\s+(?:my\s+|the\s+)?([\w .~\/-]+?)(?:\s+(?:folder|directory|dir))?$/i.exec(q)
        if (dm) { dir = dm[1].trim(); q = q.slice(0, dm.index) }
        q = q.replace(/\s+(?:on|in)\s+(?:my\s+|this\s+)?(?:computer|pc|laptop|system|home(?:\s+(?:folder|directory))?|machine)$/i, "")
        var kind = kindOf(q)
        var name = stripLead(q).replace(/^(?:all\s+)?(?:my\s+)?(?:the\s+)?/i, "")
        if (kind) name = name.replace(KIND_WORDS[kind], "").replace(/\s+/g, " ").trim()
        name = name.replace(/^(?:files?|any|all|every)\b\s*/i, "").replace(/\b(?:files?|named|called|containing)\b/gi, " ").replace(/\s+/g, " ").trim()
        if (name || kind) {
            var args = {}
            if (name) args.name = name
            if (kind) args.kind = kind
            if (dir && !/^(?:computer|pc|home|system|machine)$/i.test(dir)) args.directory = dir
            return { name: "find_files", args: args }
        }
    }
    return null
}

// "vacation picture" -> { name: "vacation", kind: "image" }: file-type words become a type filter instead of name words.
var KIND_ALIAS = { image: /\b(?:pictures?|photos?|images?|screenshots?|pics?|photographs?)\b/ig, video: /\b(?:videos?|movies?|clips?)\b/ig,
                   audio: /\b(?:songs?|music|audio|podcasts?)\b/ig, document: /\b(?:documents?|docs?|spreadsheets?|presentations?|letters?)\b/ig }
function splitKind(name, kind) {
    var n = String(name || ""), k = kind || ""
    for (var key in KIND_ALIAS) {
        if (KIND_ALIAS[key].test(n)) { if (!k) k = key; n = n.replace(KIND_ALIAS[key], " ") }
        KIND_ALIAS[key].lastIndex = 0
    }
    return { name: n.replace(/\s+/g, " ").trim(), kind: k }
}
