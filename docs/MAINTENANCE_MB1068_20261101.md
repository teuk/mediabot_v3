# MB1068 — Lossless typed plugin integers

## Defect

ConfigSchemaV3 validated decimal syntax then returned 0 + value. On 64-bit
Perl, 18446744073709551616 and -9223372036854775809 pass that syntax test but
convert to floating-point values. Four hundred nines become infinity; the
effective JSON is then {"count":Inf}, rather than a valid typed configuration.
The same helper accepts integer values, defaults and minimum/maximum bounds,
so malformed schema bounds can reach manifest validation and channel policy.

## Implementation

After the existing canonical decimal grammar, require native conversion to
round-trip to the same decimal representation. Retain the intentional -0 to
zero normalization. Exact IV/UV values remain accepted, including integers
larger than JavaScript's exact range; do not invent a new fixed global cap.
Reject rounded, non-finite and non-native integers at the existing validation
boundary, before JSON serialization or a channel-policy update.

One shared check covers values, defaults and bounds. Error messages keep their
existing field-based form and do not print the supplied numeric value. The
existing ChannelPolicyV3 validation-before-assignment ordering is retained:
an invalid override cannot replace a previously valid configuration or mode.
String/boolean validation, limits and API capability rules are unchanged.

## Validation and delivery

The existing 1073_mb744_typed_plugin_config.t keeps ten assertions. Group its
three related default checks into one, retaining their original expectations,
and use the two available assertions for exact conversion and rejection paths.
Exercise native positive/negative boundaries selected for the running Perl,
zero/-0, numeric JSON output, schema defaults and bounds, malformed decimals,
positive/negative overflow, 400-digit input and invalid reference values.
Also exercise the real manifest validator and policy update rollback boundary.
No mirrored parser or new test file is added.

Preserve previous fixes, VERSION, private commit.sh, project README, full-suite
runner/ETA, radio and YouTube. No database schema, dependency installation or
configuration file is changed. The operator script runs the visible full suite
with --progress/ETA, audits and inventory, then restarts dev only and invokes
the installed commit.sh with automatic 3.8dev VERSION after complete success.
See package QUALIFICATION.md for the observed results and local limitations.
