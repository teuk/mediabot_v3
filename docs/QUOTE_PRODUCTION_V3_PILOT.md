# MB768 — The Quote Vault Visits the Production Great Hall 📚🏰

The `quotes-v3` archive crossed into production without taking the keys from
the old librarian. On nbot `#i/o`, Mediabot loaded the package with exactly
`data.quotes.read`, `data.quotes.write`, `irc.reply` and `irc.notice`, enabled
it, and placed the channel in `observe`.

## Evidence collected

- Doctor reported `ready`, all five commands mounted, complete permissions and
  zero failures.
- One `!q stats` in `observe` produced one historical reply for the two
  existing quotes.
- One bounded `on` window produced one v3 reply, including the same total and
  the detached top-author view.
- The policy immediately returned to `observe`.
- No quote row, schema or historical handler changed.
- A clean restart restored the exact enabled/`observe` posture.
- The disposable Partyline identity was removed.

The accepted marker was
`MB768-NBOT-20260922T163107Z-312684`. Production therefore keeps the new
corridor lit but behind glass: the old handler remains authoritative, and the
three rollback charms are still `policy off`, disable and unload. 🛡️🪄
