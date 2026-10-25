# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
"""Keephaven agent memory: a scoped store an AI agent keeps its memory in, on the owner's box.

    agent-memory serve  --data DIR [--port 8790] [--bind 0.0.0.0] [--dev-token TOKEN]
    agent-memory add    --data DIR NAME [--quota-mb 1024] [--read-only]   -> prints the token ONCE
    agent-memory revoke --data DIR NAME                                    -> token stops working, files stay
    agent-memory delete --data DIR NAME                                    -> token and files gone
    agent-memory list   --data DIR                                         -> JSON, for Settings

Each agent sees only its own folder. The owner creates and revokes agents; an agent can't.
journal/ is append-only through the API: an agent can add to it, never edit or delete it.

HTTP API (all but /v1/health need  Authorization: Bearer <token>):
    GET    /v1/health                      {"ok": true, ...}
    GET    /v1/me                          name, read_only, quota, usage
    GET    /v1/files?prefix=notes/         [{path, size, mtime}]
    GET    /v1/files/<path>                the bytes; ETag header
    PUT    /v1/files/<path>                write; optional If-Match: <etag> -> 412 if it changed
    DELETE /v1/files/<path>                remove (never under journal/)
    POST   /v1/journal                     JSON object -> appended as one line with ts + seq
    GET    /v1/journal?since=YYYY-MM-DD&limit=100
    GET    /v1/search?q=word&limit=20      case-insensitive, files and journal
"""
import argparse
import datetime as dt
import hashlib
import hmac
import http.server
import json
import mimetypes
import os
import re
import secrets
import shutil
import socketserver
import sys
import tempfile
import threading
import time
import urllib.parse

VERSION = "1"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
SEG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.\-]{0,127}$")
MAX_BODY = 10 * 1024 * 1024
MAX_JOURNAL_ENTRY = 64 * 1024
MAX_PATH = 512
SEARCH_FILE_MAX = 2 * 1024 * 1024
RATE = 20.0          # requests per second per agent, sustained
BURST = 60.0


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def log(msg, owner=False):
    # The server logs to stdout, which systemd files under the unit's name. Owner commands print their
    # result (the token, the JSON list) on stdout for Settings to read, so their log line goes to stderr.
    print(f"agent-memory: {msg}", file=sys.stderr if owner else sys.stdout, flush=True)


# ----------------------------------------------------------------------------- registry (owner side)

class Registry:
    """agents.json: {name: {sha256, quota_mb, read_only, created, revoked}}. Only root writes it."""

    def __init__(self, data):
        self.data = data
        self.path = os.path.join(data, "agents.json")
        self._cache, self._mtime = {}, None
        self._lock = threading.Lock()

    def load(self):
        try:
            m = os.stat(self.path).st_mtime_ns
        except FileNotFoundError:
            return {}
        with self._lock:
            if m != self._mtime:
                with open(self.path) as f:
                    self._cache = json.load(f)
                self._mtime = m
            return self._cache

    def save(self, reg):
        os.makedirs(self.data, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.data, prefix=".agents.")
        with os.fdopen(fd, "w") as f:
            json.dump(reg, f, indent=1, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o640)
        os.replace(tmp, self.path)

    def who(self, token):
        if not token:
            return None, None
        h = hashlib.sha256(token.encode()).hexdigest()
        for name, a in self.load().items():
            if not a.get("revoked") and hmac.compare_digest(h, a.get("sha256", "")):
                return name, a
        return None, None


def agent_root(data, name):
    return os.path.join(data, "agents", name)


def usage(root):
    total = n = 0
    last = 0.0
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            try:
                st = os.stat(os.path.join(dp, f))
            except FileNotFoundError:
                continue
            total += st.st_size
            if not f.startswith("."):  # .seq and temp files count toward bytes, not toward the files an agent sees
                n += 1
            last = max(last, st.st_mtime)
    return total, n, last


# ----------------------------------------------------------------------------- path safety

def safe_rel(raw):
    """URL path tail -> a relative path made only of plain segments, or None."""
    p = urllib.parse.unquote(raw or "")
    if not p or len(p) > MAX_PATH or "\x00" in p or "\\" in p or p.startswith("/"):
        return None
    segs = p.split("/")
    if any(not SEG_RE.match(s) for s in segs):
        return None  # rejects "", ".", "..", hidden files, odd characters
    return "/".join(segs)


