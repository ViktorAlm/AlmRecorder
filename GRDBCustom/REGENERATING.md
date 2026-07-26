# Regenerating `Binary/GRDB.xcframework`

This local package ships a **prebuilt** `Binary/GRDB.xcframework` — GRDB compiled
against a **custom SQLite** build with `SQLITE_ENABLE_LOAD_EXTENSION` enabled
(required so the app can load the `vectorlite` extension used for semantic search).
The stock GRDB SwiftPM package does not enable extension loading, which is why a
custom framework is vendored here.

`Package.swift` consumes **only** the prebuilt framework (a `.binaryTarget`), so the
app builds out of the box with no SQLite compilation. The GRDB/SQLite *source* is not
kept in this repo to save ~580 MB; rebuild from the pinned upstream sources below.

## Provenance (pinned)

| Component | Source | Pin |
|---|---|---|
| GRDB | https://github.com/groue/GRDB.swift.git | `3801ab9ac659d9eb57133629270e900444020e8e` (v7.6.1 + 3) |
| Custom SQLite (SQLiteLib) | https://github.com/swiftlyfalling/SQLiteLib.git | `4a8b5505bde3be29669fbac8fa753ded792d1919` |
| SQLite amalgamation | https://sqlite.org | 3.50.4 (3500400) |

Custom build flags live in [`CustomSQLiteConfig/`](CustomSQLiteConfig/)
(`GRDBCustomSQLite-USER.xcconfig` + `GRDBCustomSQLite-USER.h`). The authoritative
build recipe is [`make_binary.sh`](make_binary.sh).

## Rebuild

```bash
# 1. Clone GRDB at the pinned commit, with its SQLite submodules
git clone https://github.com/groue/GRDB.swift.git GRDB
git -C GRDB checkout 3801ab9ac659d9eb57133629270e900444020e8e
git -C GRDB submodule update --init --recursive

# 2. Apply this package's custom SQLite config
cp CustomSQLiteConfig/GRDBCustomSQLite-USER.xcconfig GRDB/SQLiteCustom/
cp CustomSQLiteConfig/GRDBCustomSQLite-USER.h        GRDB/SQLiteCustom/

# 3. Build the framework (see make_binary.sh for the exact invocation)
./make_binary.sh macos

# 4. Replace the vendored framework with the freshly built one
#    (copy the produced GRDB.xcframework into Binary/)
```

GRDB is MIT-licensed; see [`GRDB-LICENSE.txt`](GRDB-LICENSE.txt).
