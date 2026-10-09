# Fuji San private error reports

Production: `https://reikop.io/fuji-san/report.php` and `admin.php`.
PHP 8.2+, no database or external service required. The existing website is not changed.

## Deployment

Copy only `common.php`, `report.php`, `admin.php`, `style.css`, `.htaccess`,
`private/index.php`, and `private/.htaccess` to a dedicated `/fuji-san/` directory.
Copy `config.example.php` to `config.php` and generate a unique password hash with
`password_hash($password, PASSWORD_DEFAULT)` and a random 32-byte `rate_secret`.
Never commit `config.php`, report files, or the administrator password.
The administrator signs in at `admin.php` with the generated password; no username is required.
To rotate the password, replace the hash in `config.php`. Sessions expire after one hour.

Grant the PHP service account write/rename/delete access **only** to `private/`.
On the deployed Synology server, the PHP service uses UID/GID 1023. Its existing group
receives Modify + DeleteChild permissions on this dedicated directory, leaving the
application code, configuration and the rest of the website read-only to PHP.

Every data file is a `.php` file starting with a 404/exit/`__halt_compiler()` guard;
report content is never included as executable PHP. Apache access denial is an additional
layer. Deployment must verify direct report URLs return 403/404 without their contents.
Do not configure the server to serve PHP source files as static text.

## Data and limits

- Explicit opt-in report submission; no embedded API secret in the public app.
- Allowed fields: app/OS version, camera model/firmware/transport, error, stack,
  last 120 diagnostic events, user description, optional reply email.
- Device IDs, serial numbers, recipe names, photos and raw USB payloads are excluded.
  Client redaction and a second server redaction pass mask known secrets, paths,
  emails in descriptions, IPv4 addresses, USB identifiers and credential patterns.
  Redaction is best-effort; users review the exact report before sending.
- 256 KiB request limit, strict field validation, 20 submissions per network address
  per hour, at most 2,000 stored reports. No attachment upload.
- Address identities for rate limits use a keyed HMAC; raw addresses are not stored
  in reports. Existing web-server/proxy access logs are outside this application's control.
  Forwarded headers are not trusted; behind a proxy, limits may apply to the shared peer.
- Retries use the same random report ID; duplicates are acknowledged without overwriting.
- Reports older than 30 days are removed on the next submission or admin request.
  Rate-limit files expire after two days. This is request-triggered cleanup, not a cron job.
- Admin login has a separate 10-attempt/15-minute limit, Secure/HttpOnly/SameSite session
  cookies, CSRF protection, escaped output, private JSON downloads and per-report deletion.
  Reports are untrusted user input, not authenticated evidence of a camera defect.
- No email notifications or public GitHub issue creation. Review reports in the dashboard.

## Verification

`php server/tests.php` checks validation, redaction and guarded storage using synthetic data.
`powershell -File tool/test_report_server.ps1 -CredentialFile <local-credentials-file>` checks
the deployed HTTPS service, retry deduplication, consent/size rejection, authentication,
direct-file access, escaping, redaction and deletion. It submits synthetic reports only.
Credentials use the local format `Password: <generated password>` and must remain private.

The Flutter app catches operational errors, camera-save errors, library-load errors and
Flutter/Dart unhandled errors. Native process termination, OS crashes and errors before
Flutter initialization cannot show this report dialog. Recent logs are in memory only;
an unsent report is not automatically retried or uploaded after the app exits.
