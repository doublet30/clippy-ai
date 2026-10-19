pragma Singleton
import QtQuick
import Quickshell
import "js/http.js" as Http
import "js/router.js" as Router

// Tool registry. The LLM sees specs(); the Brain (or the intent router) calls run().
//
// A tool is: { name, description, parameters (JSON schema), anim?, examples?,
//              dangerous? (bool),                   // always ask Allow/Deny first
//              describe?(args) -> string,           // text for that prompt
//              format?(result, args) -> string,     // turn the raw result into a spoken answer
//              run(args, done(resultString), ctx) } // ctx.confirm(description, cb(bool)) for conditional prompts
//
// FUTURE: terminal/app/compositor control plugs in through register(). See docs/FUTURE_API.md.
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
    function names() { return Object.keys(registry) }
    function specs() {
        return Object.keys(registry).map(k => ({
            name: k, description: registry[k].description,
            parameters: registry[k].parameters || { type: "object", properties: {} } }))
    }
    function run(name, args, done, ctx) {
        var t = registry[name]
        if (!t) return done("Error: unknown tool " + name)
        try { t.run(args || {}, done, ctx || { confirm: (d, cb) => cb(false) }) } catch (e) { done("Error: " + e) }
    }
    function format(name, result, args) {
        var t = registry[name]
        try { return t && t.format ? t.format(result, args || {}) : String(result) } catch (e) { return String(result) }
    }

    function _obj(props, req) { return { type: "object", properties: props, required: req || [] } }

    // ---------------------------------------------------------------- file helpers
    function _home() { return Sys.home() }
    function _tilde(p) { var h = _home(); return p.indexOf(h + "/") === 0 ? "~" + p.slice(h.length) : p }
    function _expand(p) { return String(p || "").replace(/^~(?=\/|$)/, _home()) }
    function _base(p) { return p.split("/").pop() }
    function _risky(path) {
        return /\.(sh|bash|zsh|fish|desktop|appimage|run|bin|exe|msi|bat|jar|py|pl|rb|com|scr|lnk)$/i.test(path)
            || (path.indexOf(_home() + "/") !== 0)
    }
    function _plain(s) { return /^[A-Za-z0-9._+-]+$/.test(s) }

    // The Weather widget is the single owner of normal local weather data.
    // It refreshes independently and writes this small, atomic cache after a
    // successful update, allowing Revvy to answer common weather questions
    // with no network call and no LLM request.
    readonly property string widgetWeatherCache: _home() + "/.cache/ttos/weather.json"

    // find <dir> files matching all words (and optional kind), newest first
    readonly property string findScript:
        'dir=$1; kind=$2; shift 2\n' +
        'case "$dir" in "$HOME"|"$HOME"/*) ;; *) echo "OUTSIDE_HOME"; exit 0;; esac\n' +
        'case "$kind" in image) exts="png jpg jpeg gif webp bmp svg tiff heic";; video) exts="mp4 mkv avi mov webm wmv flv m4v";; ' +
        'audio) exts="mp3 flac wav ogg m4a aac opus";; document) exts="pdf doc docx odt ods odp xls xlsx ppt pptx txt md rtf csv epub";; ' +
        'archive) exts="zip tar gz tgz xz bz2 7z rar deb";; code) exts="py js ts c cpp h java rs go qml sh";; *) exts="";; esac\n' +
        'args=(); for w in "$@"; do args+=( -iname "*$w*" ); done\n' +
        'if [ -n "$exts" ]; then e=(); for x in $exts; do e+=( -o -iname "*.$x" ); done; unset "e[0]"; args+=( \\( "${e[@]}" \\) ); fi\n' +
        'timeout 15 find "$dir" -xdev \\( -type d \\( -name ".*" -o -name node_modules -o -name __pycache__ -o -name site-packages \\) -prune \\) ' +
        '-o -type f "${args[@]}" -printf "%T@\\t%p\\n" 2>/dev/null | sort -rn | head -30 | cut -f2-'

    readonly property var stopWords: ["the", "a", "an", "my", "of", "file", "files", "called", "named", "please", "that", "this", "me"]

    // Resolve a spoken folder ("downloads", "my pictures", "~/Music") to an absolute path inside $HOME.
    function _resolveDir(dir, cb) {
        var d = String(dir || "").trim().replace(/^(?:my|the)\s+/i, "")
        if (!d || /^(home|~)$/i.test(d)) return cb(_home())
        d = _expand(d)
        if (d[0] === "/") return cb(d.replace(/\/+$/, ""))
        Sys.run(["bash", "-c", 'find "$HOME" -maxdepth 3 -type d -iname "$1" -not -path "*/.*" 2>/dev/null | head -1', "_", d],
            (c, o) => cb(o.trim() || _home()))
    }

    // cb(paths[]) ; paths may be [] or ["OUTSIDE_HOME"]
    function _find(dir, kind, name, cb) {
        var sk = Router.splitKind(name, kind); name = sk.name; kind = sk.kind
        var words = String(name || "").toLowerCase().split(/[\s_]+/).filter(w => w && stopWords.indexOf(w) < 0)
        _resolveDir(dir, d => Sys.run(["bash", "-c", findScript, "_", d, kind || ""].concat(words), (c, o) => {
            cb(o.split("\n").map(l => l.trim()).filter(l => l))
        }))
    }

    function _shellSplit(s) { return String(s || "").match(/"[^"]*"|'[^']*'|\S+/g) ? String(s).match(/"[^"]*"|'[^']*'|\S+/g).map(x => x.replace(/^["']|["']$/g, "")) : [] }

    function _needConfirm(isKnownApp, risky) {
        if (Config.launchPolicy === "confirm") return true
        if (Config.launchPolicy === "allow") return false
        return risky || !isKnownApp
    }

    Component.onCompleted: {
        register({
            name: "get_time",
            description: "Get the current local date and time. Optional IANA timezone like Asia/Tokyo.",
            parameters: _obj({ timezone: { type: "string", description: "IANA timezone name (optional)" } }),
            anim: "CheckingSomething",
            examples: [["what time is it?", "{}"], ["what time is it in Tokyo?", "{\"timezone\":\"Asia/Tokyo\"}"]],
            format: function (r, a) {
                if (a.timezone) return "In " + a.timezone + " it is " + r + "."
                var d = new Date()
                return "It's " + d.toLocaleString(Qt.locale(), "h:mm AP") + " on " + d.toLocaleString(Qt.locale(), "dddd, MMMM d") + "."
            },
            run: function (a, done) {
                if (a.timezone && /^[A-Za-z_\/+\-0-9]+$/.test(a.timezone)) {
                    Sys.run(["env", "TZ=" + a.timezone, "date", "+%A %-I:%M %p"],
                        (c, o) => done(c === 0 ? o.trim() : "Unknown timezone " + a.timezone))
                } else {
                    done(new Date().toLocaleString(Qt.locale(), "dddd yyyy-MM-dd HH:mm:ss t") + " (local)")
                }
            }
        })

        register({
            name: "get_widget_weather",
            description: "Read the current local weather and forecast already displayed by the TTOS Weather widget.",
            parameters: _obj({}),
            anim: "CheckingSomething",
            format: function (r) {
                var j
                try { j = JSON.parse(r) } catch (e) { return r }
                if (!j.current || !j.location) return "The Weather widget does not have a forecast available yet."
                var unit = String(j.units || "F").toUpperCase()
                var degrees = "degrees " + (unit === "C" ? "Celsius" : "Fahrenheit")
                var current = j.current
                var s = "In " + j.location + ", it's " + Math.round(Number(current.temperature)) + " " + degrees
                    + " and " + String(current.condition || "unknown conditions").toLowerCase() + "."
                var f = j.forecast || []
                if (f.length) {
                    var today = f[0]
                    s += " " + (today.day || "Today") + ": " + String(today.condition || "mixed conditions").toLowerCase()
                        + ", high " + Math.round(Number(today.high)) + ", low " + Math.round(Number(today.low)) + "."
                }
                if (f.length > 1) {
                    var next = f[1]
                    s += " " + (next.day || "Tomorrow") + ": " + String(next.condition || "mixed conditions").toLowerCase()
                        + ", high " + Math.round(Number(next.high)) + ", low " + Math.round(Number(next.low)) + "."
                }
                return s
            },
            run: function (a, done) {
                Sys.run(["cat", widgetWeatherCache], (code, output) => {
                    if (code !== 0 || !output.trim())
                        return done("The Weather widget does not have a forecast available yet. It will be available after its next refresh.")
                    try {
                        var cache = JSON.parse(output)
                        if (!cache.current || !cache.location) throw new Error("invalid weather cache")
                        done(JSON.stringify(cache))
                    } catch (e) {
                        done("The Weather widget does not have a usable forecast available yet. It will be available after its next refresh.")
                    }
                })
            }
        })

        register({
            name: "get_weather",
            description: "Get the current weather and 3-day forecast. Leave location empty for the user's current location.",
            parameters: _obj({ location: { type: "string", description: "City name. Empty = current location." } }),
            anim: "CheckingSomething",
            examples: [["what's the weather?", "{}"], ["weather in Paris", "{\"location\":\"Paris\"}"]],
            format: function (r) {
                var j
                try { j = JSON.parse(r) } catch (e) { return r }
                var imp = Config.units === "imperial", u = imp ? "degrees" : "degrees Celsius"
                var T = (c, f) => imp ? f : c
                var now = j.now, f = j.forecast || []
                var s = "In " + j.place + ", it's " + T(now.temp_c, now.temp_f) + " " + u + " and " + now.description.trim().toLowerCase()
                      + ", feels like " + T(now.feels_like_c, now.feels_like_f) + ". "
                      + "Humidity " + now.humidity_pct + " percent, wind " + (imp ? Math.round(now.wind_kmh * 0.621) + " miles per hour" : now.wind_kmh + " kilometers per hour") + " from the " + now.wind_dir + ". "
                var day = (w, label) => label + ": " + w.description.trim().toLowerCase() + ", high " + T(w.high_c, w.high_f) + ", low " + T(w.low_c, w.low_f)
                                         + (w.chance_of_rain_pct >= 20 ? ", " + w.chance_of_rain_pct + " percent chance of rain" : "") + ". "
                if (f[0]) s += day(f[0], "Today")
                if (f[1]) s += day(f[1], "Tomorrow")
                return s.trim()
            },
            run: function (a, done) {
                var loc = (a.location || Config.location || "").trim()
                var fetchWeather = (query, label) => Http.get("https://wttr.in/" + encodeURIComponent(query) + "?format=j1", {}, (err, txt, st) => {
                    if (err || st !== 200) return done("Weather lookup failed: " + (err || st))
                    try {
                        var j = JSON.parse(txt), c = j.current_condition[0], n = (j.nearest_area || [{}])[0]
                        var place = label || (n.areaName ? n.areaName[0].value + (n.region && n.region[0].value ? ", " + n.region[0].value : (n.country ? ", " + n.country[0].value : "")) : query)
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
                // No place given: wttr.in geolocates by IP (the user's current location).
                if (!loc) return fetchWeather("", "")
                // Named place: geocode first (wttr.in's own fuzzy matching can pick the wrong city, e.g. Rome -> Lome).
                var parts = loc.split(",").map(x => x.trim())
                Http.get("https://geocoding-api.open-meteo.com/v1/search?count=1&language=en&name=" + encodeURIComponent(parts[0]), {}, (err, txt, st) => {
                    try {
                        var g = JSON.parse(txt).results
                        if (g && g.length) {
                            var r = g[0]
                            return fetchWeather(r.latitude + "," + r.longitude, r.name + (r.admin1 && r.admin1 !== r.name ? ", " + r.admin1 : "") + (r.country ? ", " + r.country : ""))
                        }
                    } catch (e) {}
                    fetchWeather(loc, "")
                })
            }
        })

        register({
            name: "web_search",
            description: "Search the web (DuckDuckGo) for up-to-date information. Returns titles, URLs and snippets.",
            parameters: _obj({ query: { type: "string" } }, ["query"]),
            anim: "Searching",
            examples: [["who won the 2022 world cup?", "{\"query\":\"2022 world cup winner\"}"]],
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
            description: "Search the user's home folder for files by name. Newest first. Use kind for file types.",
            parameters: _obj({
                name: { type: "string", description: "Words from the file name, e.g. 'budget' or 'vacation photo'" },
                kind: { type: "string", description: "One of: image, video, audio, document, archive, code (optional)" },
                directory: { type: "string", description: "Folder to search, e.g. Downloads (optional, default: whole home folder)" } }),
            anim: "Searching",
            examples: [["find my budget spreadsheet", "{\"name\":\"budget\",\"kind\":\"document\"}"],
                       ["find pictures in downloads", "{\"kind\":\"image\",\"directory\":\"Downloads\"}"]],
            format: function (r) {
                var lines = r.split("\n").filter(l => l && l.indexOf("/") === 0)
                if (r === "OUTSIDE_HOME") return "I can only search inside your home folder."
                if (!lines.length) return "I couldn't find any matching files."
                var s = "I found " + (lines.length >= 30 ? "30 or more" : lines.length) + " file" + (lines.length === 1 ? "" : "s") + ". "
                s += "The newest is " + _tilde(lines[0]) + "."
                if (lines.length > 1) s += " Others include " + lines.slice(1, 3).map(_base).join(" and ") + "."
                return s
            },
            run: function (a, done) {
                if (!a.name && !a.kind) return done("Error: give a file name or a kind.")
                _find(a.directory, a.kind, a.name, paths => done(paths.length ? paths.join("\n") : "No files found."))
            }
        })

        register({
            name: "open_file",
            description: "Open a file or folder. 'file' can be a full path or just a name; the home folder is searched and the newest match is opened. Optional 'app' opens it with that program (e.g. gwenview, kate), otherwise the default program is used.",
            parameters: _obj({
                file: { type: "string", description: "Path or file name, e.g. 'vacation.png' or '~/Documents/report.pdf'" },
                app: { type: "string", description: "Program to open it with, e.g. gwenview (optional)" } }, ["file"]),
            anim: "GetTechy",
            examples: [["open budget.ods", "{\"file\":\"budget.ods\"}"],
                       ["open the vacation picture with gwenview", "{\"file\":\"vacation picture\",\"app\":\"gwenview\"}"]],
            format: function (r) { return r },
            run: function (a, done, ctx) {
                var target = _expand(a.file || a.path || a.name || "")
                if (!target) return done("Tell me which file to open.")
                var appName = String(a.app || "").trim()
                var entry = appName ? Apps.resolve(appName) : null
                if (appName && !entry && !_plain(appName)) return done("I don't recognise the program '" + appName + "'.")

                var launch = path => {
                    var label = _base(path)
                    var go = () => {
                        if (entry) Apps.launch(entry, [path], (ok, msg) => done(ok ? "Opened " + label + " with " + entry.name + "." : msg))
                        else if (appName) Sys.run(["bash", "-c", 'command -v "$1"', "_", appName], (c, o) => {
                            if (c !== 0) return done("I couldn't find a program called " + appName + ".")
                            Sys.run(["setsid", "-f", appName, path], c2 => done(c2 === 0 ? "Opened " + label + " with " + appName + "." : "Could not start " + appName + "."))
                        })
                        else Sys.run(["setsid", "-f", "xdg-open", path], c => done(c === 0 ? "Opened " + label + "." : "Could not open " + label + "."))
                    }
                    var need = _needConfirm(!appName || !!entry, _risky(path))
                    if (need) ctx.confirm("Open " + _tilde(path) + (appName ? " with " + (entry ? entry.name : appName) : "") + "?", ok => ok ? go() : done("The user declined."))
                    else go()
                }

                if (target[0] === "/") {
                    Sys.run(["test", "-e", target], c => c === 0 ? launch(target) : done("There is no file at " + _tilde(target) + "."))
                } else {
                    _find("", "", target, paths => {
                        if (!paths.length) return done("I couldn't find a file matching '" + a.file + "' in your home folder.")
                        if (paths[0] === "OUTSIDE_HOME") return done("I can only open files inside your home folder.")
                        launch(paths[0])
                    })
                }
            }
        })

        register({
            name: "launch_app",
            description: "Launch an installed program by name (e.g. firefox, gwenview, konsole, kate). Optional 'args' passes command-line arguments. Starts detached.",
            parameters: _obj({
                name: { type: "string", description: "Program name, e.g. firefox" },
                args: { type: "string", description: "Command-line arguments (optional)" } }, ["name"]),
            anim: "GetTechy",
            examples: [["open firefox", "{\"name\":\"firefox\"}"], ["start konsole", "{\"name\":\"konsole\"}"]],
            format: function (r) { return r },
            run: function (a, done, ctx) {
                var nm = String(a.name || a.app || "").trim()
                if (!nm) return done("Tell me which program to launch.")
                var args = _shellSplit(a.args)
                var entry = Apps.resolve(nm)
                if (entry) {
                    var go = () => Apps.launch(entry, args, (ok, msg) => done(msg))
                    if (_needConfirm(true, args.length > 0)) ctx.confirm("Launch " + entry.name + (args.length ? " " + args.join(" ") : "") + "?", ok => ok ? go() : done("The user declined."))
                    else go()
                    return
                }
                if (!_plain(nm)) return done("I couldn't find a program called " + nm + ".")
                Sys.run(["bash", "-c", 'command -v "$1"', "_", nm], (c, o) => {
                    if (c !== 0) return done("I couldn't find a program called " + nm + ".")
                    var go = () => Sys.run(["setsid", "-f", nm].concat(args), c2 => done(c2 === 0 ? "Launched " + nm + "." : "Could not start " + nm + "."))
                    if (_needConfirm(false, true)) ctx.confirm("Run " + o.trim() + (args.length ? " " + args.join(" ") : "") + "?", ok => ok ? go() : done("The user declined."))
                    else go()
                })
            }
        })

        if (Config.terminalPolicy !== "deny") register({
            name: "run_terminal",
            description: "Run a shell command on the user's Linux computer (bash) and return its output. 30s timeout; set background=true for GUI/long-running programs. The user approves each command unless configured otherwise.",
            parameters: _obj({ command: { type: "string" },
                background: { type: "boolean", description: "true for GUI apps / long-running programs: launches detached and returns immediately" } }, ["command"]),
            dangerous: Config.terminalPolicy !== "allow",
            anim: "GetTechy",
            examples: [["how much disk space is free?", "{\"command\":\"df -h /home\"}"]],
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
