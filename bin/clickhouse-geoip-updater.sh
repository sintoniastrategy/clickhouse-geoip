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

# Convert if needed
convert() {
    local mmdb="$1" csv="$2"
    [ -f "$csv" ] && [ -s "$csv" ] && { log "Skip: $(basename "$csv")"; return 0; }
    local dbtype=$(echo "$(basename "$mmdb")" | cut -d '.' -f1)
    log "Convert: $(basename "$mmdb") [$dbtype] to ${csv}"
    "${BIN_DIR}/mmdb2csv" -db-path "$mmdb" -db-type "$dbtype" -no-quotes > "${csv}.tmp"
    mv "${csv}.tmp" "$csv"
}

# Check if table loaded (same row count as CSV)
is_loaded() {
    local table="$1" csv="$2"
    local csv_rows=$(wc -l < "$csv" | tr -d ' ')
    csv_rows=$((csv_rows - 1))
    local tbl_rows=$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $table" 2>/dev/null || echo "0")
    [ "$csv_rows" = "$tbl_rows" ] && [ "$csv_rows" != "0" ] && { log "Skip: $table ($tbl_rows rows)"; return 0; }
    return 1
}

is_loaded2() {
    local table="$1" table2="$2"
    local tbl_rows2=$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $table2" 2>/dev/null || echo "0")
    local tbl_rows=$(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $table" 2>/dev/null || echo "0")
    [ "$tbl_rows2" = "$tbl_rows" ] && [ "$tbl_rows2" != "0" ] && { log "Skip: $table ($tbl_rows rows)"; return 0; }
    return 1
}

# Load table
load() {
    local table="$1" csv="$2"
    is_loaded "$table" "$csv" && return 0
    log "Load: $table"
    clickhouse-client -d "$CLICKHOUSE_DB" -q "TRUNCATE TABLE IF EXISTS $table" 2>/dev/null || true
    clickhouse-client -d "$CLICKHOUSE_DB" -q "INSERT INTO $table SETTINGS input_format_csv_empty_as_default = 1 FORMAT CSVWithNames" < "$csv"

    log "Loaded: $(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $table") rows"
}

# Load table
load2() {
    local table="$1" table2="$2"
    is_loaded2 "$table" "$table2" && return 0
    log "Load: $table"
    clickhouse-client -d "$CLICKHOUSE_DB" -q "TRUNCATE TABLE IF EXISTS $table" 2>/dev/null || true
    clickhouse-client -d "$CLICKHOUSE_DB" -q "INSERT INTO $table SELECT * FROM $table2"
    log "Loaded: $(clickhouse-client -d "$CLICKHOUSE_DB" -q "SELECT count() FROM $table") rows"
}

insert_meta() {
    local table="$1"
    local db_type=$(echo "$table" | cut -d_ -f2 | cut -d_ -f1)
    # meta must point at the dated TRIE DICTIONARY that dictGet resolves,
    # not at the source MergeTree table.
    local target_dict="geoip2_${db_type}_trie__${CLICKHOUSE_YYYYMM}"
    loaded=$(clickhouse-client -d geoip -q "SELECT count() FROM meta_geoip2 WHERE yyyymm=$CLICKHOUSE_YYYYMM AND db_type='$db_type'")
    if [ x"$loaded" != x"1" ]; then
        clickhouse-client -d geoip -q "INSERT INTO meta_geoip2 VALUES ($CLICKHOUSE_YYYYMM, '$db_type', '$target_dict')"
        log "Inserted meta: ($CLICKHOUSE_YYYYMM, '$db_type', '$target_dict')"
    else
        log "Skip meta: ($CLICKHOUSE_YYYYMM, '$db_type', '$target_dict')"
    fi
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

# Process country
COUNTRY_GZ="${DB_DIR}/country.${GEOIP_DATE}.mmdb.gz"
COUNTRY_MMDB="${COUNTRY_GZ%.gz}"
COUNTRY_CSV="${DB_DIR}/country.${GEOIP_DATE}.csv"
download $GEOIP_COUNTRY_URL "$COUNTRY_GZ"
decompress "$COUNTRY_GZ"
convert "$COUNTRY_MMDB" "$COUNTRY_CSV"

# Process city
CITY_GZ="${DB_DIR}/city.${GEOIP_DATE}.mmdb.gz"
CITY_MMDB="${CITY_GZ%.gz}"
CITY_CSV="${DB_DIR}/city.${GEOIP_DATE}.csv"
download $GEOIP_CITY_URL "$CITY_GZ"
decompress "$CITY_GZ"
convert "$CITY_MMDB" "$CITY_CSV"

# Process ASN
ASN_GZ="${DB_DIR}/asn.${GEOIP_DATE}.mmdb.gz"
ASN_MMDB="${ASN_GZ%.gz}"
ASN_CSV="${DB_DIR}/asn.${GEOIP_DATE}.csv"
download $GEOIP_ASN_URL "$ASN_GZ"
decompress "$ASN_GZ"
convert "$ASN_MMDB" "$ASN_CSV"

# Prepare schemas
for tpl in "${SCHEMA_DIR}"/*.sql.template; do
    sed "s/YYYYMM/${CLICKHOUSE_YYYYMM}/g" "$tpl" > "${SCHEMA_DIR}/$(basename "$tpl" .template)".yyyymm.sql
    sed "s/__YYYYMM//g" "$tpl" > "${SCHEMA_DIR}/$(basename "$tpl" .template)".main.sql
done

# Ensure the target database exists before connecting with -d
clickhouse-client -q "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DB}"

# Execute schemas
for sql in "${SCHEMA_DIR}"/*.sql; do
    log "Schema: $(basename "$sql")"
    clickhouse-client -d "$CLICKHOUSE_DB" < "$sql"
done

# Load data
load "geoip2_country__${CLICKHOUSE_YYYYMM}" "$COUNTRY_CSV"
insert_meta "geoip2_country__${CLICKHOUSE_YYYYMM}"

load "geoip2_city__${CLICKHOUSE_YYYYMM}" "$CITY_CSV"
insert_meta "geoip2_city__${CLICKHOUSE_YYYYMM}"

load "geoip2_asn__${CLICKHOUSE_YYYYMM}" "$ASN_CSV"
insert_meta "geoip2_asn__${CLICKHOUSE_YYYYMM}"

# Load data
load2 "geoip2_country" "geoip2_country__${CLICKHOUSE_YYYYMM}"
load2 "geoip2_city" "geoip2_city__${CLICKHOUSE_YYYYMM}"
load2 "geoip2_asn" "geoip2_asn__${CLICKHOUSE_YYYYMM}"

# Refresh dictionaries so the new data + month become visible immediately.
# (meta_geoip2_dict has LIFETIME(0) and never auto-reloads; the trie dicts
#  cache for LIFETIME seconds, so a fresh load would otherwise lag.)
log "Reload dictionaries"
for dt in country city asn; do
    clickhouse-client -d "$CLICKHOUSE_DB" -q "SYSTEM RELOAD DICTIONARY geoip2_${dt}_trie"
    clickhouse-client -d "$CLICKHOUSE_DB" -q "SYSTEM RELOAD DICTIONARY geoip2_${dt}_trie__${CLICKHOUSE_YYYYMM}"
done
clickhouse-client -d "$CLICKHOUSE_DB" -q "SYSTEM RELOAD DICTIONARY meta_geoip2_dict"

# Cleanup old files (>90 days)
find "${DB_DIR}" -type f -mtime +90 -delete 2>/dev/null || true

log "Update complete!"
