#!/usr/bin/env python3
"""Private Mediabot URL creation API with public, immutable redirects.

The daemon binds loopback only and is intended to run behind an HTTPS Apache
reverse proxy. Creation requires a per-instance bearer token; resolving an
already-created identifier is deliberately public.
"""

import argparse
from collections import deque
import fcntl
import hashlib
import hmac
import json
import logging
import os
from pathlib import Path
import re
import secrets
import signal
import sqlite3
import stat
import threading
import time
from urllib.parse import urlsplit


LOG = logging.getLogger("mediabot-shorturl")
STOP = threading.Event()
SLUG_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
SLUG_RE = re.compile(r"[23456789A-HJ-NP-Za-km-z]{8,16}")
TOKEN_RE = re.compile(r"[a-f0-9]{64}")
IDENTITY_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}")


class ShortURLError(Exception):
    def __init__(self, code, status=400, retry_after=None):
        self.code = code
        self.status = status
        self.retry_after = retry_after
        super().__init__(code)


def require(value, code="invalid_request", status=400, retry_after=None):
    if not value:
        raise ShortURLError(code, status, retry_after)


def read_private_json(path):
    """Read one small owner-only regular file without following a symlink."""
    path = Path(path)
    require(path.is_absolute(), "absolute_config_required")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ShortURLError("private_config_required") from error
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                "private_config_required")
        require(info.st_uid == os.getuid() and not info.st_mode & 0o077,
                "private_config_required")
        require(info.st_size <= 65536, "config_too_large")
        payload = stream.read(65537)
    require(len(payload) <= 65536, "config_too_large")
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, ValueError) as error:
        raise ShortURLError("invalid_config") from error
    require(isinstance(value, dict), "invalid_config")
    return value


def validate_public_base(value):
    require(isinstance(value, str) and value.isascii() and len(value) <= 512,
            "invalid_public_base")
    require(not re.search(r"[\x00-\x20\x7f]", value), "invalid_public_base")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username
            and not parsed.password and parsed.query == "" and parsed.fragment == ""
            and parsed.path == "/shorturl/",
            "invalid_public_base")
    try:
        parsed.port
    except ValueError as error:
        raise ShortURLError("invalid_public_base") from error
    return value


def validate_target(value, public_base):
    require(isinstance(value, str) and 1 <= len(value) <= 4096,
            "invalid_url", 422)
    require(value.isascii() and not re.search(r"[\x00-\x20\x7f]", value),
            "invalid_url", 422)
    parsed = urlsplit(value)
    require(parsed.scheme in ("http", "https") and parsed.hostname
            and not parsed.username and not parsed.password,
            "invalid_url", 422)
    try:
        parsed.port
    except ValueError as error:
        raise ShortURLError("invalid_url", 422) from error
    require(not (value.startswith(public_base)
                 and SLUG_RE.fullmatch(value[len(public_base):])),
            "already_short", 409)
    return value


def validate_config(config):
    require(config.get("listen_host") == "127.0.0.1", "loopback_only")
    require(type(config.get("listen_port")) is int
            and 1024 <= config["listen_port"] <= 65535,
            "invalid_port")
    validate_public_base(config.get("public_base"))
    require(type(config.get("slug_length")) is int
            and 8 <= config["slug_length"] <= 16,
            "invalid_slug_length")
    require(type(config.get("requests_per_minute")) is int
            and 1 <= config["requests_per_minute"] <= 6000,
            "invalid_rate_limit")

    tokens = config.get("token_hashes")
    require(isinstance(tokens, dict) and 1 <= len(tokens) <= 64,
            "tokens_required")
    require(len(set(tokens.values())) == len(tokens), "distinct_tokens_required")
    require(all(IDENTITY_RE.fullmatch(name) and TOKEN_RE.fullmatch(digest)
                for name, digest in tokens.items()),
            "invalid_token_identity")

    database = config.get("database")
    require(isinstance(database, str) and os.path.isabs(database),
            "absolute_database_required")
    parent = Path(database).parent
    require(parent.is_dir() and not parent.is_symlink(), "private_state_required")
    info = parent.stat()
    require(info.st_uid == os.getuid() and not info.st_mode & 0o077,
            "private_state_required")
    require(not Path(database).is_symlink(), "private_state_required")
    return config