def inside(root, rel):
    full = os.path.realpath(os.path.join(root, rel))
    r = os.path.realpath(root)
    return full if full.startswith(r + os.sep) else None


# ----------------------------------------------------------------------------- server

class State:
    def __init__(self, data, dev_token=None):
        self.data = data
        self.reg = Registry(data)
        self.dev = None
        if dev_token:
            # standalone try-it mode: one agent named "dev", never used on a box
            self.dev = ("dev", {"quota_mb": 256, "read_only": False}, dev_token)
        self.buckets = {}
        self.locks = {}
        self.journal_lock = threading.Lock()
        self.used = {}
        self.used_lock = threading.Lock()

    def auth(self, header):
        tok = header[7:].strip() if header and header.lower().startswith("bearer ") else ""
        if self.dev and tok and hmac.compare_digest(tok, self.dev[2]):
            return self.dev[0], self.dev[1]
        return self.reg.who(tok)

    def allow(self, name):
        t = time.monotonic()
        level, last = self.buckets.get(name, (BURST, t))
        level = min(BURST, level + (t - last) * RATE)
        if level < 1:
            self.buckets[name] = (level, t)
            return False
        self.buckets[name] = (level - 1, t)
        return True

    def lock_for(self, name):
        return self.locks.setdefault(name, threading.Lock())

    def used_bytes(self, name, root):
        with self.used_lock:
            if name not in self.used:
                self.used[name] = usage(root)[0]
            return self.used[name]

    def add_used(self, name, delta):
        with self.used_lock:
            if name in self.used:
                self.used[name] = max(0, self.used[name] + delta)


def etag_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return '"' + h.hexdigest()[:32] + '"'


