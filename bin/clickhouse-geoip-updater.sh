#!/usr/bin/env bash
set -euo pipefail

# Config
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
WORK_DIR="${WORK_DIR:-"$(readlink -f "$SCRIPT_DIR/..")"}"
CLICKHOUSE_DB="${CLICKHOUSE_DB:-geoip}"
GEOIP_DATE="${GEOIP_DATE:-$(date +%Y-%m)}"
CLICKHOUSE_YYYYMM="${CLICKHOUSE_YYYYMM:-$(date +%Y%m)}"

GEOIP_COUNTRY_URL="${GEOIP_COUNTRY_URL:-https://download.db-ip.com/free/dbip-country-lite-${GEOIP_DATE}.mmdb.gz}"
GEOIP_CITY_URL="${GEOIP_CITY_URL:-https://download.db-ip.com/free/dbip-city-lite-${GEOIP_DATE}.mmdb.gz}"
GEOIP_ASN_URL="${GEOIP_ASN_URL:-https://download.db-ip.com/free/dbip-asn-lite-${GEOIP_DATE}.mmdb.gz}"

# Use an .mmdb already on disk instead of downloading. One combined
# database may back all three types.
GEOIP_COUNTRY_FILE="${GEOIP_COUNTRY_FILE:-}"
GEOIP_CITY_FILE="${GEOIP_CITY_FILE:-}"
GEOIP_ASN_FILE="${GEOIP_ASN_FILE:-}"

# Keep each month as a geoip2_<type>_history partition, so geoip2_dated_*()
# can answer. No dictionary over it: a kept month costs disk, not memory.
GEOIP_SNAPSHOTS="${GEOIP_SNAPSHOTS:-1}"

GEOIP_COLLAPSE="${GEOIP_COLLAPSE:-1}"

# Paths
LOG_FILE="${WORK_DIR}/updater.log"
DB_DIR="${WORK_DIR}/db"
BIN_DIR="${WORK_DIR}/bin"
SCHEMA_DIR="${WORK_DIR}/sql"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
error() { log "ERROR: $*" >&2; exit 1; }

mkdir -p "${DB_DIR}" "${BIN_DIR}" "${SCHEMA_DIR}"

log "GeoIP update for ${CLICKHOUSE_YYYYMM}"

# Download with atomic mv
download() {
    local url="$1" dest="$2"
    [ -f "$dest" ] && [ -s "$dest" ] && { log "Skip: $(basename "$dest")"; return 0; }
    log "Download: $(basename "$dest")"
    curl -fsSL --retry 3 --retry-delay 5 -o "${dest}.tmp" "$url"
    mv "${dest}.tmp" "$dest"
}

# Decompress if needed
decompress() {
    local gz="$1"
    local out="${gz%.gz}"
    [ -f "$out" ] && [ -s "$out" ] && { log "Skip: $(basename "$out")"; return 0; }
    log "Decompress: $(basename "$gz")"
    gunzip -c "$gz" > "${out}.tmp"
    mv "${out}.tmp" "$out"
}

# Resolve one db type to a readable .mmdb in $MMDB_PATH. No CSV is written:
# the converter is streamed straight into ClickHouse.
resolve_mmdb() {
    local dbtype="$1" url="$2" file="$3"

    if [ -n "$file" ]; then
        [ -r "$file" ] || error "local mmdb for ${dbtype} is unreadable: ${file}"
        log "Local: ${file} [${dbtype}]"
        MMDB_PATH="$file"
        return 0
    fi

    local gz="${DB_DIR}/${dbtype}.${GEOIP_DATE}.mmdb.gz"
    download "$url" "$gz"
    decompress "$gz"
    MMDB_PATH="${gz%.gz}"
}

# Marks a month/type loaded, keyed on the collapse flag too — a collapsed
# load is different data. Holds the row count, checked against the table.
marker_path() {
    if [ "$GEOIP_COLLAPSE" = "1" ]; then
        echo "${DB_DIR}/${1}.${GEOIP_DATE}.collapsed.loaded"
    else
        echo "${DB_DIR}/${1}.${GEOIP_DATE}.loaded"
    fi
}

