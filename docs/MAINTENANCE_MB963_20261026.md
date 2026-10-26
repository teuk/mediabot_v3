# MB963 — Reminder local-calendar deadlines

## Reproduced bug

Daily, weekly and `at HH:MM` reminders used wall-clock differences added to
the current epoch, with fixed 86400-second days. This shifts deadlines when
the local UTC offset changes before the requested time. A daily 09:00 reminder
created on the afternoon before the Paris spring transition became 10:00;
the autumn transition instead made it 08:00. Recurring insertions had the same
defect, including weekly reminders crossing the transition.

## Correction

A private helper advances calendar dates using UTC noon, then resolves the
requested HH:MM with the existing core Time::Local dependency. The server's
local timezone remains authoritative. No timezone setting is changed.

- Retain the existing requirement that the next occurrence be more than sixty
  seconds in the future.
- Retain weekly delivery's rule that the same weekday repeats the next week.
- Resolve a nonexistent local time forward by the DST gap (Paris 02:30 becomes
  03:30 on the spring transition).
- Select the first occurrence of an ambiguous time. After that occurrence has
  passed, schedule the next day/week, avoiding a second daily delivery in the
  repeated hour.
- Preserve elapsed relative delays (`in 1d`, `in 1w`, `tomorrow`) and snoozes.
- Ignore invalid stored recurrence schedules after logging the error, without
  throwing out of the delivery loop or reinserting an invalid deadline.

Stored `[at:epoch]` deadlines are not rewritten by installation. New reminders
and subsequent recurring insertions use the corrected calculation. Command
syntax, pending-state ownership, recurrence tags and SQL schema are unchanged.

## Validation

`1339_mb963_reminder_local_calendar.t` calls the real creation and delivery
functions through CommunityState, UserCommands and the Mediabot facade. Its
SQLite fixture observes the inserted deadlines and actual due-time delivery;
expected dates are independently resolved with DateTime.

Coverage includes Paris spring/autumn changes, UTC, Lord Howe's half-hour DST,
year/month rollover, a leap day, the sixty-second boundary, skipped/repeated
clock hours, daily/weekly reinsertion, elapsed durations and malformed stored
tags. No live SQL/IRC server or running bot is contacted.

```bash
perl t/test_commands.pl --filter 'remind|snooze|community|mb963|module_structure' --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
