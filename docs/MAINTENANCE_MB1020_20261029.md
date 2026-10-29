# MB1020 — MixCloud public-show previews

## Request and implementation

Add public previews for shared Mixcloud show URLs and an independent `MixCloud`
chanset. The supplied example resolves through the official read-only API to
`Shut Up And Dance !`, creator `Leekid`, duration 7,576 seconds. The public API
was read directly during development; live IRC delivery remains an operator
check after installation.

`External/MixCloud.pm` owns validation, bounded JSON metadata parsing, output
and supervised worker delivery. The existing URL router selects it before the
generic title path. Its badge is white on navy and includes the mixer emoji.
Title, creator and optional duration fit one sanitized 400-byte IRC line.

An authorized native chanset command registers the missing catalogue name and
enables that one channel. There is no table-definition change, migration,
private configuration edit or automatic opt-in. Existing channel authorization
still runs before registration. A missing row, failed SQL read or disabled
flag is off, independently of UrlTitle.

Requests use one fixed HTTPS API origin with certificate verification, no
redirects, 8-second HTTP timeout and 256 KiB response limit. AsyncWorker imposes
a 12-second overall deadline. Bounded caches, pending requests and start rates
limit work; tracking parameters cannot split identities. Completion validates
the detached result and rechecks policy, connection and join generation.

Diagnostics include the new observation. The bundled web projection treats
only an absent new MixCloud field as unknown for backward compatibility;
existing mandatory fields retain their validation. This package does not
deploy the running web application.

## Qualification

Fourteen focused assertions cover canonical links, unsafe and unsupported
paths, actual chanset authorization and SQLite writes, missing/failed SQL,
UTF-8 metadata, exact show identity, HTTP limits/failures, output sanitization,
independent routing, real AsyncWorker delivery, revocation, duplicate sharing,
cache reuse, resource bounds and native Perl/Node diagnostic projection.
Fixtures contact no real IRC or database service. The separate public API
check uses the supplied show and contains no credential.

```bash
perl t/test_commands.pl --filter 'mb1020|url|spotify|applemusic|reddit|chanset|diagnostic|module_structure' --progress
(cd contrib/mbweb && npm test)
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The package README records actual qualification results and any baseline
environment failures. The operator procedure stops on failure, restarts only
development after successful checks, then calls the native commit helper.
`playRadio()`, YouTube details and the root README remain unchanged. No release
version, tag, production deployment or live IRC success is claimed here.