def make_handler(S):
    class H(http.server.BaseHTTPRequestHandler):
        server_version = "keephaven-memory/" + VERSION
        sys_version = ""

        def log_message(self, *a):
            pass

        def send_json(self, obj, code=200, extra=None):
            body = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def err(self, code, msg):
            self.send_json({"error": msg}, code)

        def body(self, limit, what):
            """The request body, or None after an error reply. Only a plain Content-Length body is
            accepted: a chunked one would otherwise read as empty and overwrite a file with nothing."""
            if self.headers.get("Transfer-Encoding"):
                self.close_connection = True
                self.err(411, "send the body with a Content-Length header, not Transfer-Encoding")
                return None
            raw = self.headers.get("Content-Length")
            if raw is None:
                self.close_connection = True
                self.err(411, "Content-Length is required")
                return None
            try:
                n = int(raw.strip())
            except ValueError:
                n = -1
            if n < 0:
                self.close_connection = True
                self.err(400, "Content-Length must be a whole number")
                return None
            if n > limit:
                self.close_connection = True  # the unread body is still on the socket
                self.err(413, what + " over " + ("10 MB" if limit == MAX_BODY else "64 KB"))
                return None
            return self.rfile.read(n) if n else b""

        def gate(self):
            name, a = S.auth(self.headers.get("Authorization"))
            if not name:
                self.err(401, "missing or unknown token; the box owner creates tokens in Settings > Agents")
                return None
            if not S.allow(name):
                self.err(429, "slow down: 20 requests a second")
                return None
            root = agent_root(S.data, name)
            os.makedirs(os.path.join(root, "journal"), exist_ok=True)
            return name, a, root

        # -- routes
        def do_GET(self):
            u = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(u.query)
            if u.path == "/v1/health":
                return self.send_json({"ok": True, "service": "keephaven-memory", "version": VERSION})
            if u.path == "/":
                # The dashboard's Agent memory tile opens this port. A person lands here, not an agent.
                host = (self.headers.get("Host") or "keephaven.local").split(":")[0]
                if not re.fullmatch(r"[A-Za-z0-9.\-]{1,253}|\[[0-9A-Fa-f:]{2,45}\]", host):
                    host = "keephaven.local"
                body = (f"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
                        f"<title>Keephaven agent memory</title><body style='font-family:sans-serif;max-width:560px;margin:40px auto;padding:0 20px'>"
                        f"<h1>Agent memory is on</h1><p>This is where your AI agents keep their memory on this Keephaven. "
                        f"Each agent gets its own folder and a journal it can add to but never change.</p>"
                        f"<p>To add an agent, or take one away, open <a href='http://{host}:8888/'>Settings</a> and go to <b>Agents</b>.</p>").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)
                return None
            g = self.gate()
            if not g:
                return
            name, a, root = g
            if u.path == "/v1/me":
                used, n, last = usage(root)
                return self.send_json({"agent": name, "read_only": bool(a.get("read_only")),
                                       "quota_bytes": int(a.get("quota_mb", 1024)) * 1024 * 1024,
                                       "used_bytes": used, "files": n,
                                       "last_write": dt.datetime.fromtimestamp(last, dt.timezone.utc).isoformat(timespec="seconds") if last else None})
            if u.path == "/v1/files":
                prefix = (q.get("prefix") or [""])[0].strip("/")
                out = []
                for dp, _dn, fn in os.walk(root):
                    for f in fn:
                        if f.startswith("."):
                            continue  # .seq and in-flight .w.* temp files
                        full = os.path.join(dp, f)
                        rel = os.path.relpath(full, root).replace(os.sep, "/")
                        if prefix and not (rel == prefix or rel.startswith(prefix + "/")):
                            continue
                        st = os.stat(full)
                        out.append({"path": rel, "size": st.st_size,
                                    "mtime": dt.datetime.fromtimestamp(st.st_mtime, dt.timezone.utc).isoformat(timespec="seconds")})
                out.sort(key=lambda x: x["path"])
                return self.send_json({"files": out[:5000], "truncated": len(out) > 5000})
            if u.path.startswith("/v1/files/"):
                rel = safe_rel(u.path[len("/v1/files/"):])
                full = rel and inside(root, rel)
                if not full:
                    return self.err(400, "bad path: plain segments of letters, digits, _ . - only")
                if not os.path.isfile(full):
                    return self.err(404, "no such file")
                tag = etag_of(full)
                with open(full, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", mimetypes.guess_type(rel)[0] or "application/octet-stream")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("ETag", tag)
                self.end_headers()
                self.wfile.write(data)
                return
            if u.path == "/v1/journal":
                since = (q.get("since") or [""])[0]
                limit = max(1, min(1000, int((q.get("limit") or ["100"])[0] or 100)))
                jd = os.path.join(root, "journal")
                files = sorted(f for f in os.listdir(jd) if re.match(r"^\d{4}-\d{2}-\d{2}\.jsonl$", f) and f[:10] >= since)
                out = []
                for f in reversed(files):
                    with open(os.path.join(jd, f)) as fh:
                        lines = fh.read().splitlines()
                    for line in reversed(lines):
                        try:
                            out.append(json.loads(line))
                        except ValueError:
                            continue
                        if len(out) >= limit:
                            break
                    if len(out) >= limit:
                        break
                out.reverse()
                return self.send_json({"entries": out})
            if u.path == "/v1/search":
                term = (q.get("q") or [""])[0].strip().lower()
                limit = max(1, min(200, int((q.get("limit") or ["20"])[0] or 20)))
                if len(term) < 2:
                    return self.err(400, "q needs at least 2 characters")
                hits = []
                for dp, _dn, fn in os.walk(root):
                    for f in sorted(fn):
                        full = os.path.join(dp, f)
                        if f.startswith(".") or os.path.getsize(full) > SEARCH_FILE_MAX:
                            continue
                        try:
                            with open(full, encoding="utf-8") as fh:
                                for i, line in enumerate(fh, 1):
                                    if term in line.lower():
                                        hits.append({"path": os.path.relpath(full, root).replace(os.sep, "/"),
                                                     "line": i, "text": line.strip()[:300]})
                                        if len(hits) >= limit:
                                            break
                        except (UnicodeDecodeError, OSError):
                            continue
                        if len(hits) >= limit:
                            break
                    if len(hits) >= limit:
                        break
                return self.send_json({"hits": hits})
            self.err(404, "unknown endpoint; GET /v1/health lists none, see the docstring in modules/agent-memory.py")

        def do_HEAD(self):
            # Health checkers often use HEAD; send_json leaves the body out for HEAD.
            if urllib.parse.urlsplit(self.path).path == "/v1/health":
                return self.send_json({"ok": True, "service": "keephaven-memory", "version": VERSION})
            self.err(405, "HEAD only works on /v1/health")

        def do_PUT(self):
            u = urllib.parse.urlsplit(self.path)
            g = self.gate()
            if not g:
                return
            name, a, root = g
            if not u.path.startswith("/v1/files/"):
                return self.err(404, "PUT only works on /v1/files/<path>")
            if a.get("read_only"):
                return self.err(403, "this agent is read-only; the owner set that in Settings")
            rel = safe_rel(u.path[len("/v1/files/"):])
            full = rel and inside(root, rel)
            if not full:
                return self.err(400, "bad path: plain segments of letters, digits, _ . - only")
            if rel == "journal" or rel.startswith("journal/"):
                return self.err(403, "journal/ is append-only: POST /v1/journal")
            data = self.body(MAX_BODY, "file")
            if data is None:
                return
            quota = int(a.get("quota_mb", 1024)) * 1024 * 1024
            with S.lock_for(name):
                old = os.path.getsize(full) if os.path.isfile(full) else 0
                if os.path.isdir(full):
                    return self.err(409, "that path is a folder")
                want = self.headers.get("If-Match")
                if want and (not os.path.isfile(full) or etag_of(full) != want):
                    return self.err(412, "file changed since you read it (ETag mismatch)")
                if S.used_bytes(name, root) - old + len(data) > quota:
                    return self.err(507, f"over this agent's quota of {quota // (1024 * 1024)} MB")
                os.makedirs(os.path.dirname(full), exist_ok=True)
                fd, tmp = tempfile.mkstemp(dir=os.path.dirname(full), prefix=".w.")
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
                    f.flush()
                    os.fsync(f.fileno())
                os.chmod(tmp, 0o640)
                os.replace(tmp, full)
                S.add_used(name, len(data) - old)
                tag = etag_of(full)
            log(f"{name} put {rel} {len(data)} bytes")
            self.send_json({"path": rel, "size": len(data), "etag": tag}, 201 if not old else 200, {"ETag": tag})

        def do_DELETE(self):
            u = urllib.parse.urlsplit(self.path)
            g = self.gate()
            if not g:
                return
            name, a, root = g
            if not u.path.startswith("/v1/files/"):
                return self.err(404, "DELETE only works on /v1/files/<path>")
            if a.get("read_only"):
                return self.err(403, "this agent is read-only")
            rel = safe_rel(u.path[len("/v1/files/"):])
            full = rel and inside(root, rel)
            if not full:
                return self.err(400, "bad path")
            if rel == "journal" or rel.startswith("journal/"):
                return self.err(403, "journal/ is append-only; nothing in it can be deleted through the API")
            if not os.path.isfile(full):
                return self.err(404, "no such file")
            with S.lock_for(name):
                size = os.path.getsize(full)
                os.remove(full)
                S.add_used(name, -size)
                d = os.path.dirname(full)
                while d != os.path.realpath(root) and not os.listdir(d):
                    os.rmdir(d)
                    d = os.path.dirname(d)
            log(f"{name} delete {rel}")
            self.send_json({"deleted": rel})

        def do_POST(self):
            u = urllib.parse.urlsplit(self.path)
            g = self.gate()
            if not g:
                return
            name, a, root = g
            if u.path != "/v1/journal":
                return self.err(404, "POST only works on /v1/journal")
            if a.get("read_only"):
                return self.err(403, "this agent is read-only")
            raw = self.body(MAX_JOURNAL_ENTRY, "journal entry")
            if raw is None:
                return
            try:
                entry = json.loads(raw or b"null")
            except ValueError:
                return self.err(400, "body must be a JSON object")
            if not isinstance(entry, dict):
                return self.err(400, "body must be a JSON object")
            quota = int(a.get("quota_mb", 1024)) * 1024 * 1024
            with S.journal_lock, S.lock_for(name):
                if S.used_bytes(name, root) + len(raw) > quota:
                    return self.err(507, "over this agent's quota")
                day = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
                path = os.path.join(root, "journal", day + ".jsonl")
                seq_file = os.path.join(root, "journal", ".seq")
                try:
                    with open(seq_file) as f:
                        seq = int(f.read().strip() or 0) + 1
                except (FileNotFoundError, ValueError):
                    seq = 1
                line = json.dumps({"ts": now_iso(), "seq": seq, "entry": entry}, ensure_ascii=False) + "\n"
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o640)
                try:
                    os.write(fd, line.encode())
                    os.fsync(fd)
                finally:
                    os.close(fd)
                with open(seq_file, "w") as f:
                    f.write(str(seq))
                S.add_used(name, len(line.encode()))
            log(f"{name} journal seq={seq}")
            self.send_json({"seq": seq, "file": "journal/" + day + ".jsonl"}, 201)

    return H