class RateLimiter:
    def __init__(self, limit, clock=time.monotonic):
        self.limit = limit
        self.clock = clock
        self.lock = threading.Lock()
        self.events = {}

    def admit(self, identity):
        now = self.clock()
        with self.lock:
            bucket = self.events.setdefault(identity, deque())
            while bucket and bucket[0] <= now - 60:
                bucket.popleft()
            if len(bucket) >= self.limit:
                retry = max(1, int(61 - (now - bucket[0])))
                raise ShortURLError("rate_limited", 429, retry)
            bucket.append(now)
            if len(self.events) > 128:
                self.events = {name: seen for name, seen in self.events.items()
                               if seen and seen[-1] > now - 60}


class Store:
    def __init__(self, database, public_base, slug_length, clock=time.time):
        self.public_base = public_base
        self.slug_length = slug_length
        self.clock = clock
        self.lock = threading.RLock()
        self.db = sqlite3.connect(database, timeout=5, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA busy_timeout=5000")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA foreign_keys=ON")
        with self.db:
            self.db.execute("""
                CREATE TABLE IF NOT EXISTS links (
                    slug          TEXT PRIMARY KEY,
                    target_url    TEXT NOT NULL,
                    target_sha256 TEXT NOT NULL UNIQUE,
                    client_id     TEXT NOT NULL,
                    created_at    INTEGER NOT NULL,
                    hits          INTEGER NOT NULL DEFAULT 0,
                    last_hit_at   INTEGER
                )
            """)

    def close(self):
        with self.lock:
            self.db.close()

    def _new_slug(self):
        return "".join(secrets.choice(SLUG_ALPHABET)
                       for _ in range(self.slug_length))

    def create(self, identity, target):
        digest = hashlib.sha256(target.encode("ascii")).hexdigest()
        now = int(self.clock())
        with self.lock, self.db:
            row = self.db.execute(
                "SELECT slug FROM links WHERE target_sha256=?", (digest,)
            ).fetchone()
            if row:
                return self._view(row["slug"], target, False)
            for _ in range(32):
                slug = self._new_slug()
                try:
                    self.db.execute(
                        "INSERT INTO links"
                        " (slug,target_url,target_sha256,client_id,created_at)"
                        " VALUES (?,?,?,?,?)",
                        (slug, target, digest, identity, now),
                    )
                    return self._view(slug, target, True)
                except sqlite3.IntegrityError:
                    row = self.db.execute(
                        "SELECT slug FROM links WHERE target_sha256=?", (digest,)
                    ).fetchone()
                    if row:
                        return self._view(row["slug"], target, False)
            raise ShortURLError("identifier_exhausted", 503)

    def _view(self, slug, target, created):
        return {
            "ok": True,
            "protocol": 1,
            "id": slug,
            "url": target,
            "short_url": self.public_base + slug,
            "created": created,
        }

    def resolve(self, slug):
        now = int(self.clock())
        with self.lock, self.db:
            row = self.db.execute(
                "SELECT target_url FROM links WHERE slug=?", (slug,)
            ).fetchone()
            require(row is not None, "not_found", 404)
            self.db.execute(
                "UPDATE links SET hits=hits+1,last_hit_at=? WHERE slug=?",
                (now, slug),
            )
            return row["target_url"]

    def counts(self):
        with self.lock:
            row = self.db.execute(
                "SELECT count(*) AS links,coalesce(sum(hits),0) AS hits FROM links"
            ).fetchone()
            return {"links": int(row["links"]), "hits": int(row["hits"])}


