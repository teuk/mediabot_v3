# MB1106 — Preserve a password changed during lazy bcrypt migration

Successful login and ident can upgrade historical plaintext and legacy
hashes to bcrypt. The old update filtered by user ID alone. If another
database connection changed that user's password after verification and
before the upgrade, the lazy write could restore the old credential in
bcrypt form.

Both credential reads now include the database's hexadecimal representation
of the stored bytes. The upgrade binds that value in the same conditional
UPDATE that installs the new hash. This tests the original bytes regardless
of the password column's case, accent or padding rules and avoids re-encoding
the stored value on the client. There is no extra query or schema change.
The upgrade is reported only when one row is affected. A failed write logs a
bounded diagnostic without the driver exception.

Lazy migration remains best effort. This change does not revoke a session or
change the result of an authentication attempt that already verified its
credential before the concurrent reset.

The native fixture uses two database connections to the same temporary
SQLite database. It writes a replacement password from the second connection
between verification and upgrade. The fixture checks that both login and
ident preserve that replacement, including a case-only change in a
case-insensitive column. It also checks normal migration, already migrated
accounts, failed verification and a rejected SQL write. This fixture requires
SQLite and Crypt::Bcrypt and does not access a live instance.
