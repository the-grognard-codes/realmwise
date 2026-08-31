
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



P1 — Android releases use the debug signing key and a placeholder app ID. The authored configuration signs release with the debug keystore and uses com.example.rpg_catalog, undermining production provenance and store readiness. build.gradle.kts (line 17)

Additional release-hardening gaps:

Catalog databases, exports, and selected DB paths are unencrypted; document the privacy model and add safeguards appropriate to shared devices/backups.
The debug API is loopback-only and compile-time disabled by default, so it is not a confirmed production exposure; ensure production builds cannot enable it unintentionally. api_debug_harness.dart (line 24)
Owner name/email can be forwarded to OpenLibrary request headers; obtain consent or remove/redact it.

Add dependency/SBOM and vulnerability scanning to release CI.

Release pipeline follow-ups:

- Add automated integration coverage for release-critical real-world flows: first launch and database setup/restore, database migration, cloud-sync conflict/recovery, secure storage, file selection, and camera scanning. Retain a manual smoke-test checklist for physical Windows, Android, and Debian-based Linux devices until those scenarios are automated.
- Keep the initial generic Linux tarball release. Later, evaluate supported-distribution packaging and testing for Debian `.deb` and RPM packages, including desktop metadata and install/upgrade/uninstall behavior.
