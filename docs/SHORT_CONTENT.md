# VDM and DansTonChat commands

Use these public commands from a channel where the corresponding feature is
allowed: `+VDM` for VDM, `+DansTonChat` for DansTonChat. Existing command flood
controls and output budgets still apply.

| Command | Result |
| --- | --- |
| `!vdm` | One recent item from the official VDM feed, excluding recent repeats |
| `!vdm 304759` | The VDM article numbered 304759 |
| `!dtc` or `!bashfr` | A random DansTonChat quote |
| `!dtc 20000` or `!bashfr 20000` | The DansTonChat quote numbered 20000 |
| `!dtc linux` or `!bashfr linux` | A text search followed by the first matching quote |

Use a positive decimal ID of at most 12 digits. VDM accepts one optional ID;
additional arguments or text receive a usage message. DansTonChat also keeps
its existing parenthesised numeric form and text search.

A numbered request never falls back to a recent or random item. A missing ID,
a redirect to another quote, ambiguous page content or a source failure produces
an error. VDM errors are notices to the requester; DTC errors appear in-channel.

VDM checks channel authorization and connection again when the worker completes.
Simultaneous requests share work only when they ask for the same ID or the same
recent feed. Different IDs cannot receive one another's results. At most four
VDM source workers and sixteen waiting callers are active at once.

An explicit VDM ID can be requested again within the two-minute recent-feed
repeat window. Successfully displayed IDs still count as recent for bare `!vdm`
and Spark. No channel setting or database migration is required by this change.

The `!` examples use the public command prefix; substitute your instance's
configured prefix where necessary. `!help vdm`, `!help dtc` and `!help bashfr`
show the corresponding command forms.
