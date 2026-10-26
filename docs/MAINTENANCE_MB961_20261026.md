# MB961 — Reminder races and scheduled input

## Reproduced defects

1. Delivery selected a due reminder, then a concurrent snooze changed its
   deadline. Delivery's pending-only UPDATE still claimed it and sent the old
   message immediately, despite the confirmed snooze.
2. A snooze could read the old message, then overwrite another snooze completed
   before its UPDATE. Its acknowledgement hid the lost edit.
3. A huge relative delay produced a scientific-notation timestamp. Delivery
   recognizes only digit timestamps, so the malformed tag was treated as due.
   Zero delays were also silently converted to ordinary immediate reminders.
4. Urgent/daily/weekly metadata made an empty message appear non-empty. A
   relative deadline could also push an initially valid message beyond the
   existing 512-character SQL column limit.

## Correction

Delivery and snooze UPDATEs now include the message read in their WHERE
condition. Delivery compares the original stored value, before stripping its
tags. Zero affected rows cannot claim a changed reminder. Snooze retains its
existing fresh-read confirmation for identical no-op writes.

Creation checks text before adding metadata, requires a positive relative
delay with a digit-only timestamp, and checks the final stored length. It
retains the current syntax, recurrence tags, send limit, conditional delivery,
Unicode content and 512-character limit. There is no application schema change.

## Regression

`1337_mb961_reminder_snapshot_and_delay.t` uses two actual SQLite connections
to interleave the real snooze/delivery functions. It runs the module,
`UserCommands` import and public `Mediabot` facade. It also checks invalid
creation inputs, ordinary supported forms, the exact final size boundary,
warning-free refusal and delivery once the postponed deadline is reached.

```bash
perl t/test_commands.pl --filter 'remind|snooze|community|mb961|module_structure' --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```

SQLite is a local regression fixture. No live MariaDB, IRC server or deployed
service was contacted during development. The existing reminder wall-clock
calendar calculations and other command families are outside this change.
