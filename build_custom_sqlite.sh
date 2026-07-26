#!/bin/bash

# Build custom SQLite with extension loading support
set -e

echo "Building custom SQLite with extension loading support..."

# Download SQLite amalgamation if not present
SQLITE_VERSION="3500400"  # 3.50.4
SQLITE_YEAR="2025"
SQLITE_DIR="sqlite-amalgamation-${SQLITE_VERSION}"
SQLITE_ZIP="${SQLITE_DIR}.zip"
SQLITE_URL="https://www.sqlite.org/${SQLITE_YEAR}/${SQLITE_ZIP}"

if [ ! -d "$SQLITE_DIR" ]; then
    echo "Downloading SQLite amalgamation..."
    curl -O "$SQLITE_URL"
    unzip -q "$SQLITE_ZIP"
fi

cd "$SQLITE_DIR"

# Compile SQLite with extension loading enabled
echo "Compiling SQLite with SQLITE_ENABLE_LOAD_EXTENSION..."
clang -dynamiclib -o libsqlite3_custom.dylib \
    -DSQLITE_ENABLE_LOAD_EXTENSION=1 \
    -DSQLITE_ENABLE_FTS5=1 \
    -DSQLITE_ENABLE_RTREE=1 \
    -DSQLITE_ENABLE_JSON1=1 \
    -DSQLITE_ENABLE_SNAPSHOT=1 \
    -DSQLITE_THREADSAFE=2 \
    -DSQLITE_ENABLE_API_ARMOR=1 \
    -DSQLITE_ENABLE_FTS3=1 \
    -DSQLITE_ENABLE_FTS3_PARENTHESIS=1 \
    -DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1 \
    -DSQLITE_OMIT_AUTORESET=1 \
    -DSQLITE_OMIT_BUILTIN_TEST=1 \
    -DSQLITE_OS_UNIX=1 \
    -DSQLITE_ENABLE_LOCKING_STYLE=1 \
    -O3 \
    -fPIC \
    -install_name @rpath/libsqlite3_custom.dylib \
    sqlite3.c

echo "SQLite library built: $(pwd)/libsqlite3_custom.dylib"

# Copy to Resources
RESOURCES_DIR="../AlmRecorder/Resources/Libraries"
mkdir -p "$RESOURCES_DIR"
cp libsqlite3_custom.dylib "$RESOURCES_DIR/"
echo "SQLite library copied to: $RESOURCES_DIR/libsqlite3_custom.dylib"

echo "Done! Custom SQLite with extension support is ready."