#!/usr/bin/env python3
"""Reference/mock server for the RevolutionWM agent API (docs/COMPOSITOR_API.md, protocol 1).

    python3 -I tests/mock_wm.py /path/to/agent.sock

Keeps a few fake windows in memory, advertises a tool catalogue, implements the confirm-token flow and
emits `event` notifications. Real window managers implement the same wire protocol.
"""
import asyncio, json, os, sys, secrets

WINDOWS = {
    "w1": dict(id="w1", title="Mozilla Firefox", app_id="firefox", geometry=dict(x=0, y=0, w=1600, h=900), state=["maximized"], workspace=1),
    "w2": dict(id="w2", title="Konsole", app_id="konsole", geometry=dict(x=300, y=200, w=800, h=500), state=[], workspace=1),
    "w3": dict(id="w3", title="Untitled - LibreOffice Writer", app_id="libreoffice-writer", geometry=dict(x=100, y=80, w=900, h=700), state=["active"], workspace=1),
}
PLACEMENTS = {"left_half": (0, 0, 800, 900), "right_half": (800, 0, 800, 900), "center": (300, 150, 1000, 600), "maximize": (0, 0, 1600, 900)}
TOKENS = {}

CATALOGUE = [
    dict(name="windows_list", description="List open windows. Optional app or title filter.", scope="windows.read",
         parameters=dict(type="object", properties=dict(app=dict(type="string"), title=dict(type="string")))),
    dict(name="window_place", description="Move a window to a screen position: left_half, right_half, center, maximize.", scope="windows.manage",
         parameters=dict(type="object", properties=dict(window=dict(type="string"), placement=dict(type="string")), required=["window", "placement"])),
    dict(name="window_state", description="Maximize, minimize, restore, fullscreen, keep_above or keep_below a window.", scope="windows.manage",
         parameters=dict(type="object", properties=dict(window=dict(type="string"), state=dict(type="string"), on=dict(type="boolean")), required=["window", "state"])),
    dict(name="window_close", description="Close a window.", scope="windows.manage", dangerous=True,
         parameters=dict(type="object", properties=dict(window=dict(type="string")), required=["window"])),
]


def fmt(w):
    g = w["geometry"]
    return f'{w["id"]}  {w["title"]}  [{",".join(w["state"]) or "normal"}]  {g["w"]}x{g["h"]}+{g["x"]}+{g["y"]}'


def tool_call(name, a, writer):
    if name == "windows_list":
        out = [w for w in WINDOWS.values() if a.get("app", "").lower() in w["app_id"].lower() and a.get("title", "").lower() in w["title"].lower()]
        return "\n".join(fmt(w) for w in out) or "No windows."
    w = WINDOWS.get(a.get("window"))
    if not w:
        return "No such window."
    if name == "window_place":
        p = PLACEMENTS.get(a.get("placement"))
        if not p:
            return "Unknown placement. Use: " + ", ".join(PLACEMENTS)
        w["geometry"] = dict(x=p[0], y=p[1], w=p[2], h=p[3])
        notify(writer, "window.changed", dict(id=w["id"], changed=["geometry"]))
        return "Placed " + fmt(w)
    if name == "window_state":
        s = a.get("state"); on = a.get("on", True)
        st = set(w["state"]); (st.add if on else st.discard)({"maximize": "maximized", "minimize": "minimized"}.get(s, s))
        w["state"] = sorted(st)
        notify(writer, "window.changed", dict(id=w["id"], changed=["state"]))
        return "OK " + fmt(w)
    if name == "window_close":
        del WINDOWS[w["id"]]
        notify(writer, "window.removed", dict(id=w["id"]))
        return "Closed."
    return "Unknown tool."


def notify(writer, typ, data):
    writer.write((json.dumps(dict(jsonrpc="2.0", method="event", params=dict(type=typ, data=data))) + "\n").encode())


async def handle(reader, writer):
    while line := await reader.readline():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        meth, p, rid = m.get("method"), m.get("params", {}), m.get("id")
        res = err = None
        if meth == "hello":
            res = dict(server="mock-wm", backend="wayland", protocol=1, capabilities=["windows.read", "windows.manage"])
            writer.write((json.dumps(dict(jsonrpc="2.0", id=rid, result=res)) + "\n").encode())
            notify(writer, "window.active", dict(id="w3"))
            await writer.drain(); continue
        if meth == "tools.list":
            res = CATALOGUE
        elif meth == "tools.call":
            spec = next((t for t in CATALOGUE if t["name"] == p.get("name")), None)
            if not spec:
                err = dict(code=-32601, message="unknown tool")
            elif spec.get("dangerous") and p.get("confirm_token") not in TOKENS:
                tok = secrets.token_hex(8); TOKENS[tok] = (p["name"], p.get("args"))
                res = dict(confirm=f'Close window {p["args"].get("window")}?', token=tok)
            else:
                if spec.get("dangerous"): TOKENS.pop(p["confirm_token"])
                res = tool_call(p["name"], p.get("args") or {}, writer)
        else:
            err = dict(code=-32601, message="method not found")
        msg = dict(jsonrpc="2.0", id=rid); msg.update(error=err) if err else msg.update(result=res)
        writer.write((json.dumps(msg) + "\n").encode()); await writer.drain()
    writer.close()


async def main(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path): os.unlink(path)
    srv = await asyncio.start_unix_server(handle, path)
    os.chmod(path, 0o600)
    print("mock wm listening on", path, flush=True)
    async with srv: await srv.serve_forever()

if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