# Stream the converter into a table. pipefail fails the load from either
# side: a CSV cut short still looks plausible, a broken pipe does not.
stream_into() {
    local table="$1" mmdb="$2" dbtype="$3"
    local collapse_flag=""
    [ "$GEOIP_COLLAPSE" = "1" ] && collapse_flag="-collapse"

    log "Load: $table  (streaming $(basename "$mmdb") [$dbtype])"
    clickhouse-client -d "$CLICKHOUSE_DB" -q "TRUNCATE TABLE IF EXISTS $table" 2>/dev/null || true
    # A streamed INSERT commits block by block, so a failure part way leaves
    # a fragment. Never a live table, but empty it so nothing mistakes it.
    # shellcheck disable=SC2086  # deliberately unquoted: empty means absent
    if ! "${BIN_DIR}/mmdb2csv" -db-path "$mmdb" -db-type "$dbtype" -no-quotes ${collapse_flag} \
        | clickhouse-client -d "$CLICKHOUSE_DB" \
            -q "INSERT INTO $table SETTINGS input_format_csv_empty_as_default = 1 FORMAT CSVWithNames"; then
        clickhouse-client -d "$CLICKHOUSE_DB" -q "TRUNCATE TABLE IF EXISTS $table" 2>/dev/null || true
        error "streaming $dbtype into $table failed"
    fi

    local loaded
    loaded=$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $table")
    # A geo database is never legitimately empty.
    [ "$loaded" -gt 0 ] || error "$table loaded 0 rows from $(basename "$mmdb")"
    log "Loaded: ${loaded} rows"
}

# Fill a staging copy of one type's live table; nothing goes live here, so
# every type can be swapped in together. Returns 1 if the month is loaded.
stage() {
    local dt="$1" mmdb="$2"
    local live="geoip2_${dt}"
    local staging="${live}__staging"
    local marker
    marker="$(marker_path "$dt")"

    if [ -f "$marker" ] \
        && [ "$(cat "$marker" 2>/dev/null)" = "$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $live" 2>/dev/null)" ]; then
        log "Skip: $live ($(cat "$marker") rows)"
        return 1
    fi

    clickhouse-client -d "$CLICKHOUSE_DB" -q "DROP TABLE IF EXISTS $staging"
    clickhouse-client -d "$CLICKHOUSE_DB" -q "CREATE TABLE $staging AS $live"
    stream_into "$staging" "$mmdb" "$dt"

    # stream_into already fails a zero-row load; this catches anything else
    # that emptied staging, since swapping it in would blank the live table.
    [ "$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $staging")" -gt 0 ] \
        || error "refusing to publish $live from empty $staging"

    if [ "$GEOIP_SNAPSHOTS" = "1" ]; then
        # Copied while staging still holds the new data — after the exchange
        # it holds the old. Dropping first makes a retry clean; drop is a no-op.
        local hist="geoip2_${dt}_history"
        clickhouse-client -d "$CLICKHOUSE_DB" -q "ALTER TABLE $hist DROP PARTITION ${CLICKHOUSE_YYYYMM}"
        clickhouse-client -d "$CLICKHOUSE_DB" -q "INSERT INTO $hist SELECT ${CLICKHOUSE_YYYYMM}, * FROM $staging"
        log "Archived: ${hist} partition ${CLICKHOUSE_YYYYMM} ($(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $hist WHERE yyyymm = ${CLICKHOUSE_YYYYMM}") rows)"
    fi
}

# Put every staged table live in one statement. TRUNCATE + INSERT would
# blank a live table for the insert's duration, and publishing one type at a
# time lets a dying run leave a new-month country beside an old-month city.
# Non-Atomic engines keep truncate+insert, where months can still diverge.
publish_all() {
    if [ "$#" -eq 0 ]; then
        log "Nothing to publish"
        return 0
    fi

    local dt pairs=""
    for dt in "$@"; do
        [ -n "$pairs" ] && pairs="${pairs}, "
        pairs="${pairs}geoip2_${dt} AND geoip2_${dt}__staging"
    done

    if [ "$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT engine FROM system.databases WHERE name = '${CLICKHOUSE_DB}'")" = "Atomic" ]; then
        log "Publish: $* (one atomic exchange)"
        clickhouse-client -d "$CLICKHOUSE_DB" -q "EXCHANGE TABLES $pairs"
    else
        log "Publish: $* (truncate+insert per table, database engine is not Atomic)"
        for dt in "$@"; do
            clickhouse-client -d "$CLICKHOUSE_DB" -q "TRUNCATE TABLE IF EXISTS geoip2_${dt}" 2>/dev/null || true
            clickhouse-client -d "$CLICKHOUSE_DB" -q "INSERT INTO geoip2_${dt} SELECT * FROM geoip2_${dt}__staging"
        done
    fi

    # Markers are written only now: before the exchange nothing was live,
    # so a run that died earlier must reload rather than skip.
    for dt in "$@"; do
        clickhouse-client -d "$CLICKHOUSE_DB" -q "DROP TABLE IF EXISTS geoip2_${dt}__staging"
        clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM geoip2_${dt}" > "$(marker_path "$dt")"
        log "Loaded: geoip2_${dt} $(cat "$(marker_path "$dt")") rows"
    done
}

# Resolve mmdb2csv: prefer an existing binary, else download the prebuilt
# release asset for this OS/arch, else build from source with Go.
GITHUB_REPO="${GITHUB_REPO:-sintoniastrategy/clickhouse-geoip}"
MMDB2CSV_VERSION="${MMDB2CSV_VERSION:-latest}"
MMDB2CSV="${BIN_DIR}/mmdb2csv"

