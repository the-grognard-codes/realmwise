# Realmwise diagnostics privacy

Diagnostic logging is local-only. Warning, error, and fatal events are retained
by default; informational and debug events require the user to enable diagnostic
options and debug logging. Logs are bounded and rotated (5 MiB normally, 100 MiB
with debug logging enabled).

The optional bundle contains a privacy statement, checksummed sanitized logs,
and an allowlisted environment summary. It excludes catalog records and text,
images, database/backup/export contents, credentials, OAuth data, contact and
account identifiers, host/device names, exact paths, and sensitive URLs. A
bundle is created only after an explicit save action and is never uploaded or
opened automatically. Users should review a bundle before sharing it.
