# MB964 — Dictionary callback runtime scope

## Reproduced bugs

`irc.channel.word` supplies the same `InvocationV3` facade used by commands.
Its `command()` accessor contains the event name and `source()` is `event`.
The dictionary bridge previously inferred a command solely from the presence
of that accessor. As a result:

- A retained word-event invocation could start dictionary work after an
  operator quarantined that event.
- An already accepted result could still invoke plugin callback code after
  the event was quarantined. Individual plugin output guards were separate
  protections; the core bridge itself did not suppress the callback.
- Callback exceptions appeared as `command:irc.channel.word`. That resource
  is not a declared command, so an operator could not quarantine the resource
  named by the failure report.

The bridge also recorded callback failures without recording later callback
successes. A recovered resource could retain an active failure streak until
another successful dispatcher call happened to clear it.

## Correction

Use the invocation's event source when it has the shared command accessor;
scheduled-job invocations retain their job name. The existing pre-launch and
completion checks now address the correct `(kind, resource, channel)` tuple.
Successful callbacks clear the matching failure streak through the existing
failure ledger. Recent failure history remains available.

The change is confined to the core dictionary bridge and its documentation.
No command syntax, plugin manifest, scoring rule, dictionary data, database
schema or private configuration is changed. No quarantine is added or reset
automatically. Releasing a resource permits fresh work and does not replay a
completion already discarded while it was quarantined.

## Validation

`1340_mb964_dictionary_callback_scope.t` loads an actual temporary API v3 Perl
package through `RuntimeV3`. It uses the native registry, word observation,
event queue, scheduler, scoped invocations, channel policies, quarantine
registry and failure ledger. Only the dictionary transport is held by a test
fixture so completion can be triggered after an operator action.

The test exercises commands, word events and jobs, including retained
invocations, late quarantine, another channel, unrelated resources, explicit
release, callback exceptions, recovery, off/on policy changes and disable.
Its callback changes package state directly, ensuring suppression is checked
at the core boundary rather than inferred from silent IRC output.

The 67 assertions reproduce 13 failures on the supplied source and pass on
the corrected source. No live dictionary, SQL server or IRC connection is
used by this test.

```bash
perl t/test_commands.pl --filter 'mb959|mb75[12]|mb850|mb964|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
