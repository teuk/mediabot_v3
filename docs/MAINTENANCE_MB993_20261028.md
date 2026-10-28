# MB993 — Preserve roll options with the default dice

Base: `snap_mediabot_v3_teuk_20261028_151545.zip`, VERSION
`3.6dev-20261028_141534`. Previous fixes, including MB992 and French Trivia,
are already present in this snapshot.

## Reproduced defect

Native roll and playful-v3 always skipped the first argument when reading
modifiers and advantage/disadvantage. This was correct with an explicit dice
token, such as `1d20`, but discarded a real option when using the default 1d6:

```text
roll +2        -> bonus ignored
roll adv       -> one draw instead of two
roll +2 adv    -> advantage applied, bonus ignored
```

Each parser now consumes an argument only when it specifies NdN dice or a
numeric side count. Remaining arguments are parsed as options, including the
first one when no dice token was supplied. No arguments are removed from the
original Context or v3 invocation: both handlers operate on local copies.

The no-argument 1d6 default, explicit NdN/numeric-side forms, modifier bounds
(-100 to +100), IRC strike-through rendering of the discarded die, native
audit behavior, and channel-scoped five-entry histories keep their semantics.
Random generation is unchanged. playful-v3 advances from 1.0.1 to 1.0.2;
activation, authority, configuration, other commands and jobs are unchanged.
No SQL, dependency, Trivia or production deployment change is included.

## Verification

The regression has 17 focused assertions using the actual registered native
roll handler and real PluginContext/InvocationV3 objects. Fixed draws check
exact outcomes and ranges without statistical expectations or seeding the
process. Tests cover omitted and explicit dice, signed modifiers, advantage
and disadvantage, clamping, preserved arguments, native audit entries and
bounded histories in two channels. Test-only draw overrides remain local to
the regression process.

Eight assertions fail on the original runtime. After correcting native roll
alone, the same eight assertions still fail against the unmodified v3 path,
so neither implementation masks the other. All 17 pass with both corrected.

The delivery README records targeted and complete suite results, security
audit, startup integrity and generated command-inventory verification.
The user procedure runs the entire suite with --progress, stops on any
failure, restarts dev only, then invokes the native commit/push script.
