# MB869 — speed up the complete test suite

This round reduces repeated setup work and idle fixture waits. The normal
command remains:

```bash
perl t/test_commands.pl --progress
```

It continues to execute every discovered test file, in lexical order, with
the existing native-closure / standalone-TAP isolation, assertion accounting,
failure diagnostics and exit status. No result is reused from a previous run.

## Remove repeated capability scans

Previously, every launcher invocation read and classified all test sources,
including invocations filtered to a single case. Runner regressions repeatedly
launch filtered subprocesses, multiplying this otherwise unused work.

The launcher now filters names first. It reads capability metadata only for
matching candidates when `--fast`, `--class`, `--exclude-class`,
`--class-summary` or `--list-selected` needs those tags. Plain full or filtered
execution inspects each file's isolation contract immediately before running
it, as before, without the extra capability pass.

Fast-lane sentinel existence is still checked against the complete discovered
catalogue before a filename filter can narrow execution. Source metadata is
fresh on every invocation; there is no persistent classification cache.

## Remove idle waits in existing fixtures

- The MB380 and MB381 CPAN fixtures already fake the installer, Perl, root UID
  and download/build commands. Their fake command directory now also includes
  a no-op `sleep`, avoiding a five-second progress-spinner pause around a
  local fake helper. The actual launch, PID polling, wait, status and filesystem
  permission assertions remain in place. The shipped installer is unchanged.
- The network-statistics HTTP/TLS fixtures run their server loop with a 10 ms
  idle shutdown poll instead of the library default. They still make real
  local HTTP and TLS requests, test certificate verification and retry queues,
  call shutdown and close the server. Request and TLS timeouts are unchanged;
  the production server is unchanged.

## Verify behavior and measure locally

`1283_mb869_test_runner_lazy_selection.t` runs the actual launcher against a
private miniature catalogue. A wrapper around the real classifier records
which files are read. Its 36 assertions verify complete coverage, native/TAP
counts, capability selection/exclusion, filtered catalogue summaries, mandatory
sentinels, fresh classification after a source edit and nonzero failure exits.
The assertions do not depend on machine speed. Fixtures live outside the real
case directory, so they cannot be collected by another test run.

To inspect the remaining bottlenecks:

```bash
perl t/test_commands.pl --progress --profile --profile-top 20
```

The complete measured before/after results, environment limitations and
installation rehearsal are in the delivery package's `QUALIFICATION.md`.
Measurements concern one local environment; compare the time printed by the
same full-suite command on the target server before drawing a server-specific
speedup conclusion.

This round changes test tooling and fixtures only. It changes no application
module, database schema, migration, runtime setting or production timeout.