detect_os() { case "$(uname -s)" in Linux) echo linux ;; Darwin) echo darwin ;; *) echo unknown ;; esac; }
detect_arch() { case "$(uname -m)" in x86_64 | amd64) echo amd64 ;; aarch64 | arm64) echo arm64 ;; *) echo unknown ;; esac; }

download_mmdb2csv() {
    local os arch asset url tmp
    os="$(detect_os)"
    arch="$(detect_arch)"
    if [ "$os" = unknown ] || [ "$arch" = unknown ]; then
        log "No prebuilt mmdb2csv for $(uname -s)/$(uname -m)"
        return 1
    fi
    asset="mmdb2csv_${os}_${arch}.tar.gz"
    if [ "$MMDB2CSV_VERSION" = latest ]; then
        url="https://github.com/${GITHUB_REPO}/releases/latest/download/${asset}"
    else
        url="https://github.com/${GITHUB_REPO}/releases/download/${MMDB2CSV_VERSION}/${asset}"
    fi
    log "Fetch mmdb2csv: ${url}"
    tmp="$(mktemp -d)"
    if curl -fsSL --retry 3 --retry-delay 5 -o "${tmp}/${asset}" "$url" &&
        tar -xzf "${tmp}/${asset}" -C "$tmp" && [ -f "${tmp}/mmdb2csv" ]; then
        install -m 0755 "${tmp}/mmdb2csv" "$MMDB2CSV"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

build_mmdb2csv() {
    command -v go >/dev/null 2>&1 || return 1
    log "Build mmdb2csv from source (go build ./cmd/mmdb2csv)"
    (cd "$WORK_DIR" && CGO_ENABLED=0 go build -trimpath -o "$MMDB2CSV" ./cmd/mmdb2csv)
}

if [ ! -x "$MMDB2CSV" ]; then
    log "mmdb2csv not found at ${MMDB2CSV} — acquiring it"
    download_mmdb2csv || build_mmdb2csv || error "Could not obtain mmdb2csv: release download failed and 'go' is unavailable to build it. Install Go (the script will build it automatically) or download it manually from https://github.com/${GITHUB_REPO}/releases and place it at ${MMDB2CSV}."
    log "mmdb2csv ready: $("$MMDB2CSV" -version 2>/dev/null || echo unknown)"
fi

# Resolve each database to a file on disk
resolve_mmdb country "$GEOIP_COUNTRY_URL" "$GEOIP_COUNTRY_FILE"; COUNTRY_MMDB="$MMDB_PATH"
resolve_mmdb city    "$GEOIP_CITY_URL"    "$GEOIP_CITY_FILE";    CITY_MMDB="$MMDB_PATH"
resolve_mmdb asn     "$GEOIP_ASN_URL"     "$GEOIP_ASN_FILE";     ASN_MMDB="$MMDB_PATH"

# Earlier versions generated .main.sql / .yyyymm.sql / .absent.sql from
# templates. Releases unpack in place and every sql/*.sql runs, so a stale
# .yyyymm.sql would keep recreating month objects — remove them.
rm -f "${SCHEMA_DIR}"/*.yyyymm.sql "${SCHEMA_DIR}"/*.main.sql "${SCHEMA_DIR}"/*.absent.sql

# Ensure the target database exists before connecting with -d
clickhouse-client -q "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DB}"

# Execute schemas
for sql in "${SCHEMA_DIR}"/*.sql; do
    log "Schema: $(basename "$sql")"
    clickhouse-client -d "$CLICKHOUSE_DB" < "$sql"
done

# Load everything into staging first, then put it all live at once. A type
# whose month is already loaded is skipped and stays out of the exchange.
STAGED=""
stage country "$COUNTRY_MMDB" && STAGED="$STAGED country"
stage city    "$CITY_MMDB"    && STAGED="$STAGED city"
stage asn     "$ASN_MMDB"     && STAGED="$STAGED asn"

# shellcheck disable=SC2086  # deliberately unquoted: one word per db type
publish_all $STAGED

# They cache for LIFETIME and their source table was just swapped, so
# without this a lookup answers from last month for up to that long.
log "Reload dictionaries"
for dt in country city asn; do
    clickhouse-client -d "$CLICKHOUSE_DB" -q "SYSTEM RELOAD DICTIONARY geoip2_${dt}_trie"
done

# Cleanup downloaded databases (>90 days). Markers are a few bytes and
# outlive them deliberately, so an old month is not re-ingested.
find "${DB_DIR}" -type f \( -name '*.mmdb' -o -name '*.mmdb.gz' \) -mtime +90 -delete 2>/dev/null || true

log "Update complete!"
