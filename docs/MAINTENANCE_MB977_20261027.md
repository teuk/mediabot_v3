# MB977 — Confirm native quote rankings

Native topquote and halloffame now reject failed or partial SQL results, finish allocated cursors and contain errors in the legacy fallback. Confirmed empty listings retain their existing message. The recent-quotes fallback remains available, including on an actual schema without hits.

The regression uses real registry handlers and read-only SQLite, both DBI error modes, partial and empty failed fetches, legacy schemas and cleanup faults. All 1,016 assertions pass; 360 fail before the fix.
