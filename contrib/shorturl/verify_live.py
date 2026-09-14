#!/usr/bin/env python3
"""Verify the public HTTPS ShortURL contract without exposing credentials."""

import argparse
import http.client
import json
import os
from pathlib import Path
import re
import ssl
import stat
from urllib.parse import urlsplit


TOKEN_RE = re.compile(r"[a-f0-9]{64}")
SLUG_RE = re.compile(r"[23456789A-HJ-NP-Za-km-z]{8,16}")


def fail(message):
    raise RuntimeError(message)


def credential(path):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink():
        fail("unsafe credential path")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise RuntimeError("cannot open credential safely") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail("credential must be one regular file")
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            fail("credential must be owner-only")
        if info.st_size > 128:
            fail("credential is too large")
        raw = os.read(descriptor, 129)
    finally:
        os.close(descriptor)
    try:
        token = raw.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise RuntimeError("invalid credential") from error
    if not TOKEN_RE.fullmatch(token):
        fail("invalid credential")
    return token


def endpoint(public_base):
    if not re.fullmatch(
            r"https://[A-Za-z0-9.-]+(?::[0-9]{2,5})?/shorturl/",
            public_base):
        fail("invalid public base")
    parsed = urlsplit(public_base)
    if (parsed.scheme != "https" or not parsed.hostname
            or parsed.username or parsed.password
            or parsed.path != "/shorturl/"
            or parsed.query or parsed.fragment):
        fail("invalid public base")
    try:
        port = parsed.port or 443
    except ValueError as error:
        raise RuntimeError("invalid public base") from error
    if not 1 <= port <= 65535:
        fail("invalid public base")
    return parsed.hostname, port


def exchange(host, port, method, path, body=b"", headers=None):
    connection = http.client.HTTPSConnection(
        host, port, timeout=8, context=ssl.create_default_context()
    )
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        payload = response.read(8193)
        if len(payload) > 8192:
            fail("HTTPS response is too large")
        return response.status, dict(response.getheaders()), payload
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--credential", required=True, type=Path)
    parser.add_argument("--public-base", default="https://teuk.org/shorturl/")
    args = parser.parse_args()

    token = credential(args.credential)
    host, port = endpoint(args.public_base)
    api_path = "/shorturl/api/v1/links"
    target = "https://example.org/mediabot-shorturl-live-probe"
    body = json.dumps({"url": target}, separators=(",", ":")).encode("ascii")
    common = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": "Mediabot-ShortURL-Live-Verify/1",
    }

    status, _, _ = exchange(host, port, "POST", api_path, body, common)
    if status != 401:
        fail("unauthenticated creation was not rejected")
    print("UNAUTHENTICATED_CREATE=REJECTED")

    headers = dict(common)
    headers["Authorization"] = "Bearer " + token
    status, _, payload = exchange(host, port, "POST", api_path, body, headers)
    if status not in (200, 201):
        fail("authenticated creation failed with HTTP " + str(status))
    try:
        result = json.loads(payload)
    except (UnicodeDecodeError, ValueError) as error:
        raise RuntimeError("invalid creation response") from error
    identifier = result.get("id")
    if (result.get("ok") is not True or result.get("protocol") != 1
            or result.get("url") != target
            or not isinstance(identifier, str)
            or not SLUG_RE.fullmatch(identifier)
            or result.get("short_url") != args.public_base + identifier):
        fail("creation response contract mismatch")
    print("AUTHENTICATED_CREATE=PASS")
    print("IDENTIFIER=" + identifier)

    status, headers, payload = exchange(
        host, port, "GET", "/shorturl/" + identifier
    )
    location = next(
        (value for name, value in headers.items() if name.lower() == "location"),
        "",
    )
    if status != 302 or location != target or payload:
        fail("public redirect contract mismatch")
    print("PUBLIC_REDIRECT=PASS")
    print("DESTINATION_BINDING=PASS")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit("shorturl live verification: " + str(error))