class Application:
    def __init__(self, config, store=None, clock=time.monotonic):
        self.config = validate_config(config)
        self.store = store or Store(
            config["database"], config["public_base"], config["slug_length"]
        )
        self.rate = RateLimiter(config["requests_per_minute"], clock=clock)

    def authenticate(self, environ):
        header = environ.get("HTTP_AUTHORIZATION", "")
        require(header.startswith("Bearer ") and TOKEN_RE.fullmatch(header[7:]),
                "unauthorized", 401)
        candidate = hashlib.sha256(header[7:].encode("ascii")).hexdigest()
        identity = None
        for name, digest in self.config["token_hashes"].items():
            if hmac.compare_digest(digest, candidate):
                identity = name
        require(identity is not None, "unauthorized", 401)
        return identity

    @staticmethod
    def _json(start_response, status, result, retry_after=None, head=False):
        payload = json.dumps(result, ensure_ascii=True, separators=(",", ":")).encode()
        reasons = {
            200: "OK", 201: "Created", 400: "Bad Request",
            401: "Unauthorized", 404: "Not Found", 409: "Conflict",
            413: "Content Too Large", 415: "Unsupported Media Type",
            422: "Unprocessable Content", 429: "Too Many Requests",
            503: "Service Unavailable",
        }
        headers = [
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(payload))),
            ("Cache-Control", "no-store"),
            ("Content-Security-Policy", "default-src 'none'"),
            ("X-Content-Type-Options", "nosniff"),
            ("X-Robots-Tag", "noindex, nofollow"),
        ]
        if retry_after is not None:
            headers.append(("Retry-After", str(int(retry_after))))
        start_response(f"{status} {reasons[status]}", headers)
        return [b"" if head else payload]

    @staticmethod
    def _redirect(start_response, target, head=False):
        headers = [
            ("Location", target),
            ("Content-Length", "0"),
            ("Cache-Control", "private, no-store"),
            ("Referrer-Policy", "no-referrer"),
            ("X-Content-Type-Options", "nosniff"),
            ("X-Robots-Tag", "noindex, nofollow"),
        ]
        start_response("302 Found", headers)
        return [b""]

    def __call__(self, environ, start_response):
        method = environ.get("REQUEST_METHOD", "")
        path = environ.get("PATH_INFO", "")
        head = method == "HEAD"
        try:
            require(not environ.get("HTTP_TRANSFER_ENCODING"), "invalid_framing")
            require(not environ.get("QUERY_STRING"), "invalid_request")

            if method == "GET" and path == "/healthz":
                result = {"ok": True, "protocol": 1, **self.store.counts()}
                return self._json(start_response, 200, result)

            match = re.fullmatch(r"/shorturl/([23456789A-HJ-NP-Za-km-z]{8,16})", path)
            if method in ("GET", "HEAD") and match:
                return self._redirect(
                    start_response, self.store.resolve(match.group(1)), head=head
                )

            require(method == "POST" and path == "/shorturl/api/v1/links",
                    "not_found", 404)
            identity = self.authenticate(environ)
            require(environ.get("CONTENT_TYPE", "").split(";", 1)[0].strip().lower()
                    == "application/json", "json_required", 415)
            size = environ.get("CONTENT_LENGTH", "")
            require(size.isdecimal() and 0 < int(size) <= 8192,
                    "invalid_length", 413)
            payload = environ["wsgi.input"].read(int(size))
            require(len(payload) == int(size), "invalid_length", 400)
            body = json.loads(payload)
            require(isinstance(body, dict) and set(body) == {"url"},
                    "invalid_request")
            target = validate_target(body["url"], self.config["public_base"])
            self.rate.admit(identity)
            result = self.store.create(identity, target)
            LOG.info("client=%s link=%s created=%s",
                     identity, result["id"], int(result["created"]))
            return self._json(start_response, 201 if result["created"] else 200,
                              result)
        except ShortURLError as error:
            return self._json(start_response, error.status,
                              {"error": error.code}, error.retry_after, head=head)
        except (KeyError, TypeError, ValueError, UnicodeDecodeError):
            return self._json(start_response, 400,
                              {"error": "invalid_request"}, head=head)
        except Exception:
            LOG.error("api=internal_error")
            return self._json(start_response, 503,
                              {"error": "unavailable"}, head=head)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    os.umask(0o077)

    config = validate_config(read_private_json(args.config))
    lock = open(config["database"] + ".lock", "a", encoding="ascii")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    application = Application(config)

    def stopping(*_args):
        STOP.set()
        application.store.close()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        from waitress import serve
    except ImportError as error:
        raise ShortURLError("waitress_required") from error
    serve(
        application,
        host="127.0.0.1",
        port=config["listen_port"],
        threads=4,
        connection_limit=64,
        channel_timeout=15,
        cleanup_interval=5,
        max_request_header_size=8192,
        max_request_body_size=8192,
        expose_tracebacks=False,
        ident="mediabot-shorturl",
        clear_untrusted_proxy_headers=True,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        label = error.code if isinstance(error, ShortURLError) else type(error).__name__
        raise SystemExit("shorturl service: " + label)
