In the Settings > Cloud Sync tab, after selecting a Cloud provider and choosing to Connect, "Connecting to DropBox" is appears to always be displayed regardless of the Provider chosen. 


The settings section will look better if we rename the categories to the following:
Interface > Interface
Local Database > Database
Cloud Sync > Cloud Sync
Data Sources > Sources

In the Settings > Cloud Sync tab, the default Device ID should be  based on the device hostname (limited to 12 characters).  
Device ID can be a UUID behind the scenes if needed.

In the Settings > Sources tab, add a small section detailing enrichment gained from using RPGGeek API, as well as a link to the RPGGeek API application page.

In the Settings > Sources tab, add a section noting that Open Library is a non-profit 501(c)(3) digital library project operated by the Internet Archive.  While they provide access to their API for free, they do ask that users supply a name and email address.  This is optional and will never be sent to Realmwise.  Then add a text field for Name and Email Address and a save button.  This should update the API payloads sent to OpenLibrary with the details.

403 enabling auto sync on OneDrive windows.

On the Android build, during initial setup of Realmwise, when the system doesn't have a database chosen and is prompting for creating or opening a DB or restoring a sync bundle, if the screen is rotated to Horizontal a UI overflow is reported, the buttons do not fit on the screen.

In the Settings > Interface section, make the default theme Dungeon Black.  Remove the themes Rose Spell and Moonstone and create two new themes.  One which is high-contrast dark, and another which is suitable for users that are color blind.

For Android builds, the application icon in the Android UI is the default flutter icon.  Update the icon to the thumbnail of the correct pixel size in assets/branding/publication

Add a high contrast and color blindness friendly theme.  Remove moonstone and rose spell.  

Add normal structured download diagnostics with the planned logging feature.

Add default and debug level logging feature.
    Any logging built in by default?
    Toggle in the UI
    Add normal structured download diagnostics with the planned logging feature.
    
Find out about Android publication.
    Get a manifest of what is required packages, builds, etc.
    Are we relatively up-to-date?
    Is this code ready for publication?

Fix the file upload on Android for images

Add support for Google Books API, and maybe Library of Congress?
    Complete data enrichment.

P1 — Android releases use the debug signing key and a placeholder app ID. The authored configuration signs release with the debug keystore and uses com.example.rpg_catalog, undermining production provenance and store readiness. build.gradle.kts (line 17)

Additional release-hardening gaps:

Catalog databases, exports, and selected DB paths are unencrypted; document the privacy model and add safeguards appropriate to shared devices/backups.
The debug API is loopback-only and compile-time disabled by default, so it is not a confirmed production exposure; ensure production builds cannot enable it unintentionally. api_debug_harness.dart (line 24)
Owner name/email can be forwarded to OpenLibrary request headers; obtain consent or remove/redact it.

Add dependency/SBOM and vulnerability scanning to release CI.
