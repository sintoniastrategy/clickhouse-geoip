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

# Use an .mmdb that is already on disk instead of downloading one. Set per
# db type; a single combined database may back all three. Anything fetched
# and verified elsewhere (a paid subscription, a mirror) belongs here.
GEOIP_COUNTRY_FILE="${GEOIP_COUNTRY_FILE:-}"
GEOIP_CITY_FILE="${GEOIP_CITY_FILE:-}"
GEOIP_ASN_FILE="${GEOIP_ASN_FILE:-}"

# Keep each month in geoip2_<type>_history as its own partition, so
# geoip2_dated_*() can answer point-in-time questions. History is a table
# and nothing else: no dictionary is built over it, so a kept month costs
# disk and no memory. Turning this off loads the live tables only, and the
# dated getters then return NULL for every month.
GEOIP_SNAPSHOTS="${GEOIP_SNAPSHOTS:-1}"

# Merge consecutive networks that carry identical values into the largest
# aligned prefixes. Lookups are unchanged (see
# internal/csvdumper/collapse.go), and one database feeding several tables
# is the normal case, so this is on by default: a country table cut at ISP
# boundaries carries tens of millions of rows the data cannot distinguish,
# and every one of them is a prefix in the ip_trie built on top. Set to 0
# to dump every network verbatim.
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

# Resolve one db type to a readable .mmdb, in $MMDB_PATH. No CSV is
# produced: the converter is streamed into ClickHouse instead, so nothing
# intermediate lands on disk.
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

# Records that a month/type has been ingested, and with which converter
# settings: a collapsed load is different data, so toggling the flag must
# not look like "already done". Holds the row count, checked against the
# table so a dropped database is noticed rather than skipped.
marker_path() {
    if [ "$GEOIP_COLLAPSE" = "1" ]; then
        echo "${DB_DIR}/${1}.${GEOIP_DATE}.collapsed.loaded"
    else
        echo "${DB_DIR}/${1}.${GEOIP_DATE}.loaded"
    fi
}

# Stream the converter straight into a table. `set -o pipefail` makes
# either side's failure fail the load, which is the point: a CSV cut short
# by a killed process still looks like a plausible file, a broken pipe
# does not.
stream_into() {
    local table="$1" mmdb="$2" dbtype="$3"
    local collapse_flag=""
    [ "$GEOIP_COLLAPSE" = "1" ] && collapse_flag="-collapse"

    log "Load: $table  (streaming $(basename "$mmdb") [$dbtype])"
    clickhouse-client -d "$CLICKHOUSE_DB" -q "TRUNCATE TABLE IF EXISTS $table" 2>/dev/null || true
    # An INSERT from a stream commits block by block, so a failure part way
    # through leaves the target partly filled. That target is never a live
    # table — publish/swap_in put the data in place only after this
    # returns — but empty it anyway, so nothing later mistakes a fragment
    # for a load.
    # shellcheck disable=SC2086  # deliberately unquoted: empty means absent
    if ! "${BIN_DIR}/mmdb2csv" -db-path "$mmdb" -db-type "$dbtype" -no-quotes ${collapse_flag} \
        | clickhouse-client -d "$CLICKHOUSE_DB" \
            -q "INSERT INTO $table SETTINGS input_format_csv_empty_as_default = 1 FORMAT CSVWithNames"; then
        clickhouse-client -d "$CLICKHOUSE_DB" -q "TRUNCATE TABLE IF EXISTS $table" 2>/dev/null || true
        error "streaming $dbtype into $table failed"
    fi

    local loaded
    loaded=$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $table")
    # A geo database is never legitimately empty, and the ledger row that
    # may follow would otherwise advertise a month holding nothing.
    [ "$loaded" -gt 0 ] || error "$table loaded 0 rows from $(basename "$mmdb")"
    log "Loaded: ${loaded} rows"
}

# Fill a staging copy of one db type's live table. Nothing goes live here:
# publishing is deferred so that every type can be swapped in together.
#
# Returns 1 when this month is already loaded, so the caller knows not to
# include the type in the publish.
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

    # Refuse to carry an empty table into the publish. stream_into already
    # fails a zero-row load, so this only fires if something else emptied
    # the staging table — and swapping it in would blank the live one.
    [ "$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $staging")" -gt 0 ] \
        || error "refusing to publish $live from empty $staging"

    if [ "$GEOIP_SNAPSHOTS" = "1" ]; then
        # The month's partition, copied out of staging while staging still
        # holds the new data — after the exchange it holds the old one.
        # Dropping first makes a retry after a failed run clean; dropping a
        # partition that does not exist is a no-op.
        local hist="geoip2_${dt}_history"
        clickhouse-client -d "$CLICKHOUSE_DB" -q "ALTER TABLE $hist DROP PARTITION ${CLICKHOUSE_YYYYMM}"
        clickhouse-client -d "$CLICKHOUSE_DB" -q "INSERT INTO $hist SELECT ${CLICKHOUSE_YYYYMM}, * FROM $staging"
        log "Archived: ${hist} partition ${CLICKHOUSE_YYYYMM} ($(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $hist WHERE yyyymm = ${CLICKHOUSE_YYYYMM}") rows)"
    fi
}

# Put every staged table live in a single statement.
#
# Two things this buys. TRUNCATE + INSERT would leave a live table empty
# for as long as the insert takes; the ip_trie dictionaries cache for
# LIFETIME seconds, so a reload landing in that window loads an empty
# dictionary and every lookup — and anything enriching rows on insert from
# one — silently gets nothing back until the end of the run. And doing the
# types one at a time means a run that dies between country and city
# leaves a live country from the new month next to a city from the old one:
# each table consistent by itself, the months apart until the next run.
# EXCHANGE TABLES takes several pairs at once and renames them all, so
# neither window exists.
#
# It needs an Atomic database (the default since 20.10). Older engines keep
# the truncate+insert path, which cannot be atomic across three tables —
# there the months can still diverge, and there is no way around it.
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

# Earlier versions rendered the per-type schemas from *.sql.template into
# generated .main.sql / .yyyymm.sql / .absent.sql. There is nothing left to
# substitute — a month is a partition now, not a table name — so the
# schemas are plain .sql. Releases are unpacked in place and every
# sql/*.sql is executed below, so the leftovers have to be removed rather
# than merely left ungenerated: a stale .yyyymm.sql would go on recreating
# the per-month tables and dictionaries this version stopped making.
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

# Refresh the live dictionaries so the new data is visible at once: they
# cache for LIFETIME seconds and their source table was just swapped, so
# without this a lookup keeps answering from the previous month for up to
# that long.
#
# The month's own dictionary is deliberately NOT reloaded. It was created a
# moment ago and has never been loaded, so it has nothing stale to refresh
# — reloading it only forces a full copy into memory that nobody has asked
# for. With dictionaries_lazy_load (on by default) an archived month costs
# nothing until a dated lookup actually touches it.
log "Reload dictionaries"
for dt in country city asn; do
    clickhouse-client -d "$CLICKHOUSE_DB" -q "SYSTEM RELOAD DICTIONARY geoip2_${dt}_trie"
done

# Cleanup downloaded databases (>90 days). Markers are a few bytes and
# outlive them deliberately, so an old month is not re-ingested.
find "${DB_DIR}" -type f \( -name '*.mmdb' -o -name '*.mmdb.gz' \) -mtime +90 -delete 2>/dev/null || true

log "Update complete!"
