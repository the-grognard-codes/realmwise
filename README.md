# RPG Catalog

RPG Catalog is a local-first Flutter application for cataloging tabletop RPG books and the individual copies a collector owns. It runs on Android, Windows, and Debian-family Linux desktops from a single codebase.

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

## Project map

- `lib/models/` — immutable database and API models.
- `lib/data/` — SQLite schema and persistence.
- `lib/services/` — backups, image files, OpenLibrary/RPGGeek, and app orchestration.
- `lib/screens/` — responsive catalog, add, edit, and settings views.
- `docs/openapi.yaml` — the documented local service contract, importable in Swagger UI.
- `test/` — model and database tests.

## Data and privacy

The primary catalog data and images remain on the device. A supplied RPGGeek API key is stored in the currently open local database and is only sent to RPGGeek requests. OpenLibrary and RPGGeek requests occur only when the user starts a remote search or enrichment.
