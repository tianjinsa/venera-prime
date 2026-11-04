# Backup import white screen

## Device evidence

- Android device: TAS-AN00; installed Prime version: 2.6.2 (2622).
- White screen reproduced by cold-starting the installed application without
  clearing its data or reinstalling it.
- Flutter logs were suppressed by the device's global `persist.log.tag=M`.
  Temporarily enabling `log.tag.flutter=V` exposed the first exception:
  `no such column: added_at`, from
  `SELECT * FROM read_later ORDER BY added_at DESC`.
- The call originates in `ReadLaterManager.getAll` while constructing the home
  page. Subsequent `RenderPhysicalModel` / `RenderSliver` errors follow that
  failure.

## Cause

The previously supplied `1792075800 (1).venera` contains a valid, empty
`read_later` table with `type` and `added_time` columns, nullable `subtitle`, and
no `tags` or `description`. Current code expects `comic_type`, `added_at`,
`tags`, and `description`. The existing migration only added `description`.
SQLite integrity checks therefore passed, but homepage queries failed.

The later `1792228143585082.venera` has the current read-later schema. Neither
archive's embedded source scripts were executed during this investigation.

## Fix and validation

- Rebuild the legacy table in a SQLite transaction, map the old field names,
  preserve identity and timestamps, and fill missing optional fields.
- Replace the old primary key and NOT NULL columns so future inserts work.
- Keep schema migration outside corrupt-database recovery: unsupported schemas
  fail initialization or trigger import rollback, preserving the original DB.
- Linux: 7 focused migration/backup tests passed, including native ZIP export.
- Connected Android device: 6 tests passed, 1 host-only WAL export test skipped.
  The isolated integration application verified empty/populated legacy tables,
  retained timestamps, duplicate rejection, writes, reopening, and backup import
  followed by core-manager reinitialization.
- Static analysis of the changed Dart files passed.

The automated tests use synthetic fixtures matching the original table
definition; they do not constitute a fresh full restore of either original
archive on the device.

## Installation and recovery

- At the user's request, built the fix from `7134e99` locally as an arm64 release
  APK. The local Android keystore certificate matches the installed application.
- Verified the repaired APK's certificate, package ID, version 2.6.2, and
  versionCode 2622 against the installed APK, then installed with `adb install -r`.
  No uninstall or app-data clearing was performed.
- The actual application's existing imported data now opens successfully. Its
  home page shows 291 history records and reading statistics.
- A further force-stop and cold start succeeded (`TotalTime: 398 ms`). The new
  process log contains none of the missing-column or RenderSliver errors.
- Imported source scripts still report independent parsing/configuration errors,
  including a ManWang syntax error and a JM baseUrl error. These do not prevent
  the home page from opening and were not changed by this database fix.
- Restored the temporary `log.tag.flutter` override and left the app open.
- The unnecessary remote Android build was cancelled and its completed run
  record removed. No version was bumped, no existing release was changed, and no
  new release was published.

Local repaired APK: `/tmp/venera-prime-2.6.2-migration-fix-arm64.apk`.