class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(args):
    os.makedirs(os.path.join(args.data, "agents"), exist_ok=True)
    S = State(args.data, args.dev_token)
    with Threaded((args.bind, args.port), make_handler(S)) as httpd:
        log(f"listening on {args.bind}:{args.port}, data {args.data}" + (" (dev token mode)" if S.dev else ""))
        httpd.serve_forever()


# ----------------------------------------------------------------------------- owner commands

def cmd_add(args):
    if not NAME_RE.match(args.name):
        sys.exit("name: 1-32 of a-z 0-9 -, starting with a letter or digit")
    reg = Registry(args.data)
    r = dict(reg.load())
    if args.name in r and not r[args.name].get("revoked"):
        sys.exit(f"{args.name} already exists; revoke it first to issue a new token")
    if not 1 <= args.quota_mb <= 1024 * 1024:
        sys.exit("quota-mb: 1 to 1048576")
    token = "khm_" + secrets.token_urlsafe(32)
    r[args.name] = {"sha256": hashlib.sha256(token.encode()).hexdigest(), "quota_mb": args.quota_mb,
                    "read_only": bool(args.read_only), "created": now_iso(), "revoked": None}
    reg.save(r)
    os.makedirs(os.path.join(agent_root(args.data, args.name), "journal"), exist_ok=True)
    log(f"owner added agent {args.name} quota={args.quota_mb}MB read_only={bool(args.read_only)}", owner=True)
    print(token)


