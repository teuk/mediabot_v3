# Mediabot command catalogue

MB741 gave every built-in and plugin command one authoritative name catalogue.
MB749 completes that convergence: `Mediabot::CommandRegistry` now owns the
executable handler for every built-in as well.

## Runtime flow

For a public or private command, Mediabot now:

1. normalizes the command name with the IRC-safe case/accent fold;
2. resolves the source-scoped entry in `CommandRegistry`;
3. invokes the handler stored in that registry entry;
4. treats an unregistered name as unknown.

There is no compatibility dispatch hash and no second handler lookup.
Database-backed public commands remain a separate instance-data path after the
built-in catalogue lookup.

## Sources and dispatch kinds

| Source | Dispatch metadata | Meaning |
| --- | --- | --- |
| `public` | `registry` | Built-in handler stored in the registry |
| `private` | `registry` | Built-in handler stored in the registry |
| `public` | `plugin-v3` | Mounted plugin handler stored in the registry |

The catalogue currently contains 238 public and 94 private built-ins, all with
CODE handlers. The compatibility exports `legacy_public_adapter_names()` and
`legacy_private_adapter_names()` remain for out-of-tree tooling but return
empty lists.

## Adding a command

A new built-in command must be added to `Mediabot::BuiltinCommandCatalog` and
to the corresponding registry-native handler catalogue in `Mediabot.pm`.

The definition owns its canonical name, source, handler and metadata. Add the
matching internal help entry and focused tests. A plugin uses the same registry
API and must not replace a built-in name.

Run the deterministic inventory check after any catalogue or help change:

```sh
perl tools/mb_architecture_inventory.pl \
  --check docs/generated/COMMAND_INVENTORY.md
```

The tool fails closed when a handler catalogue drifts from its declared names.
Regenerate the Markdown only when the source change is intentional and already
covered by tests.

## Migration and rollback

An eligible public built-in may still be shadowed by an official v3 package
through the named `legacy-public-fallback` protocol. The name is retained for
manifest compatibility, but MB749 captures the previous registry handler at
mount time: disabled, `off` and `observe` call that saved CODE reference, and
unload restores the exact registry entry. The main dispatcher knows nothing
about migration fallback.

During MB749 deployment, rollback restores the complete previous source set;
the database and private configuration are untouched. Runtime validation must
confirm exact registry counts, syntax, focused dispatch tests, the fast lane,
service readiness and IRC reconnection before promotion.
