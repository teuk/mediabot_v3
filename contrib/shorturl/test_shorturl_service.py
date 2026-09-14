#!/usr/bin/env python3
"""Offline behavioral and security tests for Mediabot ShortURL."""

import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from contextlib import redirect_stdout

import shorturl_admin as admin
import configure_client as client_config
import shorturl_service as shorturl
import verify_live as live_verify


class ShortURLContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.token = "a" * 64
        self.now = 1_800_000_000
        self.config = {
            "database": str(self.root / "shorturl.sqlite3"),
            "listen_host": "127.0.0.1",
            "listen_port": 8766,
            "public_base": "https://teuk.org/shorturl/",
            "requests_per_minute": 300,
            "slug_length": 10,
            "token_hashes": {
                "dev": hashlib.sha256(self.token.encode()).hexdigest(),
                "nbot": hashlib.sha256(("b" * 64).encode()).hexdigest(),
            },
        }
        self.store = shorturl.Store(
            self.config["database"], self.config["public_base"], 10,
            clock=lambda: self.now,
        )
        self.monotonic = 1000
        self.app = shorturl.Application(
            self.config, store=self.store, clock=lambda: self.monotonic
        )

    def tearDown(self):
        self.store.close()
        self.temporary.cleanup()

    def request(self, method, path, body=None, token=None, **extra):
        raw = json.dumps(body).encode() if body is not None else b""
        environ = {
            "REQUEST_METHOD": method,
            "PATH_INFO": path,
            "QUERY_STRING": "",
            "CONTENT_TYPE": "application/json",
            "CONTENT_LENGTH": str(len(raw)),
            "HTTP_AUTHORIZATION": "Bearer " + (token or self.token),
            "wsgi.input": io.BytesIO(raw),
        }
        environ.update(extra)
        captured = []
        response = b"".join(self.app(
            environ, lambda status, headers: captured.append((status, headers))
        ))
        status = int(captured[0][0].split()[0])
        headers = dict(captured[0][1])
        decoded = json.loads(response) if response else None
        return status, headers, decoded

    def create(self, target="https://example.org/news?id=1"):
        return self.request("POST", "/shorturl/api/v1/links", {"url": target})

    def test_authenticated_create_and_public_redirect(self):
        status, _, result = self.create()
        self.assertEqual(status, 201)
        self.assertEqual(result["url"], "https://example.org/news?id=1")
        self.assertRegex(result["id"], r"^[23456789A-HJ-NP-Za-km-z]{10}$")
        self.assertEqual(result["short_url"],
                         "https://teuk.org/shorturl/" + result["id"])
        status, headers, body = self.request(
            "GET", "/shorturl/" + result["id"], token="c" * 64
        )
        self.assertEqual((status, headers["Location"], body),
                         (302, "https://example.org/news?id=1", None))

    def test_creation_is_idempotent_across_instances(self):
        first = self.create()[2]
        second = self.request(
            "POST", "/shorturl/api/v1/links",
            {"url": "https://example.org/news?id=1"}, token="b" * 64,
        )
        self.assertEqual(second[0], 200)
        self.assertEqual(second[2]["id"], first["id"])
        self.assertFalse(second[2]["created"])
        self.assertEqual(self.store.counts()["links"], 1)

    def test_creation_requires_known_token(self):
        self.assertEqual(self.create()[0], 201)
        self.assertEqual(self.request(
            "POST", "/shorturl/api/v1/links",
            {"url": "https://example.org/other"}, token="c" * 64,
        )[0], 401)
        self.assertEqual(self.store.counts()["links"], 1)

    def test_public_redirect_requires_no_token(self):
        identifier = self.create()[2]["id"]
        status, headers, body = self.request(
            "HEAD", "/shorturl/" + identifier,
            token="", HTTP_AUTHORIZATION="",
        )
        self.assertEqual((status, body), (302, None))
        self.assertEqual(headers["Location"], "https://example.org/news?id=1")

    def test_unknown_identifier_has_no_redirect(self):
        status, headers, result = self.request(
            "GET", "/shorturl/2222222222", HTTP_AUTHORIZATION=""
        )
        self.assertEqual((status, result), (404, {"error": "not_found"}))
        self.assertNotIn("Location", headers)

    def test_target_validation_blocks_header_and_userinfo_abuse(self):
        rejected = (
            "file:///etc/passwd",
            "https://user:password@example.org/private",
            "https://example.org/a\r\nX-Evil: yes",
            "https://teuk.org/shorturl/2222222222",
            "https://example.org/é",
        )
        for target in rejected:
            with self.subTest(target=target):
                status = self.create(target)[0]
                self.assertIn(status, (409, 422))

    def test_public_base_is_bound_to_the_documented_route(self):
        invalid = dict(self.config)
        invalid["public_base"] = "https://teuk.org/other/"
        with self.assertRaises(shorturl.ShortURLError) as caught:
            shorturl.validate_config(invalid)
        self.assertEqual(caught.exception.code, "invalid_public_base")

    def test_body_contract_is_bounded_and_exact(self):
        self.assertEqual(self.request(
            "POST", "/shorturl/api/v1/links", {"url": "https://example.org", "x": 1}
        )[0], 400)
        self.assertEqual(self.request(
            "POST", "/shorturl/api/v1/links", {"url": "https://example.org"},
            CONTENT_TYPE="text/plain",
        )[0], 415)
        self.assertEqual(self.request(
            "POST", "/shorturl/api/v1/links", {"url": "https://example.org"},
            CONTENT_LENGTH="9000",
        )[0], 413)
        self.assertEqual(self.request(
            "POST", "/shorturl/api/v1/links", {"url": "https://example.org"},
            HTTP_TRANSFER_ENCODING="chunked",
        )[0], 400)

    def test_rate_limit_is_per_authenticated_instance(self):
        self.app.rate = shorturl.RateLimiter(2, clock=lambda: self.monotonic)
        self.create("https://example.org/1")
        self.create("https://example.org/2")
        status, headers, result = self.create("https://example.org/3")
        self.assertEqual((status, result["error"]), (429, "rate_limited"))
        self.assertIn("Retry-After", headers)
        self.assertEqual(self.request(
            "POST", "/shorturl/api/v1/links",
            {"url": "https://example.org/4"}, token="b" * 64,
        )[0], 201)

    def test_health_is_loopback_route_and_contains_counts_only(self):
        self.create()
        status, _, result = self.request("GET", "/healthz", token="")
        self.assertEqual(status, 200)
        self.assertEqual(set(result), {"ok", "protocol", "links", "hits"})

    def test_database_contains_digest_but_no_bearer_token(self):
        self.create()
        raw = (self.root / "shorturl.sqlite3").read_bytes()
        self.assertNotIn(self.token.encode(), raw)


