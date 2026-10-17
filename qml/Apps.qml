pragma Singleton
import QtQuick
import Quickshell

// Index of installed desktop applications (.desktop files) so "open gwenview" / "open X with kate"
// can be resolved without the model knowing any command lines.
Singleton {
    id: root

    property var entries: []        // [{id, name, generic, exec, terminal}]
    readonly property string scanScript:
        'for f in /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop ' +
        '"$HOME"/.local/share/applications/*.desktop /var/lib/flatpak/exports/share/applications/*.desktop ' +
        '"$HOME"/.local/share/flatpak/exports/share/applications/*.desktop; do ' +
        '[ -f "$f" ] || continue; ' +
        'awk -F= -v f="$f" \'/^\\[/{sec=($0=="[Desktop Entry]")} sec&&$1=="Name"&&!n{n=substr($0,6)} ' +
        'sec&&$1=="GenericName"&&!g{g=substr($0,13)} sec&&$1=="Exec"&&!e{e=substr($0,6)} ' +
        'sec&&$1=="NoDisplay"{nd=$2} sec&&$1=="Hidden"{nd=($2=="true")?"true":nd} sec&&$1=="Terminal"{t=$2} sec&&$1=="Type"{ty=$2} ' +
        'END{if(nd!="true"&&ty=="Application"&&e!="")printf "%s\\t%s\\t%s\\t%s\\t%s\\n",f,n,g,e,t}\' "$f"; done'

    function refresh() {
        Sys.run(["sh", "-c", scanScript], (c, o) => {
            var r = []
            o.split("\n").forEach(l => {
                var p = l.split("\t")
                if (p.length < 4 || !p[1]) return
                var base = p[0].split("/").pop().replace(/\.desktop$/, "")
                r.push({ id: base, name: p[1], generic: p[2] || "", exec: p[3], terminal: p[4] === "true",
                         short: base.split(".").pop().toLowerCase() })
            })
            entries = r
        })
    }
    // Quickshell creates singletons lazily: Brain touches this at startup (Apps.refresh()) so the index is ready.

    function _n(s) { return String(s || "").toLowerCase().replace(/[^a-z0-9+ ]/g, " ").replace(/\s+/g, " ").trim() }

    // Best matching installed application for a spoken name, or null.
    function resolve(query, minScore) {
        var q = _n(query)
        if (!q) return null
        var best = null, score = 0
        entries.forEach(e => {
            var n = _n(e.name), s = 0
            if (e.short === q || e.id.toLowerCase() === q) s = 100
            else if (n === q) s = 95
            else if (n.split(" ")[0] === q || e.short.replace(/-/g, " ") === q) s = 80
            else if (n.indexOf(q) === 0) s = 70
            else if (q.indexOf(" ") < 0 && n.split(" ").indexOf(q) >= 0) s = 55
            else if (q.length >= 4 && (n.indexOf(q) >= 0 || _n(e.generic) === q)) s = 40
            if (s > score || (s === score && best && e.name.length < best.name.length)) { score = s; best = e }
        })
        return score >= (minScore || 40) ? best : null
    }
    // Strict check for the intent router: only exact/prefix name matches count as "an app" ("open invoice" is a file).
    function isApp(query) { return resolve(query, 70) !== null }

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // Shell command line that runs a desktop entry, substituting %f/%F/%u/%U with the given files.
    function commandFor(entry, files) {
        var list = (files || []).map(shq).join(" ")
        var cmd = entry.exec.replace(/%[fFuU]/g, "\u0001").replace(/%[dDnNvmickK]/g, "").replace(/%%/g, "%")
        if (cmd.indexOf("\u0001") >= 0) cmd = cmd.replace(/\u0001/, list).replace(/\u0001/g, "")
        else if (list) cmd += " " + list
        if (entry.terminal) cmd = "${TERMINAL:-konsole} -e " + cmd
        return cmd
    }

    // Start detached; done(ok, message)
    function launch(entry, files, done) {
        var cmd = commandFor(entry, files)
        Sys.run(["setsid", "-f", "bash", "-c", cmd + " >/dev/null 2>&1 </dev/null"],
            c => done(c === 0, c === 0 ? "Launched " + entry.name + "." : "Could not start " + entry.name + "."))
    }
}