def cmd_revoke(args):
    reg = Registry(args.data)
    r = dict(reg.load())
    if args.name not in r:
        sys.exit(f"no agent named {args.name}")
    r[args.name] = dict(r[args.name], revoked=now_iso())
    reg.save(r)
    log(f"owner revoked agent {args.name}; files kept", owner=True)
    print(f"revoked {args.name}; its files stay until you delete them")


def cmd_delete(args):
    reg = Registry(args.data)
    r = dict(reg.load())
    if args.name not in r:
        sys.exit(f"no agent named {args.name}")
    root = agent_root(args.data, args.name)
    if os.path.realpath(root).startswith(os.path.realpath(os.path.join(args.data, "agents")) + os.sep) and os.path.isdir(root):
        shutil.rmtree(root)
    del r[args.name]
    reg.save(r)
    log(f"owner deleted agent {args.name} and its files", owner=True)
    print(f"deleted {args.name} and its files on this box (a paired backup box keeps what it already received)")


def cmd_list(args):
    out = []
    for name, a in sorted(Registry(args.data).load().items()):
        used, n, last = usage(agent_root(args.data, name))
        out.append({"name": name, "quota_mb": a.get("quota_mb"), "read_only": a.get("read_only"),
                    "created": a.get("created"), "revoked": a.get("revoked"), "used_bytes": used, "files": n,
                    "last_write": dt.datetime.fromtimestamp(last, dt.timezone.utc).isoformat(timespec="seconds") if last else None})
    print(json.dumps(out))


def main(argv=None):
    p = argparse.ArgumentParser(prog="agent-memory")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve"); s.add_argument("--data", required=True); s.add_argument("--port", type=int, default=8790)
    s.add_argument("--bind", default="0.0.0.0"); s.add_argument("--dev-token")
    a = sub.add_parser("add"); a.add_argument("--data", required=True); a.add_argument("name")
    a.add_argument("--quota-mb", type=int, default=1024); a.add_argument("--read-only", action="store_true")
    for c in ("revoke", "delete"):
        x = sub.add_parser(c); x.add_argument("--data", required=True); x.add_argument("name")
    ls = sub.add_parser("list"); ls.add_argument("--data", required=True)
    args = p.parse_args(argv)
    {"serve": serve, "add": cmd_add, "revoke": cmd_revoke, "delete": cmd_delete, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    main()
