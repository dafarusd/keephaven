# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
"""Off-box tests for modules/agent-memory.py. Runs the real server on a random port against a temp folder.

    python3 tests/agent-memory-api.py -v

Proves the API's logic and its refusals. It does NOT prove privilege on a box (that's tests/agent-memory.nix,
which runs the service as its own user under systemd in a VM) or anything about the Pi's hardware.
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "modules", "agent-memory.py")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class API(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = tempfile.mkdtemp(prefix="khm-")
        cls.port = free_port()
        run = lambda *a: subprocess.run([sys.executable, SERVER, *a], capture_output=True, text=True, check=True).stdout.strip()
        cls.tok_a = run("add", "--data", cls.data, "alpha", "--quota-mb", "1")
        cls.tok_b = run("add", "--data", cls.data, "beta")
        cls.tok_ro = run("add", "--data", cls.data, "reader", "--read-only")
        cls.tok_gone = run("add", "--data", cls.data, "gone")
        run("revoke", "--data", cls.data, "gone")
        cls.cli = staticmethod(run)
        cls.proc = subprocess.Popen([sys.executable, SERVER, "serve", "--data", cls.data, "--bind", "127.0.0.1",
                                     "--port", str(cls.port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for _ in range(50):
            try:
                if cls.req("GET", "/v1/health")[0] == 200:
                    break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate(); cls.proc.wait(5)

    @classmethod
    def req(cls, method, path, body=None, token=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=10)
        h = dict(headers or {})
        if token:
            h["Authorization"] = "Bearer " + token
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        c.request(method, path, body=body, headers=h)
        r = c.getresponse(); data = r.read()
        try:
            j = json.loads(data)
        except ValueError:
            j = data
        return r.status, j, dict(r.getheaders())

    def test_01_health_needs_no_token(self):
        s, j, _ = self.req("GET", "/v1/health")
        self.assertEqual((s, j["ok"]), (200, True))

    def test_02_no_token_refused(self):
        for m, p in (("GET", "/v1/me"), ("GET", "/v1/files"), ("PUT", "/v1/files/x.md"), ("POST", "/v1/journal")):
            self.assertEqual(self.req(m, p, b"x")[0], 401, p)

    def test_03_wrong_and_revoked_token_refused(self):
        self.assertEqual(self.req("GET", "/v1/me", token="khm_nope")[0], 401)
        self.assertEqual(self.req("GET", "/v1/me", token=self.tok_gone)[0], 401)

    def test_04_write_read_list(self):
        s, j, h = self.req("PUT", "/v1/files/notes/today.md", b"remember: the backup box refuses deletes", token=self.tok_a)
        self.assertIn(s, (200, 201)); self.assertTrue(h.get("ETag"))
        s, body, h2 = self.req("GET", "/v1/files/notes/today.md", token=self.tok_a)
        self.assertEqual((s, body), (200, b"remember: the backup box refuses deletes"))
        s, j, _ = self.req("GET", "/v1/files?prefix=notes", token=self.tok_a)
        self.assertEqual([f["path"] for f in j["files"]], ["notes/today.md"])

    def test_05_agents_cannot_see_each_other(self):
        self.req("PUT", "/v1/files/secret.md", b"alpha only", token=self.tok_a)
        self.assertEqual(self.req("GET", "/v1/files/secret.md", token=self.tok_b)[0], 404)
        s, j, _ = self.req("GET", "/v1/files", token=self.tok_b)
        self.assertNotIn("secret.md", [f["path"] for f in j["files"]])
        s, j, _ = self.req("GET", "/v1/search?q=alpha", token=self.tok_b)
        self.assertEqual(j["hits"], [])

    def test_06_path_tricks_refused(self):
        bad = ["../beta/x", "..%2Fbeta%2Fx", "%2Fetc%2Fpasswd", ".hidden", "a//b", "a/./b", "a\\b", "journal/../x",
               "a%00b", "x" * 600]
        for p in bad:
            s = self.req("PUT", "/v1/files/" + p, b"x", token=self.tok_a)[0]
            self.assertIn(s, (400, 404), p)
            self.assertIn(self.req("GET", "/v1/files/" + p, token=self.tok_a)[0], (400, 404), p)
        self.assertFalse(os.path.exists(os.path.join(self.data, "agents", "beta", "x")))
        self.assertFalse(os.path.exists(os.path.join(self.data, "x")))

    def test_07_journal_append_only(self):
        s1, j1, _ = self.req("POST", "/v1/journal", {"did": "first"}, token=self.tok_b)
        s2, j2, _ = self.req("POST", "/v1/journal", {"did": "second"}, token=self.tok_b)
        self.assertEqual((s1, s2), (201, 201)); self.assertEqual(j2["seq"], j1["seq"] + 1)
        f = j1["file"]
        self.assertEqual(self.req("PUT", "/v1/files/" + f, b"rewritten", token=self.tok_b)[0], 403)
        self.assertEqual(self.req("DELETE", "/v1/files/" + f, token=self.tok_b)[0], 403)
        self.assertEqual(self.req("PUT", "/v1/files/journal/new.jsonl", b"x", token=self.tok_b)[0], 403)
        s, j, _ = self.req("GET", "/v1/journal?limit=10", token=self.tok_b)
        self.assertEqual([e["entry"]["did"] for e in j["entries"]][-2:], ["first", "second"])
        self.assertEqual(self.req("POST", "/v1/journal", b"[1,2]", token=self.tok_b)[0], 400)
        self.assertEqual(self.req("POST", "/v1/journal", b"not json", token=self.tok_b)[0], 400)

    def test_08_read_only_agent(self):
        self.assertEqual(self.req("GET", "/v1/me", token=self.tok_ro)[1]["read_only"], True)
        self.assertEqual(self.req("PUT", "/v1/files/x.md", b"x", token=self.tok_ro)[0], 403)
        self.assertEqual(self.req("POST", "/v1/journal", {"a": 1}, token=self.tok_ro)[0], 403)
        self.assertEqual(self.req("DELETE", "/v1/files/x.md", token=self.tok_ro)[0], 403)

    def test_09_quota(self):
        # alpha has 1 MB
        big = b"z" * (700 * 1024)
        self.assertIn(self.req("PUT", "/v1/files/big1.bin", big, token=self.tok_a)[0], (200, 201))
        self.assertEqual(self.req("PUT", "/v1/files/big2.bin", big, token=self.tok_a)[0], 507)
        # overwriting the same file with the same size fits: quota counts the old size out
        self.assertIn(self.req("PUT", "/v1/files/big1.bin", big, token=self.tok_a)[0], (200, 201))
        self.assertEqual(self.req("DELETE", "/v1/files/big1.bin", token=self.tok_a)[0], 200)
        self.assertIn(self.req("PUT", "/v1/files/big2.bin", big, token=self.tok_a)[0], (200, 201))
        self.req("DELETE", "/v1/files/big2.bin", token=self.tok_a)

    def test_10_body_limit(self):
        # The server answers 413 from the Content-Length alone and hangs up without reading 10 MB, so a client
        # still sending sees either the 413 or a closed pipe. Either way nothing may land on disk.
        try:
            s = self.req("PUT", "/v1/files/huge.bin", b"z" * (10 * 1024 * 1024 + 1), token=self.tok_b)[0]
        except (BrokenPipeError, ConnectionResetError):
            s = 413
        self.assertEqual(s, 413)
        self.assertFalse(os.path.exists(os.path.join(self.data, "agents", "beta", "huge.bin")))

    def raw(self, request):
        """Send bytes exactly as given; return the status code, or 0 if the server sent nothing."""
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        sock.sendall(request)
        data = b""
        try:
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        sock.close()
        try:
            return int(data.split(b" ", 2)[1])
        except (IndexError, ValueError):
            return 0

    def test_10b_chunked_refused_and_nothing_written(self):
        self.req("PUT", "/v1/files/keep.md", b"original", token=self.tok_b)
        req = (b"PUT /v1/files/keep.md HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer " + self.tok_b.encode()
               + b"\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nd\r\nhello chunked\r\n0\r\n\r\n")
        self.assertEqual(self.raw(req), 411)
        self.assertEqual(self.req("GET", "/v1/files/keep.md", token=self.tok_b)[1], b"original")
        req = (b"PUT /v1/files/new-chunked.md HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer " + self.tok_b.encode()
               + b"\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
        self.assertEqual(self.raw(req), 411)
        self.assertFalse(os.path.exists(os.path.join(self.data, "agents", "beta", "new-chunked.md")))
        req = (b"POST /v1/journal HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer " + self.tok_b.encode()
               + b"\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\n{}\r\n0\r\n\r\n")
        self.assertEqual(self.raw(req), 411)

    def test_10c_missing_or_bad_content_length(self):
        auth = b"Authorization: Bearer " + self.tok_b.encode() + b"\r\n"
        for cl, want in ((None, 411), (b"abc", 400), (b"-5", 400), (b"", 400)):
            head = b"PUT /v1/files/cl.md HTTP/1.1\r\nHost: x\r\n" + auth + b"Connection: close\r\n"
            if cl is not None:
                head += b"Content-Length: " + cl + b"\r\n"
            self.assertEqual(self.raw(head + b"\r\nxyz"), want, cl)
        self.assertFalse(os.path.exists(os.path.join(self.data, "agents", "beta", "cl.md")))
        # the server is still up and answering after those
        self.assertEqual(self.req("GET", "/v1/health")[0], 200)

    def test_10d_head_health(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.request("HEAD", "/v1/health"); r = c.getresponse(); r.read()
        self.assertEqual(r.status, 200)

    def test_11_if_match(self):
        s, j, h = self.req("PUT", "/v1/files/plan.md", b"v1", token=self.tok_b)
        tag = h["ETag"]
        self.assertIn(self.req("PUT", "/v1/files/plan.md", b"v2", token=self.tok_b, headers={"If-Match": tag})[0], (200, 201))
        self.assertEqual(self.req("PUT", "/v1/files/plan.md", b"v3", token=self.tok_b, headers={"If-Match": tag})[0], 412)
        self.assertEqual(self.req("GET", "/v1/files/plan.md", token=self.tok_b)[1], b"v2")

    def test_12_search(self):
        self.req("PUT", "/v1/files/people/dafarus.md", b"line one\nHe builds Keephaven\n", token=self.tok_b)
        s, j, _ = self.req("GET", "/v1/search?q=keephaven", token=self.tok_b)
        self.assertIn({"path": "people/dafarus.md", "line": 2, "text": "He builds Keephaven"}, j["hits"])
        self.assertEqual(self.req("GET", "/v1/search?q=k", token=self.tok_b)[0], 400)

    def test_13_delete_cleans_empty_folders_not_root(self):
        self.req("PUT", "/v1/files/deep/er/x.md", b"x", token=self.tok_b)
        self.assertEqual(self.req("DELETE", "/v1/files/deep/er/x.md", token=self.tok_b)[0], 200)
        root = os.path.join(self.data, "agents", "beta")
        self.assertFalse(os.path.exists(os.path.join(root, "deep")))
        self.assertTrue(os.path.isdir(os.path.join(root, "journal")))

    def test_14_owner_list_and_duplicate_add(self):
        names = [a["name"] for a in json.loads(self.cli("list", "--data", self.data))]
        self.assertEqual(names, ["alpha", "beta", "gone", "reader"])
        r = subprocess.run([sys.executable, SERVER, "add", "--data", self.data, "beta"], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        for bad in ("Beta", "-x", "a" * 40, "a/b"):
            r = subprocess.run([sys.executable, SERVER, "add", "--data", self.data, bad], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0, bad)

    def test_15_tokens_not_stored_in_clear(self):
        reg = open(os.path.join(self.data, "agents.json")).read()
        for t in (self.tok_a, self.tok_b, self.tok_ro):
            self.assertNotIn(t, reg)
        self.assertEqual(oct(os.stat(os.path.join(self.data, "agents.json")).st_mode & 0o777), "0o640")

    def test_16_rate_limit(self):
        codes = [self.req("GET", "/v1/me", token=self.tok_ro)[0] for _ in range(90)]
        self.assertIn(429, codes)

    def test_17_revoked_then_delete(self):
        tok = self.cli("add", "--data", self.data, "temp")
        self.assertIn(self.req("PUT", "/v1/files/a.md", b"x", token=tok)[0], (200, 201))
        self.cli("revoke", "--data", self.data, "temp")
        self.assertEqual(self.req("GET", "/v1/files/a.md", token=tok)[0], 401)
        self.assertTrue(os.path.exists(os.path.join(self.data, "agents", "temp", "a.md")))
        self.cli("delete", "--data", self.data, "temp")
        self.assertFalse(os.path.exists(os.path.join(self.data, "agents", "temp")))


if __name__ == "__main__":
    unittest.main()
