
# Feature: 

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


Find out about Android publication.
    Get a manifest of what is required packages, builds, etc.
    Are we relatively up-to-date?
    Is this code ready for publication?

P1 — Android releases use the debug signing key and a placeholder app ID. The authored configuration signs release with the debug keystore and uses com.example.rpg_catalog, undermining production provenance and store readiness. build.gradle.kts (line 17)

Additional release-hardening gaps:

Catalog databases, exports, and selected DB paths are unencrypted; document the privacy model and add safeguards appropriate to shared devices/backups.
The debug API is loopback-only and compile-time disabled by default, so it is not a confirmed production exposure; ensure production builds cannot enable it unintentionally. api_debug_harness.dart (line 24)
Owner name/email can be forwarded to OpenLibrary request headers; obtain consent or remove/redact it.

Add dependency/SBOM and vulnerability scanning to release CI.




1. Finalize the release commit.
   - All pending changes have been published, I am working from a clean main branch.
2. Produce and validate the release artifact.
   - Tests were completed successfully, build completed successfully.  I have 
   - Zip package Realmwise-1.0.0-windows-x64.zip has been created.  
   - I tested on a clean Windows machine launching, restoring, syncing and loading bundle from remote on all three cloud sync providers.
3. Decide your Windows trust model.
   - A ZIP is the simplest direct GitHub option.
   - Authenticode-sign the executable and included native DLLs if possible. It is not strictly required, but unsigned downloads will have weaker Windows/SmartScreen reputation.
   - Publish a SHA256SUMS.txt beside the ZIP so users can verify downloads.
     - ***Clarify and expand on this.  Do I need to get my application signed for release?***
4. Lock down the public-release configuration.
   - Decide whether public binaries include Google/OneDrive/Dropbox OAuth client IDs. Never embed a real client secret; document which sync providers are enabled and how their OAuth apps are configured.
   - ***How would users be able to use cloud sync from the windows app without client id's?  How is a client secret usually handled in this case?***

    My build command is:

        #Use this one for Windows Release Builds
        flutter build windows --release `
        --dart-define=GOOGLE_DRIVE_CLIENT_ID="792779271616-rhlm36vsff8jirqroqsr1ue3lvf7t2ld.apps.googleusercontent.com" `
        --dart-define=GOOGLE_DRIVE_CLIENT_SECRET=<client secret> `
        --dart-define=GOOGLE_DRIVE_REDIRECT_URI=http://127.0.0.1:8765/oauth2callback `
        --dart-define=MICROSOFT_ONEDRIVE_CLIENT_ID="f689c4d7-5fc4-4a50-aee5-da175b97e113" `
        --dart-define=MICROSOFT_ONEDRIVE_TENANT="consumers" `
        --dart-define=MICROSOFT_ONEDRIVE_REDIRECT_URI=http://127.0.0.1:8765/oauth2callback `
        --dart-define=DROPBOX_CLIENT_ID=qiiuadba0azgtr7 `
        --dart-define=DROPBOX_REDIRECT_URI=http://127.0.0.1:8766/oauth2callback

- Complete the security review, including Git history and prior Actions logs—not only current files. Making the repository public exposes all source, history, and Actions logs. [GitHub’s visibility guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)
- Add a SECURITY.md, issue templates, and a brief support/upgrade policy. The README already has privacy, licensing, and third-party-notice material.
    ***These are great callouts, I will work on them***
1. Publish reproducibly.
   - Tag the tested commit as v1.0.0.
   - On GitHub, create a draft release, attach the ZIP and checksums, write release notes, then publish it as the latest release. GitHub supports attaching binary assets directly to releases. [GitHub release instructions](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
   - Make the repo public only after confirming the release page, links, and repository-security settings.
Before v1.1, I’d add GitHub Actions to build/test the pinned Flutter version and generate the ZIP/checksums from a tag. There is currently no tracked release workflow, installer, signing setup, or updater; that is acceptable for a manual v1.0 ZIP release, provided the above manual validation is done.
***These are also great callouts, I will work on them also***


Generate Wiki
Build Release pipelines
Windows software signing
Update keys in the build to PROD.
Validate said keys.
Update all documentation such as README.md.

Test the release build for Windows.

Fix logging on Android builds.