#!/usr/bin/env python3
"""Configure one Mediabot instance without exposing its bearer token."""

import argparse
import os
from pathlib import Path
import re
import stat
import tempfile
from urllib.parse import urlsplit


TOKEN_RE = re.compile(r"[a-f0-9]{64}")
SECTION_RE = re.compile(r"^\s*\[([^]\r\n]+)]\s*(?:[#;].*)?$", re.IGNORECASE)


class ConfigurationError(Exception):
    pass


def require(value, message):
    if not value:
        raise ConfigurationError(message)


def read_regular(path, private=False, limit=1024 * 1024):
    path = Path(path)
    require(path.is_absolute(), "absolute path required: " + str(path))
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ConfigurationError("cannot safely open: " + str(path)) from error
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                "regular file required: " + str(path))
        require(info.st_uid == os.getuid(), "file owner mismatch: " + str(path))
        if private:
            require(not info.st_mode & 0o077,
                    "owner-only credential required: " + str(path))
        require(info.st_size <= limit, "file too large: " + str(path))
        payload = stream.read(limit + 1)
    require(len(payload) <= limit, "file too large: " + str(path))
    return payload, info


def section_ranges(lines):
    sections = []
    seen = set()
    for index, line in enumerate(lines):
        match = SECTION_RE.match(line.rstrip("\r\n"))
        if not match:
            continue
        name = match.group(1).strip().lower()
        require(name not in seen, "duplicate section: " + name)
        seen.add(name)
        sections.append((name, index))
    return sections


def configured_text(source, token, api_url, public_base):
    require(TOKEN_RE.fullmatch(token), "invalid credential")
    require(api_url == public_base + "api/v1/links",
            "API URL must be the public base plus api/v1/links")
    require(re.fullmatch(
        r"https://[A-Za-z0-9.-]+(?::[0-9]{2,5})?/shorturl/", public_base
    ),
            "invalid HTTPS public base")
    try:
        urlsplit(public_base).port
    except ValueError as error:
        raise ConfigurationError("invalid HTTPS public base") from error

    lines = source.splitlines(keepends=True)
    if source and not source.endswith(("\n", "\r")):
        lines[-1] += "\n"
    sections = section_ranges(lines)
    positions = {name: index for name, index in sections}
    values = {
        "API_URL": api_url,
        "PUBLIC_BASE_URL": public_base,
        "STATE_FILE": "cache/shorturl-state.json",
        "API_KEY": token,
    }

    if "shorturl" not in positions:
        insert_at = positions.get("tinyurl", len(lines))
        block = ["[shorturl]\n"] + [f"{key}={value}\n" for key, value in values.items()] + ["\n"]
        lines[insert_at:insert_at] = block
        return "".join(lines)

    start = positions["shorturl"] + 1
    end = next((index for _, index in sections if index > positions["shorturl"]), len(lines))
    found = {}
    for index in range(start, end):
        match = re.match(r"^\s*([A-Za-z0-9_]+)\s*=", lines[index])
        if not match:
            continue
        key = match.group(1).upper()
        if key not in values:
            continue
        require(key not in found, "duplicate shorturl key: " + key)
        found[key] = index

    for key, value in values.items():
        if key in found:
            lines[found[key]] = f"{key}={value}\n"
        else:
            lines.insert(end, f"{key}={value}\n")
            end += 1
    return "".join(lines)


def write_once_backup(path, payload, info):
    backup = path.with_name(path.name + ".pre-mb736")
    if backup.exists() or backup.is_symlink():
        _, backup_info = read_regular(backup, private=True)
        require(backup_info.st_uid == info.st_uid, "backup owner mismatch")
        return backup
    descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    return backup


def atomic_replace(path, payload, info):
    descriptor, temporary = tempfile.mkstemp(prefix=".shorturl-client-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--credential", required=True, type=Path)
    parser.add_argument("--public-base", default="https://teuk.org/shorturl/")
    args = parser.parse_args()

    token_raw, _ = read_regular(args.credential, private=True, limit=128)
    try:
        token = token_raw.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise ConfigurationError("credential is not ASCII") from error
    config_raw, config_info = read_regular(args.config)
    try:
        config_text = config_raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConfigurationError("configuration is not UTF-8") from error
    updated = configured_text(
        config_text, token, args.public_base + "api/v1/links",
        args.public_base,
    ).encode("utf-8")

    backup = write_once_backup(args.config, config_raw, config_info)
    atomic_replace(args.config, updated, config_info)
    print("ShortURL client configured: " + str(args.config))
    print("Original configuration backup: " + str(backup))


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except ConfigurationError as error:
        raise SystemExit("shorturl client configuration: " + str(error))
