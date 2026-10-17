pragma Singleton
import QtQuick
import Quickshell
import "js/http.js" as Http

// Tool registry. The LLM sees specs(); the Brain calls run().
//
// A tool is: { name, description, parameters (JSON schema), dangerous?, anim?,
//              describe?(args) -> string, run(args, done(resultString)) }
//
// FUTURE: terminal/app/compositor control plugs in through register().
// See docs/FUTURE_API.md - nothing in the Brain or UI needs to change.
Singleton {
    id: root

    property var registry: ({})
    property int version: 0

    function register(tool) {
        var r = Object.assign({}, registry); r[tool.name] = tool; registry = r; version++
    }
    function unregister(name) {
        var r = Object.assign({}, registry); delete r[name]; registry = r; version++
    }
    function get(name) { return registry[name] }
    function specs() {
        return Object.keys(registry).map(k => ({
            name: k, description: registry[k].description,
            parameters: registry[k].parameters || { type: "object", properties: {} } }))
    }
    function run(name, args, done) {
        var t = registry[name]
        if (!t) return done("Error: unknown tool " + name)
        try { t.run(args || {}, done) } catch (e) { done("Error: " + e) }
    }

    function _obj(props, req) { return { type: "object", properties: props, required: req || [] } }

    Component.onCompleted: {
        register({
            name: "get_time",
            description: "Get the current local date and time, optionally for an IANA timezone like 'Asia/Tokyo'.",
            parameters: _obj({ timezone: { type: "string", description: "IANA timezone name (optional)" } }),
            anim: "CheckingSomething",
            run: function (a, done) {
                if (a.timezone && /^[A-Za-z_\/+\-0-9]+$/.test(a.timezone)) {
                    Sys.run(["env", "TZ=" + a.timezone, "date", "+%A %Y-%m-%d %H:%M:%S %Z (UTC%z)"],
                        (c, o) => done(c === 0 ? o.trim() : "Unknown timezone " + a.timezone))
                } else {
                    var d = new Date()
                    done(d.toLocaleString(Qt.locale(), "dddd yyyy-MM-dd HH:mm:ss t") + " (local)")
                }
            }
        })

        register({
            name: "get_weather",
            description: "Get current weather and a 3-day forecast for a place. Omit location to use the user's default/approximate location.",
            parameters: _obj({ location: { type: "string", description: "City or place name (optional)" } }),
            anim: "CheckingSomething",
            run: function (a, done) {
                var loc = a.location || Config.location || ""
                Http.get("https://wttr.in/" + encodeURIComponent(loc) + "?format=j1", {}, (err, txt, st) => {
                    if (err || st !== 200) return done("Weather lookup failed: " + (err || st))
                    try {
                        var j = JSON.parse(txt), c = j.current_condition[0], n = (j.nearest_area || [{}])[0]
                        var place = n.areaName ? n.areaName[0].value + ", " + (n.country ? n.country[0].value : "") : loc
                        var out = { place: place,
                            now: { temp_c: c.temp_C, temp_f: c.temp_F, feels_like_c: c.FeelsLikeC, feels_like_f: c.FeelsLikeF,
                                   description: c.weatherDesc[0].value, humidity_pct: c.humidity,
                                   wind_kmh: c.windspeedKmph, wind_dir: c.winddir16Point },
                            forecast: j.weather.map(w => ({ date: w.date, high_c: w.maxtempC, low_c: w.mintempC,
                                high_f: w.maxtempF, low_f: w.mintempF,
                                description: w.hourly[4] ? w.hourly[4].weatherDesc[0].value : "",
                                chance_of_rain_pct: Math.max.apply(null, w.hourly.map(h => +h.chanceofrain)) })) }
                        done(JSON.stringify(out))
                    } catch (e) { done("Weather parse error: " + e) }
                })
            }
        })

        register({
            name: "web_search",
            description: "Search the web (DuckDuckGo). Returns top results with title, URL and snippet. Use fetch_url to read a result in full.",
            parameters: _obj({ query: { type: "string" } }, ["query"]),
            anim: "Searching",
            run: function (a, done) {
                Http.get("https://html.duckduckgo.com/html/?q=" + encodeURIComponent(a.query), { "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) clippy-ai" }, (err, html, st) => {
                    if (err || st >= 400) return done("Search failed: " + (err || st))
                    var res = [], re = /<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<a[^>]+class="result__snippet"[^>]*>([\s\S]*?)<\/a>/g, m
                    while ((m = re.exec(html)) && res.length < 6) {
                        var u = m[1], q = /uddg=([^&]+)/.exec(u)
                        if (q) u = decodeURIComponent(q[1])
                        res.push({ title: Http.htmlToText(m[2]), url: u, snippet: Http.htmlToText(m[3]) })
                    }
                    done(res.length ? JSON.stringify(res) : "No results found.")
                })
            }
        })

        register({
            name: "fetch_url",
            description: "Download a web page and return its readable text (truncated).",
            parameters: _obj({ url: { type: "string" } }, ["url"]),
            anim: "Searching",
            run: function (a, done) {
                if (!/^https?:\/\//.test(a.url)) return done("Only http(s) URLs are allowed.")
                Http.get(a.url, { "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) clippy-ai" }, (err, txt, st) =>
                    done(err || st >= 400 ? "Fetch failed: " + (err || st) : Http.htmlToText(txt, 6000)), 20000)
            }
        })


        register({
            name: "find_files",
            description: "Find files by name under the user's home directory (case-insensitive substring match, hidden dirs skipped). Read-only. Returns up to 25 full paths, newest first.",
            parameters: _obj({ name: { type: "string", description: "Part of the file name, e.g. 'vacation' or '.png'" },
                               directory: { type: "string", description: "Directory to search (optional, default: home)" } }, ["name"]),
            anim: "Searching",
            run: function (a, done) {
                var dir = (a.directory || Sys.home()).replace(/^~/, Sys.home())
                Sys.run(["bash", "-c", "timeout 15 find \"$1\" -xdev \\( -name '.*' -prune \\) -o -type f -iname \"*$2*\" -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -25 | cut -d' ' -f2-", "_", dir, a.name],
                    (c, o) => done(o.trim() || "No files found matching '" + a.name + "' in " + dir))
            }
        })

        register({
            name: "open_file",
            description: "Open a file or folder with a desktop application (default app via xdg-open, or a specific one like 'gwenview'). Launches detached.",
            parameters: _obj({ path: { type: "string", description: "Absolute path of the file" },
                               app: { type: "string", description: "Program name, e.g. gwenview (optional)" } }, ["path"]),
            dangerous: true,
            anim: "GetTechy",
            describe: a => "Open " + a.path + (a.app ? " with " + a.app : ""),
            run: function (a, done) {
                if (a.app && !/^[A-Za-z0-9_.\-]+$/.test(a.app)) return done("Invalid application name.")
                var path = a.path.replace(/^~/, Sys.home())
                Sys.run(["setsid", "-f", a.app || "xdg-open", path], c => done(c === 0 ? "Opened." : "Could not open (exit " + c + "). Is " + (a.app || "xdg-open") + " installed?"))
            }
        })

        if (Config.terminalPolicy !== "deny") register({
            name: "run_terminal",
            description: "Run a shell command on the user's Linux computer (bash) and return its combined output. 30s timeout. The user is asked to approve each command unless configured otherwise.",
            parameters: _obj({ command: { type: "string" },
                background: { type: "boolean", description: "true for GUI apps / long-running programs (gwenview, firefox...): launches detached and returns immediately" } }, ["command"]),
            dangerous: Config.terminalPolicy !== "allow",
            anim: "GetTechy",
            describe: a => (a.background ? "Launch in background:\n" : "Run in terminal:\n") + a.command,
            run: function (a, done) {
                if (a.background) return Sys.run(["setsid", "-f", "bash", "-c", a.command + " >/dev/null 2>&1 </dev/null"], c => done(c === 0 ? "Started in the background." : "Failed to start (exit " + c + ")"))
                Sys.run(["timeout", "30", "bash", "-c", "exec 2>&1; " + a.command], (code, out) => {
                    out = out.length > 4000 ? out.slice(0, 4000) + "\n…(truncated)" : out
                    done("exit code " + code + "\n" + out)
                })
            }
        })
    }
}
