#!/usr/bin/env python3
"""Initialize and administer Mediabot ShortURL without printing credentials."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import tempfile

from shorturl_service import (IDENTITY_RE, ShortURLError, Store,
                              read_private_json, require, validate_config,
                              validate_public_base)


def private_directory(path):
    path = Path(path)
    require(path.is_absolute() and path.is_dir() and not path.is_symlink(),
            "private_directory_required")
    info = path.stat()
    require(info.st_uid == os.getuid() and not info.st_mode & 0o077,
            "private_directory_required")
    return path


def atomic_json(path, value):
    path = Path(path)
    require(path.is_absolute() and path.parent.is_dir()
            and not path.parent.is_symlink() and not path.is_symlink(),
            "private_config_required")
    descriptor, temporary = tempfile.mkstemp(prefix=".shorturl-config-",
                                             dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
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


def write_credential(path, token):
    path = Path(path)
    require(path.is_absolute() and not path.exists() and not path.is_symlink(),
            "new_credential_path_required")
    parent_info = path.parent.stat()
    require(path.parent.is_dir() and not path.parent.is_symlink()
            and parent_info.st_uid == os.getuid()
            and not parent_info.st_mode & 0o022,
            "credential_parent_required")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as stream:
        stream.write(token + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def new_token():
    token = secrets.token_hex(32)
    return token, hashlib.sha256(token.encode("ascii")).hexdigest()


def initialize(args):
    storage = private_directory(args.storage)
    control = storage / "control"
    state = storage / "state"
    require(not control.exists() and not state.exists(), "state_already_initialized")
    control.mkdir(mode=0o700)
    state.mkdir(mode=0o700)
    identity = args.identity
    require(IDENTITY_RE.fullmatch(identity), "invalid_token_identity")
    public_base = validate_public_base(args.public_base)
    token, digest = new_token()
    config = {
        "database": str(state / "shorturl.sqlite3"),
        "listen_host": "127.0.0.1",
        "listen_port": args.listen_port,
        "public_base": public_base,
        "requests_per_minute": args.requests_per_minute,
        "slug_length": args.slug_length,
        "token_hashes": {identity: digest},
    }
    validate_config(config)
    atomic_json(control / "service.json", config)
    write_credential(args.credential_output, token)
    print("ShortURL initialized: " + str(control / "service.json"))
    print("Credential written once: " + str(args.credential_output))


def issue(args):
    config = validate_config(read_private_json(args.config))
    require(IDENTITY_RE.fullmatch(args.identity), "invalid_token_identity")
    require(args.identity not in config["token_hashes"], "identity_exists")
    token, digest = new_token()
    config["token_hashes"][args.identity] = digest
    validate_config(config)
    write_credential(args.credential_output, token)
    try:
        atomic_json(args.config, config)
    except Exception:
        Path(args.credential_output).unlink(missing_ok=True)
        raise
    print("Credential issued for: " + args.identity)
    print("Credential written once: " + str(args.credential_output))
    print("Restart mediabot-shorturl.service to load the new token hash.")


def revoke(args):
    config = validate_config(read_private_json(args.config))
    require(args.identity in config["token_hashes"], "unknown_identity")
    require(len(config["token_hashes"]) > 1, "last_identity_required")
    del config["token_hashes"][args.identity]
    atomic_json(args.config, config)
    print("Credential revoked for: " + args.identity)
    print("Restart mediabot-shorturl.service to enforce revocation.")


def list_identities(args):
    config = validate_config(read_private_json(args.config))
    for identity in sorted(config["token_hashes"]):
        print(identity)


def inspect(args):
    config = validate_config(read_private_json(args.config))
    store = Store(config["database"], config["public_base"], config["slug_length"])
    try:
        counts = store.counts()
    finally:
        store.close()
    print("IDENTITIES=" + str(len(config["token_hashes"])))
    print("LINKS=" + str(counts["links"]))
    print("HITS=" + str(counts["hits"]))


def parser():
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init")
    init.add_argument("--storage", type=Path,
                      default=Path("/var/lib/mediabot-shorturl"))
    init.add_argument("--public-base", required=True)
    init.add_argument("--identity", default="dev")
    init.add_argument("--credential-output", required=True, type=Path)
    init.add_argument("--listen-port", type=int, default=8766)
    init.add_argument("--requests-per-minute", type=int, default=300)
    init.add_argument("--slug-length", type=int, default=10)
    init.set_defaults(function=initialize)

    for name, function in (("issue", issue), ("revoke", revoke),
                           ("list", list_identities), ("inspect", inspect)):
        command = commands.add_parser(name)
        command.add_argument("--config", type=Path,
                             default=Path("/var/lib/mediabot-shorturl/control/service.json"))
        if name in ("issue", "revoke"):
            command.add_argument("--identity", required=True)
        if name == "issue":
            command.add_argument("--credential-output", required=True, type=Path)
        command.set_defaults(function=function)
    return result


if __name__ == "__main__":
    os.umask(0o077)
    arguments = parser().parse_args()
    try:
        arguments.function(arguments)
    except Exception as error:
        label = error.code if isinstance(error, ShortURLError) else type(error).__name__
        raise SystemExit("shorturl admin: " + label)
