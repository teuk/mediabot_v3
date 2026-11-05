# MB1113 — Publish top sayings only after a complete read

A failed fetch from the !topsay query could look like the end of the
result set. The command could publish a partial ranking or say that
there were no results, then record the command as successful. Prepare
and execute failures also did not give the caller a useful response.

The command now checks the cursor's error state before closing it.
It closes the statement before formatting replies. If preparation,
execution or reading fails or throws, the caller receives one private
database notice. No ranking, empty response or success audit is emitted.

The query, the 30-row limit, authorization and pagination are unchanged.
The existing command fixture checks one clean empty result, failures
before or after the first row, and a thrown fetch error. The prior
authorization, alias, pagination and compatibility checks still run.

No schema, configuration or dependency change.