class ShortURLAdministration(unittest.TestCase):
    def test_live_verifier_rejects_unsafe_inputs_without_exposing_token(self):
        self.assertEqual(
            live_verify.endpoint("https://teuk.org/shorturl/"),
            ("teuk.org", 443),
        )
        for value in (
            "http://teuk.org/shorturl/",
            "https://user@teuk.org/shorturl/",
            "https://teuk.org/other/",
            "https://teuk.org:70000/shorturl/",
        ):
            with self.subTest(value=value):
                with self.assertRaises(RuntimeError):
                    live_verify.endpoint(value)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            credential = root / "dev.token"
            token = "d" * 64
            credential.write_text(token + "\n", encoding="ascii")
            credential.chmod(0o600)
            self.assertEqual(live_verify.credential(credential), token)
            credential.chmod(0o640)
            with self.assertRaises(RuntimeError) as caught:
                live_verify.credential(credential)
            self.assertNotIn(token, str(caught.exception))

    def test_issue_and_revoke_store_hashes_without_printing_tokens(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            storage = root / "service"
            storage.mkdir(mode=0o700)
            dev_credential = root / "dev.token"
            output = io.StringIO()
            with redirect_stdout(output):
                admin.initialize(SimpleNamespace(
                    storage=storage,
                    public_base="https://teuk.org/shorturl/",
                    identity="dev",
                    credential_output=dev_credential,
                    listen_port=8766,
                    requests_per_minute=300,
                    slug_length=10,
                ))
            dev_token = dev_credential.read_text(encoding="ascii").strip()
            self.assertRegex(dev_token, r"^[a-f0-9]{64}$")
            self.assertNotIn(dev_token, output.getvalue())
            self.assertEqual(dev_credential.stat().st_mode & 0o777, 0o600)

            config_path = storage / "control" / "service.json"
            config = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertNotIn(dev_token, config_path.read_text(encoding="utf-8"))
            self.assertEqual(
                config["token_hashes"]["dev"],
                hashlib.sha256(dev_token.encode("ascii")).hexdigest(),
            )

            nbot_credential = root / "nbot.token"
            output = io.StringIO()
            with redirect_stdout(output):
                admin.issue(SimpleNamespace(
                    config=config_path,
                    identity="nbot",
                    credential_output=nbot_credential,
                ))
            nbot_token = nbot_credential.read_text(encoding="ascii").strip()
            self.assertNotIn(nbot_token, output.getvalue())
            config = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertEqual(set(config["token_hashes"]), {"dev", "nbot"})

            with redirect_stdout(io.StringIO()):
                admin.revoke(SimpleNamespace(config=config_path, identity="dev"))
            config = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertEqual(set(config["token_hashes"]), {"nbot"})

    def test_client_configuration_is_atomic_private_and_preserves_other_sections(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            config_path = root / "mediabot.conf"
            original = "[main]\nNICK=mediabotv3\n\n[tinyurl]\nAPI_KEY=legacy\n"
            config_path.write_text(original, encoding="utf-8")
            config_path.chmod(0o640)
            token = "c" * 64
            updated = client_config.configured_text(
                original,
                token,
                "https://teuk.org/shorturl/api/v1/links",
                "https://teuk.org/shorturl/",
            )
            self.assertIn("[shorturl]\n", updated)
            self.assertIn("API_KEY=" + token + "\n", updated)
            self.assertIn("[tinyurl]\nAPI_KEY=legacy\n", updated)

            _, info = client_config.read_regular(config_path)
            backup = client_config.write_once_backup(
                config_path, original.encode("utf-8"), info
            )
            client_config.atomic_replace(config_path, updated.encode("utf-8"), info)
            self.assertEqual(backup.read_text(encoding="utf-8"), original)
            self.assertEqual(config_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_packaging_keeps_backend_local_and_public_health_hidden(self):
        root = Path(__file__).resolve().parent
        unit = (root / "mediabot-shorturl.service.example").read_text()
        apache = (root / "apache-shorturl.conf.example").read_text()
        installer = (root / "install_service.sh").read_text()
        verifier = (root / "verify_live.py").read_text()
        self.assertIn("User=mediabot", unit)
        self.assertIn("IPAddressDeny=any", unit)
        self.assertIn("IPAddressAllow=127.0.0.0/8", unit)
        self.assertIn("ProtectSystem=strict", unit)
        self.assertIn(
            "ProxyPass        /shorturl/ http://127.0.0.1:8766/shorturl/",
            apache,
        )
        self.assertIn("Require method GET HEAD POST", apache)
        self.assertIn('RewriteCond %{HTTP:Transfer-Encoding} !^$', apache)
        self.assertIn("connectiontimeout=3 timeout=5 retry=0", apache)
        self.assertNotIn("healthz", apache)
        self.assertIn("for attempt in $(seq 1 20)", installer)
        self.assertIn('if [ "$health_ok" -ne 1 ]', installer)
        self.assertIn("UNAUTHENTICATED_CREATE=REJECTED", verifier)
        self.assertIn("DESTINATION_BINDING=PASS", verifier)


if __name__ == "__main__":
    unittest.main(verbosity=2)
