.pragma library

// Minimal XHR helpers. cb(err, text, status)
function request(method, url, headers, body, cb, timeoutMs) {
    var x = new XMLHttpRequest()
    x.open(method, url)
    for (var k in headers || {}) x.setRequestHeader(k, headers[k])
    x.timeout = timeoutMs || 60000
    x.onreadystatechange = function () {
        if (x.readyState !== XMLHttpRequest.DONE) return
        if (x.status === 0) return cb("network error / timeout: " + url, "", 0)
        cb(null, x.responseText, x.status)
    }
    x.ontimeout = function () { cb("timeout: " + url, "", 0) }
    x.send(body === undefined ? null : body)
}
function get(url, headers, cb, t) { request("GET", url, headers, undefined, cb, t) }
function postJson(url, headers, obj, cb, t) {
    var h = Object.assign({ "Content-Type": "application/json" }, headers)
    request("POST", url, h, JSON.stringify(obj), cb, t)
}

function htmlToText(html, max) {
    var t = html.replace(/<(script|style|noscript|svg)[\s\S]*?<\/\1>/gi, " ")
                .replace(/<br\s*\/?>|<\/(p|div|li|h\d|tr)>/gi, "\n")
                .replace(/<[^>]+>/g, " ")
                .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<")
                .replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#x27;|&#39;/g, "'")
                .replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim()
    return max && t.length > max ? t.slice(0, max) + "…" : t
}
