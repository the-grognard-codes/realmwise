Add default and debug level logging feature.
    Any logging built in by default?
    Toggle in the UI

Revise the category image to be a small square rather than circle.  Update the focus zoom sliders to account for this.

Cloud storage syncing.
    Scope
    Support for Google Drive, One-Drive, Dropbox

Find out about Android publication.
    Get a manifest of what is required packages, builds, etc.
    Are we relatively up-to-date?
    Is this code ready for publication?



Fix the file upload on Android for images

Add support for Google Books API, and maybe Library of Congress?
    Complete data enrichment.


    
P1 — Android releases use the debug signing key and a placeholder app ID. The authored configuration signs release with the debug keystore and uses com.example.rpg_catalog, undermining production provenance and store readiness. build.gradle.kts (line 17)


P2 — Remote image downloads accept arbitrary HTTP(S) URLs, including private/local targets, with unbounded in-memory downloads and no content validation. This enables plaintext interception, local-network requests, and memory/disk exhaustion on Windows, Linux, and Android. Require HTTPS, block local/private addresses after redirects, stream with size caps, and validate image content. image_storage_service.dart (line 66)

Additional release-hardening gaps:

Catalog databases, exports, and selected DB paths are unencrypted; document the privacy model and add safeguards appropriate to shared devices/backups.
The debug API is loopback-only and compile-time disabled by default, so it is not a confirmed production exposure; ensure production builds cannot enable it unintentionally. api_debug_harness.dart (line 24)
Owner name/email can be forwarded to OpenLibrary request headers; obtain consent or remove/redact it.
Add dependency/SBOM and vulnerability scanning to release CI.
