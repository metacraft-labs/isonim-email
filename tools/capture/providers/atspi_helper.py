"""The accessibility client of the linux-desktop capture provider.

A desktop mail client that offers no remote-control protocol of its
own is driven, and measured, through its accessibility tree (AT-SPI):
the geometry of its message-body widget, the subject it shows, the
text field of a password prompt, a button to press. This process runs
outside the capture session and talks to the session's own buses (the
session bus, and through it the session's accessibility bus); the
caller passes DBUS_SESSION_BUS_ADDRESS and XDG_RUNTIME_DIR.

Protocol: one JSON request per line on stdin, one JSON answer per line
on stdout ({"ok": true, "result": ...} or {"ok": false, "error": ...}).

  {"op": "wait_name", "name": N, "timeout_ms": T}
      a name (the accessibility bus, a client, a keyring) is owned on
      the session bus
  {"op": "find", "app": A, "window": W, "role": R, "name": N,
    "name_re": RE, "showing": B, "prune": [roles], "limit": K}
      nodes matching every given filter, depth first; each has its role,
      name, window-relative extents, states, action names, text (for a
      text node), its ancestors (role, name, extents; the window first)
      and a path (child indices from the desktop) for the ops below
  {"op": "act", "path": P, "action": NAME}  runs the node's action; the
      answer is the toolkit's: true when it performed it
  {"op": "windows", "app": A}               the names of the app's
      top-level windows, as the app reports them now (its accessibility
      objects: a window exists here as soon as the app created it,
      before the compositor shows it)
  {"op": "focus", "path": P}                gives the node the focus
  {"op": "set_text", "path": P, "text": T}  replaces an editable text
  {"op": "dbus_call", "dest": D, "path": P, "iface": I, "method": M,
    "args": TEXT}
      calls a method on the session bus, its arguments in GVariant text
      form (a client's own remote API, e.g. a GApplication action)
  {"op": "sql", "db": FILE, "sql": S, "params": [...]}
      runs one statement on an SQLite file (a client's own store, e.g.
      Evolution's remote-content list or Akonadi's item table) and
      returns its rows as lists

The answers carry no secret: a password is written into a field with
set_text and never echoed back (password fields are not read).
"""

import json
import re
import sqlite3
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, Gio, GLib  # noqa: E402

UNKNOWN = -2147483648


def pump():
    ctx = GLib.MainContext.default()
    while ctx.pending():
        ctx.iteration(False)


def extents(node):
    try:
        comp = node.get_component_iface()
        if comp is None:
            return None
        e = comp.get_extents(Atspi.CoordType.WINDOW)
        if e.x == UNKNOWN or e.y == UNKNOWN:
            return None
        return {"x": e.x, "y": e.y, "width": e.width, "height": e.height}
    except GLib.Error:
        return None


def states(node):
    try:
        return sorted(s.value_nick for s in node.get_state_set().get_states())
    except GLib.Error:
        return []


def actions(node):
    try:
        a = node.get_action_iface()
        if a is None:
            return []
        return [Atspi.Action.get_action_name(a, i) for i in range(a.get_n_actions())]
    except GLib.Error:
        return []


def text_of(node, role):
    if role == "password text":
        return None
    try:
        t = node.get_text_iface()
        if t is None:
            return None
        return Atspi.Text.get_text(t, 0, -1)
    except GLib.Error:
        return None


def resolve(path):
    node = Atspi.get_desktop(0)
    for i in path:
        node = node.get_child_at_index(i)
        if node is None:
            raise RuntimeError(f"no node at {path}")
    return node


