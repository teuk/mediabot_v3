# MB1127 — Reminder cancellation

`!remind cancel` and `!tell cancel` now share one implementation. Both
accept one ID or `all`, and reject extra arguments before writing. An
ID is validated as a positive unsigned 64-bit value without rounding.

One SQL update checks the sender and pending state together. Both
forms mark matched rows cancelled (2); delivered rows retain state 1
and unrelated rows are untouched. Bulk cancellation still spans all
channels for the calling nick. A repeated bulk request reports zero.

Database failures produce a private, generic notice. Statement cleanup
is attempted even after an error, and a cleanup exception cannot change
an already confirmed row count. Successful cancellations retain the
audit action. The existing reminder test exercises both IRC registry
handlers against SQLite, including DBI exceptions and false returns.
No migration or configuration change is required.
