# Mediabot command catalogue

MB741 gives every built-in and plugin command one authoritative front door:
`Mediabot::CommandRegistry`.

## Runtime flow

For a public or private command, Mediabot now:

1. normalizes the command name with the IRC-safe case/accent fold;
2. resolves the source-scoped entry in `CommandRegistry`;
3. invokes a direct registry handler, or the frozen adapter named by the
   entry's `metadata.dispatch` value;
4. treats an unregistered name as unknown.

There is no lookup fallback from an unknown registry name into either legacy
hash. Database-backed public commands remain a separate instance-data path
after the built-in catalogue lookup.

## Sources and dispatch kinds

| Source | Dispatch metadata | Meaning |
| --- | --- | --- |
| `public` | `registry` | Native built-in or plugin handler stored in the registry |
| `public` | `legacy-public` | Registered built-in implemented by the frozen public adapter |
| `private` | `legacy-private` | Registered built-in implemented by the frozen private adapter |

The catalogue currently contains 238 public and 94 private built-ins. The four
existing native public handlers are `version`, `uptime`, `help` and `commands`.
All other historical handlers keep their behavior through an explicit adapter
entry.

## Adding a command

A new built-in command must be added as a direct registry definition. It must
not be appended to `%command_map`, `%command_table`, or either frozen adapter
allow-list in `Mediabot::BuiltinCommandCatalog`.

The definition owns its canonical name, source, handler and metadata. Add the
matching internal help entry and focused tests. A plugin uses the same registry
API and must not replace a built-in name.

Run the deterministic inventory check after any catalogue or help change:

```sh
perl tools/mb_architecture_inventory.pl \
  --check docs/generated/COMMAND_INVENTORY.md
```

The tool fails closed when a historical table drifts from its frozen
allow-list. Regenerate the Markdown only when the source change is intentional
and already covered by tests.

## Migration and rollback

Legacy handlers may be migrated one at a time. Move the implementation into a
direct registry handler, change that catalogue entry's dispatch metadata to
`registry`, then remove the corresponding adapter and frozen allow-list entry
in the same tested change.

During MB741 deployment, rollback restores the complete previous source set;
the database and private configuration are untouched. Runtime validation must
confirm exact registry counts, syntax, focused dispatch tests, the fast lane,
service readiness and IRC reconnection before promotion.
