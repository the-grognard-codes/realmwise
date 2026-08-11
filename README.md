# Realmwise

Realmwise is a local-first Flutter application for cataloging tabletop RPG books and the individual copies a collector owns. It runs on Android, Windows, and Debian-family Linux desktops from a single codebase.

## Highlights

- SQLite database selected, created, opened, closed, and restored from within the app.
- Local image library with ISBN-based filenames, selected cover images, and removable local files.
- Hierarchical catalog: game system → setting → book type → book title.
- OpenLibrary searching and optional RPGGeek enrichment. RPGGeek values take precedence when returned.
- Works when offline: all catalog, edit, search-field suggestions, image, backup, and database features stay available; remote lookups report a useful offline error.
- Periodic crash-recovery database snapshots (every 10 minutes while open).
- Adaptive Material UI for narrow phones and resizable desktop windows.

## Run locally

Install a current [Flutter SDK](https://docs.flutter.dev/get-started/install), then run:

```sh
flutter pub get
flutter run -d windows     # or linux / android
flutter test
```

The app creates an initial database in its application-documents directory. Use **Settings → Database** to create, close, open, or restore a database. Backups are kept alongside the active database in `backups/`.

## Packaging

```sh
flutter build windows
flutter build linux
flutter build apk --release
```

The generated Windows executable is under `build/windows/.../runner/Release`, Linux under `build/linux/.../release/bundle`, and the Android package under `build/app/outputs/flutter-apk`.

## Google Drive manual sync

Google Drive sync is enabled only in builds configured with an OAuth client ID. In the Google Cloud project, enable the Google Drive API, configure the OAuth consent screen (including test users while the app is in testing), and create a **Desktop app** OAuth client. Realmwise's Windows/Linux flow listens on a loopback address; the default is `http://127.0.0.1:8765/oauth2callback`. Desktop OAuth clients support loopback redirects and do not require you to add that URI in the Cloud Console. If you override `GOOGLE_DRIVE_REDIRECT_URI`, use a loopback URI that Realmwise can bind locally (including its port and path).

```sh
flutter run -d windows --dart-define=GOOGLE_DRIVE_CLIENT_ID=your-client-id --dart-define=GOOGLE_DRIVE_REDIRECT_URI=http://127.0.0.1:8765/oauth2callback
```

`GOOGLE_DRIVE_CLIENT_SECRET` may optionally be supplied with `--dart-define` for OAuth clients that require a secret. Desktop OAuth with PKCE normally works without one; a value embedded in a desktop build is not a security boundary.

The app requests the `drive.appdata` scope and stores its sync bundle in Drive's hidden `appDataFolder`; it does not create or use a visible Realmwise folder. This private app-data area is only available to this app, so the same OAuth client/account and app configuration must be used on every device that should share a catalog. Disconnecting removes local credentials and sync settings but does not delete the remote app-data bundle.

For an External consent screen in **Testing**, add every tester explicitly. Google test-user authorizations for this Drive scope—including offline refresh tokens—expire after seven days, so testers will need to reconnect periodically. Use a published production configuration for durable refresh tokens.

Drive sync is a manual copy/recovery mechanism, not a replacement for local backups. Keep the local database and image backups, and use **Settings → Database** export/restore when moving to a different account, OAuth client, or device configuration. Before restoring or switching devices, make sure the target device can authenticate with the same Google account and matching client/redirect settings; otherwise its hidden app-data bundle will not be discoverable.

## Project map

- `lib/models/` — immutable database and API models.
- `lib/data/` — SQLite schema and persistence.
- `lib/services/` — backups, image files, OpenLibrary/RPGGeek, and app orchestration.
- `lib/screens/` — responsive catalog, add, edit, and settings views.
- `docs/openapi.yaml` — the documented local service contract, importable in Swagger UI.
- `test/` — model and database tests.

## Data and privacy

The primary catalog data and images remain on the device. A supplied RPGGeek API key is stored in the currently open local database and is only sent to RPGGeek requests. OpenLibrary and RPGGeek requests occur only when the user starts a remote search or enrichment.
