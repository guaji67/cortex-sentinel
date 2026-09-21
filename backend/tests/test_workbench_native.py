"""Black-box tests of the actual Swift executable, no GUI/production data/Multica writes."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid
import http.server
import threading

REPO = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("SENTINEL_TEST_BINARY", REPO / ".build/debug/CortexSentinelBar"))


class NativeWorkbench(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="sentinel-workbench-tests-")
        cls.root = Path(cls.tmp.name)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        cls.secret = uuid.uuid4().hex
        cls.view_key = uuid.uuid4().hex
        cls.config = {"port": cls.port, "mode": "host", "node_id": str(uuid.uuid4()),
            "view_key": cls.view_key, "clients": {"tester": {"secret": cls.secret, "scopes": ["*"]},
            "limited": {"secret": cls.secret, "scopes": ["one-module"]}}}
        (cls.root / "config.json").write_text(json.dumps(cls.config))
        cls.log = (cls.root / "process.log").open("w")
        cls.process = subprocess.Popen([str(BINARY), "--workbench-serve", str(cls.root), str(REPO / "Resources/Workbench")], stdout=cls.log, stderr=cls.log)
        for _ in range(100):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{cls.port}/api/info", timeout=.2):
                    break
            except OSError:
                time.sleep(.05)
        else:
            cls.process.terminate();cls.process.wait(timeout=5)
            message=(cls.root/"process.log").read_text()[-500:]
            cls.log.close();cls.tmp.cleanup()
            raise RuntimeError("native server did not start: "+message)

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=10)
        cls.log.close()
        cls.tmp.cleanup()

    def request(self, path, body=None, actor="tester", remote=False, key=None, headers=None, method=None, stamp=None):
        raw = json.dumps(body, ensure_ascii=False).encode() if body is not None else b""
        hs = {"Content-Type": "application/json"}
        if remote:
            hs["Host"] = "10.0.0.2:" + str(self.port)
        if actor:
            timestamp = str(stamp if stamp is not None else int(time.time()))
            signature = hmac.new(self.secret.encode(), (timestamp+"\n"+path+"\n").encode()+raw, hashlib.sha256).hexdigest()
            hs.update({"X-Board-Client": actor, "X-Board-Time": timestamp, "X-Board-Signature": signature})
        if key:
            hs["Authorization"] = "Bearer " + key
        hs.update(headers or {})
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}"+path,
            data=raw if body is not None else None, headers=hs, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as res:
                return res.status, json.load(res)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def event(self, track=None, id=None, kind="track", rev=0, patch=None):
        track = track or "module-"+uuid.uuid4().hex
        return {"id": id or track, "kind": kind, "event_id": str(uuid.uuid4()), "base_revision": rev,
                "patch": {"title": "合成研究", "track": track, **(patch or {})}}

    def test_generic_100_modules_freeform(self):
        for _ in range(100):
            e = self.event(patch={"body": "自由研究", "custom": {"unusual": [1, 2, {"x": "保留"}]}})
            code, result = self.request("/api/update", e, remote=True)
            self.assertEqual(code, 200, result)
        code, row = self.request("/api/entities/"+e["id"], remote=True)
        self.assertEqual(code, 200)
        self.assertEqual(row["custom"]["unusual"][2]["x"], "保留")
        self.assertGreaterEqual(len(self.request("/api/overview")[1]["entities"]), 100)

    def test_idempotency_and_conflict(self):
        e = self.event()
        self.assertEqual(self.request("/api/update", e)[0], 200)
        self.assertTrue(self.request("/api/update", e)[1]["replayed"])
        conflict = self.event(track=e["id"], patch={"body": "stale"})
        self.assertEqual(self.request("/api/update", conflict)[0], 409)
        e["patch"]["body"] = "different event with same id"
        self.assertEqual(self.request("/api/update", e)[0], 409)

    def test_scoped_permissions(self):
        self.assertEqual(self.request("/api/update", self.event(), actor="limited")[0], 403)
        e = self.event(track="one-module")
        self.assertEqual(self.request("/api/update", e, actor="limited")[0], 200)

    def test_browser_and_signature_security(self):
        self.assertEqual(self.request("/api/overview", actor=None, remote=True)[0], 401)
        self.assertEqual(self.request("/api/overview", actor=None, remote=True, key=self.view_key)[0], 200)
        self.assertEqual(self.request("/api/update", self.event(), actor=None, remote=True, key=self.view_key)[0], 401)
        self.assertEqual(self.request("/api/overview", remote=True, stamp=1)[0], 401)
        self.assertEqual(self.request("/api/settings", actor=None, remote=True, key=self.view_key)[0], 403)
        self.assertEqual(self.request("/api/overview", headers={"Host":"attacker.example"})[0], 403)
        self.assertEqual(self.request("/api/update", self.event(), headers={"Origin":"https://attacker.example"})[0], 403)

    def test_verification_not_inferred(self):
        root = self.event(); self.assertEqual(self.request("/api/update", root)[0], 200)
        p = self.event(track=root["id"], id="bug-"+uuid.uuid4().hex, kind="problem", patch={"state":"verified","classification":"source_only"})
        self.assertEqual(self.request("/api/update", p)[0], 400)
        p["patch"].update(classification="confirmed_bug", evidence={"machine":"synthetic","version":"test","action":"open","expected":"visible","actual":"visible","checked_at":"2026-09-21T00:00:00Z","reference":"synthetic test receipt"})
        self.assertEqual(self.request("/api/update", p)[0], 200)
        regression = self.event(track=root["id"], id=p["id"], kind="problem", rev=1, patch={"state":"repairing"})
        self.assertEqual(self.request("/api/update", regression)[0], 200)
        stale = self.event(track=root["id"], id=p["id"], kind="problem", rev=2, patch={"state":"verified"})
        self.assertEqual(self.request("/api/update", stale)[0], 400)

    def test_source_colors_full_text_and_stale_guard(self):
        root = self.event(); self.request("/api/update", root)
        source = {"track":root["id"],"observed_at":"2026-09-21T00:00:00Z","legend":{"orange":"未覆盖，不等于失败"},"sections":[{"title":"自由研究","body":"不丢正文"}],"blocks":[{"id":root["id"]+":one","track":root["id"],"title":"块","source_color":"orange"}]}
        self.assertEqual(self.request("/api/source", source)[0], 200)
        source["observed_at"]="2026-09-20T00:00:00Z"
        self.assertEqual(self.request("/api/source", source)[0], 409)
        snapshot=self.request("/api/overview")[1]
        self.assertEqual(snapshot["sources"][root["id"]]["sections"][0]["body"],"不丢正文")

    def test_nested_cycle(self):
        root=self.event(); self.request("/api/update", root)
        a=self.event(track=root["id"],id=root["id"]+":a",kind="area")
        b=self.event(track=root["id"],id=root["id"]+":b",kind="area",patch={"parent":a["id"]})
        self.assertEqual(self.request("/api/update",a)[0],200)
        self.assertEqual(self.request("/api/update",b)[0],200)
        a.update(event_id=str(uuid.uuid4()),base_revision=1);a["patch"]["parent"]=b["id"]
        self.assertEqual(self.request("/api/update",a)[0],400)

    def test_source_cannot_shadow_another_tracks_identity(self):
        first=self.event();second=self.event()
        self.request("/api/update",first);self.request("/api/update",second)
        block=self.event(track=first["id"],id=first["id"]+":area",kind="area")
        self.request("/api/update",block)
        malicious={"track":second["id"],"observed_at":"2026-09-21T00:00:00Z","blocks":[{"id":block["id"],"track":second["id"],"title":"shadow"}]}
        self.assertEqual(self.request("/api/source",malicious)[0],403)

    def test_drafts_cas_and_no_unauthorized_host_mutation(self):
        draft={"base_revision":0,"drafts":{"domains":{},"tickets":{}}}
        self.assertEqual(self.request("/api/drafts",draft,method="PUT")[0],403)
        self.assertEqual(self.request("/api/drafts",draft,method="PUT",headers={"X-Sentinel-Local":"1"})[0],200)
        self.assertEqual(self.request("/api/drafts",draft,method="PUT",headers={"X-Sentinel-Local":"1"})[0],409)

    def test_oversize_and_duplicate_headers(self):
        with socket.create_connection(("127.0.0.1",self.port),timeout=2) as sock:
            sock.sendall(b"POST /api/update HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3000000\r\n\r\n")
            self.assertIn(b"413",sock.recv(1024))
        with socket.create_connection(("127.0.0.1",self.port),timeout=2) as sock:
            sock.sendall(b"POST /api/update HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n")
            self.assertIn(b"400",sock.recv(1024))

    def test_second_process_cannot_share_listener(self):
        with tempfile.TemporaryDirectory(prefix="sentinel-port-conflict-") as second:
            second=Path(second)
            (second/"config.json").write_text(json.dumps(self.config))
            run=subprocess.run([str(BINARY),"--workbench-serve",str(second),str(REPO/"Resources/Workbench")],
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
            self.assertNotEqual(run.returncode,0)
            self.assertEqual(self.request("/api/info")[0],200)

    def test_rapid_restart_keeps_same_ledger_and_port(self):
        cls=type(self)
        event=self.event(patch={"body":"survives restart"})
        self.assertEqual(self.request("/api/update",event)[0],200)
        self.request("/api/overview")
        cls.process.terminate();cls.process.wait(timeout=5)
        started=time.monotonic()
        cls.process=subprocess.Popen([str(BINARY),"--workbench-serve",str(cls.root),str(REPO/"Resources/Workbench")],stdout=cls.log,stderr=cls.log)
        for _ in range(80):
            try:
                code,row=self.request("/api/entities/"+event["id"])
                if code==200:
                    break
            except OSError:
                pass
            time.sleep(.025)
        else:
            self.fail("listener did not recover after rapid restart")
        self.assertLess(time.monotonic()-started,3)
        self.assertEqual(row["body"],"survives restart")

    def test_cutover_from_legacy_ipv4_http(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200);self.end_headers();self.wfile.write(b"ok")
            def log_message(self,*args):
                pass
        old=http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
        port=old.server_port
        thread=threading.Thread(target=old.serve_forever,daemon=True);thread.start()
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/",timeout=2) as response:
            response.read()
        old.shutdown();old.server_close();thread.join(timeout=2)
        with tempfile.TemporaryDirectory(prefix="sentinel-legacy-cutover-") as temporary:
            directory=Path(temporary)
            (directory/"config.json").write_text(json.dumps({**self.config,"port":port}))
            child=subprocess.Popen([str(BINARY),"--workbench-serve",str(directory),str(REPO/"Resources/Workbench")],stdout=self.log,stderr=self.log)
            try:
                for _ in range(240):
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/info",timeout=.2) as response:
                            self.assertEqual(json.load(response)["schema"],1)
                            break
                    except OSError:
                        time.sleep(.25)
                else:
                    self.fail("native server did not reclaim the retired legacy HTTP endpoint: " + (self.root/"process.log").read_text()[-500:])
            finally:
                child.terminate();child.wait(timeout=5)

if __name__ == "__main__":
    unittest.main()