def find(req):
    pump()
    desk = Atspi.get_desktop(0)
    app_name = req.get("app")
    window_re = re.compile(req["window"]) if req.get("window") else None
    roles = req.get("role")
    if isinstance(roles, str):
        roles = [roles]
    name = req.get("name")
    name_re = re.compile(req["name_re"]) if req.get("name_re") else None
    showing = req.get("showing")
    prune = set(req.get("prune", []))
    limit = req.get("limit", 1000)
    out = []

    def walk(node, path, depth, anc):
        if len(out) >= limit or depth > 60:
            return
        try:
            role = node.get_role_name()
            nm = node.get_name() or ""
        except GLib.Error:
            return
        ok = True
        if roles is not None and role not in roles:
            ok = False
        if ok and name is not None and nm != name:
            ok = False
        if ok and name_re is not None and not name_re.search(nm):
            ok = False
        st = None
        if ok and showing is not None:
            st = states(node)
            if ("showing" in st) != showing:
                ok = False
        if ok and depth > 0:
            out.append(
                {
                    "path": path,
                    "role": role,
                    "name": nm,
                    "extents": extents(node),
                    "states": st if st is not None else states(node),
                    "actions": actions(node),
                    "text": text_of(node, role),
                    "ancestors": anc,
                }
            )
        if role in prune and depth > 0:
            return
        try:
            n = node.get_child_count()
        except GLib.Error:
            return
        me = anc + [{"role": role, "name": nm, "extents": extents(node), "path": path}]
        for i in range(n):
            try:
                c = node.get_child_at_index(i)
            except GLib.Error:
                continue
            if c is not None:
                walk(c, path + [i], depth + 1, me)

    for i in range(desk.get_child_count()):
        app = desk.get_child_at_index(i)
        if app is None:
            continue
        try:
            app.clear_cache()
            if app_name is not None and app.get_name() != app_name:
                continue
        except GLib.Error:
            continue
        for j in range(app.get_child_count()):
            win = app.get_child_at_index(j)
            if win is None:
                continue
            try:
                if window_re is not None and not window_re.search(win.get_name() or ""):
                    continue
            except GLib.Error:
                continue
            walk(win, [i, j], 1, [])
    return out


def act(req):
    node = resolve(req["path"])
    a = node.get_action_iface()
    if a is None:
        raise RuntimeError("the node has no action")
    names = [Atspi.Action.get_action_name(a, i) for i in range(a.get_n_actions())]
    want = req.get("action")
    idx = 0 if want is None else names.index(want)
    return Atspi.Action.do_action(a, idx)


def windows(req):
    pump()
    desk = Atspi.get_desktop(0)
    out = []
    for i in range(desk.get_child_count()):
        app = desk.get_child_at_index(i)
        if app is None:
            continue
        try:
            app.clear_cache()
            if app.get_name() != req["app"]:
                continue
            for j in range(app.get_child_count()):
                win = app.get_child_at_index(j)
                if win is not None:
                    out.append(win.get_name() or "")
        except GLib.Error:
            continue
    return out


def set_text(req):
    node = resolve(req["path"])
    e = node.get_editable_text_iface()
    if e is None:
        raise RuntimeError("the node is not editable text")
    return Atspi.EditableText.set_text_contents(e, req["text"])


def focus(req):
    node = resolve(req["path"])
    comp = node.get_component_iface()
    if comp is None:
        raise RuntimeError("the node has no component")
    return Atspi.Component.grab_focus(comp)


def wait_name(req):
    deadline = time.monotonic() + req.get("timeout_ms", 10000) / 1000
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    while True:
        try:
            r = bus.call_sync(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "NameHasOwner",
                GLib.Variant("(s)", (req["name"],)),
                GLib.VariantType("(b)"),
                Gio.DBusCallFlags.NONE,
                1000,
                None,
            )
            if r.unpack()[0]:
                return True
        except GLib.Error:
            pass
        if time.monotonic() > deadline:
            raise RuntimeError(f"{req['name']} did not appear on the session bus")
        time.sleep(0.02)


def dbus_call(req):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    args = GLib.Variant.parse(None, req["args"], None, None) if req.get("args") else None
    r = bus.call_sync(
        req["dest"],
        req["path"],
        req["iface"],
        req["method"],
        args,
        None,
        Gio.DBusCallFlags.NONE,
        req.get("timeout_ms", 20000),
        None,
    )
    return None if r is None else r.unpack()


def sql(req):
    con = sqlite3.connect(req["db"], timeout=10)
    try:
        cur = con.execute(req["sql"], req.get("params", []))
        rows = [list(r) for r in cur.fetchall()]
        con.commit()
        return rows
    finally:
        con.close()


OPS = {
    "find": find,
    "act": act,
    "windows": windows,
    "focus": focus,
    "set_text": set_text,
    "wait_name": wait_name,
    "dbus_call": dbus_call,
    "sql": sql,
}


def main():
    for line in sys.stdin:
        line = line.strip()
        if line == "":
            continue
        try:
            req = json.loads(line)
            res = OPS[req["op"]](req)
            ans = {"ok": True, "result": res}
        except Exception as err:  # every failure is an answer, never a crash
            ans = {"ok": False, "error": f"{type(err).__name__}: {err}"}
        sys.stdout.write(json.dumps(ans) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
