We are nearing a suitable release candidate which can be made available to a small group of testers.  However, before we can do that we need to implement a logging and diagnostic framework so testers and users can report issues with meaningful data.

Make no changes as part of this request, it is a requirements scoping task.

Some key requirements are:

The option for the user to generate a diagnostic bundle.  It would be a .zip file with non-personally identifiable information about the user's system, along with logs from the logging framework to be built out.  

By default, this option should be hidden from users and should be enabled by toggling on a "Enable Diagnostic Options" in the Settings > UI section.  This will expose a new tab in the settings section named "Diagnostics".

Logs that match the severity type of Warn and above should be logged by default even when diagnostics are disabled.  Logs should be rotated and shouldn't consume more than a few megabytes of space under normal conditions.  Debug logging should be able to be toggled on at user option.  These should not consume more than 100 MB of space ever.

Flesh out the requirements for a diagnostic and logging framework given the guidance above and the template which will be submitted under a future request below:

# Feature: Search Characters by Name

## Abstract

## Objective

## Context / Existing Behavior

## In Scope

## Out of Scope

## Functional Requirements

## Acceptance Criteria

## Constraints

## Implementation Guidance

## Validation

## Completion Notes

We are nearing the point where a viable 


Generate diagnostic bundle.




A secured logging method with rotation is required for future 



Sync ownership lost message on restore?  Is this due to bundle restored thinking it is primary?



403 enabling auto sync on OneDrive windows.

On the Android build, during initial setup of Realmwise, when the system doesn't have a database chosen and is prompting for creating or opening a DB or restoring a sync bundle, if the screen is rotated to Horizontal a UI overflow is reported, the buttons do not fit on the screen.


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
