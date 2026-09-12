#!/usr/bin/env python3
"""Stand-in for the factory token broker, for the helper and isolation tests.

Speaks the broker's contract (services/factory-token-broker in maguerrieri/toolbox):

  POST /token   optional JSON body {"repository": "owner/repo"}
                200 {token, expires_in, expires_at, repository, permissions, app}
                403 {"error": "repository_not_bound"} when the body names a repo other
                    than the bound one
  GET  /healthz 200

Configuration (environment):
  FAKE_BROKER_BOUND       the one repository this broker's bearer is bound to (required)
  FAKE_BROKER_LEAK=1      misbehave: mint for whatever repository the caller asks
                          (the isolation test must catch this)
  FAKE_BROKER_LENIENT=1   misbehave: ignore the repository parameter and always mint
                          for the bound repo (the helper must refuse the mismatch)
  FAKE_BROKER_EXPIRES_IN  seconds until expiry (default 3600)
  FAKE_BROKER_PERMS       JSON object to return as `permissions` (misbehaving broker)
  FAKE_BROKER_NO_APP=1    omit the `app` object (misbehaving broker)
  FAKE_BROKER_OMIT_EXPIRES_IN=1  respond with expires_at only
  FAKE_BROKER_REQUIRE_BEARER  when set, requests must carry `Authorization: Bearer <this>`
                          (401 otherwise) — the real broker always requires one; the
                          helper never sends one because the API-credentials proxy does
  FAKE_BROKER_COUNT_FILE  path; each /token call appends one line (for cache tests)
  FAKE_BROKER_STATUS      force this HTTP status on /token (e.g. 500)

Prints `PORT <n>` on stdout once listening (port 0 → ephemeral).
"""
import datetime
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

BOUND = os.environ.get("FAKE_BROKER_BOUND", "")
LEAK = os.environ.get("FAKE_BROKER_LEAK") == "1"
LENIENT = os.environ.get("FAKE_BROKER_LENIENT") == "1"
EXPIRES_IN = int(os.environ.get("FAKE_BROKER_EXPIRES_IN", "3600"))
OMIT_EXPIRES_IN = os.environ.get("FAKE_BROKER_OMIT_EXPIRES_IN") == "1"
REQUIRE_BEARER = os.environ.get("FAKE_BROKER_REQUIRE_BEARER", "")
COUNT_FILE = os.environ.get("FAKE_BROKER_COUNT_FILE", "")
FORCE_STATUS = os.environ.get("FAKE_BROKER_STATUS", "")
PERMS = os.environ.get("FAKE_BROKER_PERMS", "")
NO_APP = os.environ.get("FAKE_BROKER_NO_APP") == "1"
COUNTER = {"n": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # quiet
        pass

    def _json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self._json(200, {"ok": True})
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/token":
            return self._json(404, {"error": "not_found"})
        COUNTER["n"] += 1
        if COUNT_FILE:
            with open(COUNT_FILE, "a") as fh:
                fh.write("token\n")
        if FORCE_STATUS:
            return self._json(int(FORCE_STATUS), {"error": "forced"})
        if REQUIRE_BEARER and self.headers.get("Authorization") != f"Bearer {REQUIRE_BEARER}":
            return self._json(401, {"error": "unauthorized"})
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        asked = None
        if raw:
            try:
                asked = (json.loads(raw) or {}).get("repository")
            except ValueError:
                return self._json(400, {"error": "bad_json"})
        repo = BOUND
        if asked and asked.lower() != BOUND.lower():
            if LEAK:
                repo = asked
            elif LENIENT:
                pass
            else:
                return self._json(403, {"error": "repository_not_bound"})
        n = COUNTER["n"]
        expires_at = (
            datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=EXPIRES_IN)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = {
            "token": f"ghs_fake_{repo.replace('/', '_')}_{n}",
            "expires_at": expires_at,
            "repository": repo,
            "permissions": {"contents": "write", "pull_requests": "write"},
            "app": {"slug": "factory-fake", "bot_user_id": 424242, "bot_login": "factory-fake[bot]"},
        }
        if not OMIT_EXPIRES_IN:
            body["expires_in"] = EXPIRES_IN
        if PERMS:
            body["permissions"] = json.loads(PERMS)
        if NO_APP:
            del body["app"]
        self._json(200, body)


def main():
    if not BOUND:
        print("FAKE_BROKER_BOUND is required", file=sys.stderr)
        sys.exit(2)
    srv = HTTPServer(("127.0.0.1", int(os.environ.get("FAKE_BROKER_PORT", "0"))), Handler)
    print(f"PORT {srv.server_address[1]}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
