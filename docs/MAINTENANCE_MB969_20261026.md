# MB969 — Quote read confirmation

## Problem

The API v3 quote service caught exceptions from its fetch loop but did not
inspect DBI's statement error. With `RaiseError=0`, a failed fetch returns an
undefined row just like normal end of results. The service could consequently
publish an incomplete search, an incorrect empty response or partial quote
statistics. An individual quote returned before a subsequent fetch failure
could also reach the existing recall-accounting path.

## Fix

Inspect the statement error after the fetch loop and before finishing the
cursor. An unconfirmed read follows the existing fixed service-error path;
the runtime and official plugin already render the appropriate database-error
notice. Collected rows are discarded and later queries are not attempted.

The shared boundary covers `by_id`, `count`, `random`, `search`, `by_author`,
`random_by_author`, `stats` and `top`, including each stage of operations that
perform two queries. Confirmed empty results and healthy results retain their
existing representation. Bounds, channel scope, authorization, SQL queries,
database schema, configuration and plugin activation are unchanged.

## Regression coverage

`t/cases/1345_mb969_quote_fetch_confirmation.t` runs actual SQLite statements
against multiple channels. A DBI subclass injects failures before any row or
after one row under both `RaiseError` modes, including the second query of
random selection and statistics. Cursor cleanup deliberately clears the DBI
error to prove that it is inspected first.

The test also loads the official `quotes-v3` package through PluginManager,
activates its existing command bridge on a disposable test channel and checks
error notices, withheld partial public output, no recall-accounting calls on
failed reads, fixed runtime logs and successful recovery on the next command.
Only the irrelevant accounting sink is replaced by a call-counting probe.

```sh
perl t/test_commands.pl --filter 'quote|mb969|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
