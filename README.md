# clickhouse-geoip

GeoIP lookups in ClickHouse, built from the free **[db-ip.com Lite](https://db-ip.com/db/lite.php)**
databases (country / city / ASN). A small pipeline downloads the monthly
`.mmdb` files, converts them to CSV with a Go tool, loads them into MergeTree
tables, exposes them as `ip_trie` dictionaries, and wraps everything in
easy-to-call SQL functions — including **point-in-time** lookups that resolve an
IP against the database as it stood in a given month (the reason this exists):

```sql
-- Latest data:
SELECT geoip2_country('8.8.8.8');          -- United States
SELECT geoip2_country_iso_code('1.1.1.1'); -- AU
SELECT geoip2_city('8.8.8.8');             -- Mountain View
SELECT geoip2_asn_org('77.88.8.8');        -- YANDEX LLC

-- Point-in-time — the geo of an IP as of a given date (the whole point):
-- dt selects the monthly snapshot; the IP is matched within that month's data.
SELECT geoip2_dated_country(toDate('2024-03-15'), '8.8.8.8');
SELECT geoip2_dated_city(toDate('2024-03-15'), '8.8.8.8');
SELECT geoip2_dated_asn_org(toDate('2024-03-15'), '77.88.8.8');
```

IPv4 and IPv6 are both supported. Unknown / private IPs return `NULL`.

[![Latest Release](https://img.shields.io/github/v/release/sintoniastrategy/clickhouse-geoip)](https://github.com/sintoniastrategy/clickhouse-geoip/releases)
[![Release](https://github.com/sintoniastrategy/clickhouse-geoip/actions/workflows/release.yml/badge.svg)](https://github.com/sintoniastrategy/clickhouse-geoip/actions/workflows/release.yml)
[![Go Report Card](https://goreportcard.com/badge/github.com/sintoniastrategy/clickhouse-geoip)](https://goreportcard.com/report/github.com/sintoniastrategy/clickhouse-geoip)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## Contents

- [How it works](#how-it-works)
- [Quick start (Docker)](#quick-start-docker)
- [Install](#install)
- [What gets created](#what-gets-created)
- [Query functions](#query-functions)
- [Design notes & limitations](#design-notes--limitations)
- [Production deployment (bare-metal / cron)](#production-deployment-bare-metal--cron)
- [Configuration](#configuration)
- [Monthly updates](#monthly-updates)
- [Operational notes & gotchas](#operational-notes--gotchas)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [License](#license)

---

## How it works

```
db-ip Lite                bin/mmdb2csv            clickhouse-client
.mmdb.gz  ──gunzip──▶ .mmdb ──────────▶ .csv ──────INSERT──────▶  geoip2_<type>__YYYYMM   (MergeTree, dated)
                                                                         │
                                                                  ip_trie dictionary
                                                                         ▼
                                                                  geoip2_<type>_trie__YYYYMM
              INSERT … SELECT (load2)                                    │
  geoip2_<type>  ◀──────────────────────────────────────────────────────┘ (latest month copied to
  (MergeTree, "main") ──ip_trie──▶ geoip2_<type>_trie  (main dictionary)    the non-dated "main" objects)

  meta_geoip2(yyyymm, db_type, target_dict) ──▶ meta_geoip2_dict   (maps a month → its dated trie dict)
```

For each db type (`country`, `city`, `asn`) the updater
[`bin/clickhouse-geoip-updater.sh`](bin/clickhouse-geoip-updater.sh):

1. **Downloads** the monthly db-ip Lite file
   (`https://download.db-ip.com/free/dbip-<type>-lite-YYYY-MM.mmdb.gz`).
2. **Converts** it to CSV with [`mmdb2csv`](cmd/mmdb2csv/) (a Go tool using the
   MaxMind `geoip2`/`maxminddb` readers — db-ip Lite uses the same MMDB schema).
3. **Loads** the CSV into a dated table `geoip2_<type>__YYYYMM`.
4. Creates a **dated `ip_trie` dictionary** `geoip2_<type>_trie__YYYYMM` over it.
5. **Copies** the dated table into the non-dated "main" table `geoip2_<type>`,
   which backs the main dictionary `geoip2_<type>_trie`.
6. **Registers** the month in `meta_geoip2` and reloads the dictionaries.

The SQL functions resolve an IP through the dictionaries. The non-dated
functions (`geoip2_country`, …) always use the latest loaded data; the dated
functions (`geoip2_dated_country(dt, ip)`, …) can resolve historical months if
you keep several loaded (see [dated lookups](#dated-lookups)).

---

## Quick start (Docker)

Spins up ClickHouse, builds the updater image (compiles `mmdb2csv` from source +
ships a `clickhouse-client`), and loads the current month.

**Prerequisites:** Docker with Compose v2. Outbound HTTPS to `download.db-ip.com`.

```bash
# 1. Start ClickHouse (waits until healthy)
docker compose up -d clickhouse

# 2. Run the one-shot updater (download → convert → load → build dicts)
docker compose run --rm updater
```

First run downloads ~71 MB (country 4 MB, city 62 MB, asn 5 MB) and takes
~5–6 minutes end-to-end (the city file dominates). It is **idempotent** — re-runs
skip files and tables that are already present.

**Try some lookups** (there is no `clickhouse-client` on the host; query through
the server container or the mapped HTTP port):

```bash
docker compose exec clickhouse clickhouse-client -q \
  "SELECT geoip2_country('8.8.8.8'), geoip2_asn_org('8.8.8.8')"

# or over HTTP (mapped to 127.0.0.1:18123)
curl -s 'http://localhost:18123/?user=geoip&password=geoip' \
  --data-binary "SELECT geoip2_city('1.1.1.1'), geoip2_country_iso_code('1.1.1.1')"
```

**Tear down** (add `-v` to also delete the data + download volumes):

```bash
docker compose down        # keep data
docker compose down -v     # wipe everything
```

> The compose stack creates a network-reachable `geoip`/`geoip` user **and keeps
> the built-in `default` user** — the dictionaries need `default` for their
> internal loopback connections (see [gotchas](#operational-notes--gotchas)).
> These are local-dev credentials; change them for anything exposed.

---

## Install

You only need the **`mmdb2csv`** converter on the host that runs the updater
(the Docker path builds it for you). Three ways to get it:

1. **Let the updater fetch it (default).** If `bin/mmdb2csv` is missing,
   [`bin/clickhouse-geoip-updater.sh`](bin/clickhouse-geoip-updater.sh) downloads
   the prebuilt release asset for your OS/arch from the
   [releases page](https://github.com/sintoniastrategy/clickhouse-geoip/releases),
   falling back to `go build` if Go is present. Pin a version with
   `MMDB2CSV_VERSION=v0.1.0`.
2. **Grab a prebuilt binary.** Download `mmdb2csv_<os>_<arch>.tar.gz` from the
   [releases page](https://github.com/sintoniastrategy/clickhouse-geoip/releases),
   verify it against `checksums.txt`, extract, and drop `mmdb2csv` into `bin/`.
3. **Build from source** (Go 1.23+):

   ```bash
   go install github.com/sintoniastrategy/clickhouse-geoip/cmd/mmdb2csv@latest
   # …or from a checkout:
   go build -trimpath -o bin/mmdb2csv ./cmd/mmdb2csv
   ```

Prebuilt binaries are published for **Linux / macOS / Windows** on **amd64** and
**arm64** (no Windows/arm64). They are static and CGO-free.

---

## What gets created

Everything lives in the **`geoip`** database.

### Tables (`MergeTree`, `ORDER BY prefix`)

| Table | Purpose |
|---|---|
| `geoip2_country__YYYYMM`, `geoip2_city__YYYYMM`, `geoip2_asn__YYYYMM` | Per-month source data (full column set). |
| `geoip2_country`, `geoip2_city`, `geoip2_asn` | The "main" copy = latest loaded month. |
| `meta_geoip2(yyyymm, db_type, target_dict)` | Registry mapping a month to its dated trie dictionary. |

### Dictionaries

| Dictionary | Layout | Notes |
|---|---|---|
| `geoip2_<type>_trie` | `ip_trie` | Main lookup dict, `LIFETIME(14400)`. |
| `geoip2_<type>_trie__YYYYMM` | `ip_trie` | Per-month dict, `LIFETIME(14400)`. |
| `meta_geoip2_dict` | `complex_key_hashed` | `LIFETIME(0)` — reloaded by the updater. |

The `prefix` column holds CIDR strings (e.g. `8.8.8.0/24`); `ip_trie` does
longest-prefix matching for both IPv4 and IPv6.

---

## Query functions

All functions are SQL UDFs created by [`sql/02_common_funcs.sql`](sql/02_common_funcs.sql)
and `sql/03_*_funcs.sql`.

### Convenience functions

Every field comes in two forms: a **latest** form `geoip2_<x>(ip)` and a
**point-in-time** form `geoip2_dated_<x>(dt, ip)`. The latest form is just the
dated one called with `now()` — e.g. `geoip2_country(ip)` ≡ `geoip2_dated_country(now(), ip)`.

| Latest | Point-in-time | Returns |
|---|---|---|
| `geoip2_country(ip)` | `geoip2_dated_country(dt, ip)` | Country name |
| `geoip2_country_iso_code(ip)` | `geoip2_dated_country_iso_code(dt, ip)` | Country ISO code |
| `geoip2_city(ip)` | `geoip2_dated_city(dt, ip)` | City name |
| `geoip2_city_lat(ip)` / `geoip2_city_lon(ip)` | `geoip2_dated_city_lat(dt, ip)` / `geoip2_dated_city_lon(dt, ip)` | Latitude / longitude |
| `geoip2_asn_org(ip)` | `geoip2_dated_asn_org(dt, ip)` | Autonomous-system organization |

### Generic getters (any attribute)

```sql
geoip2_dated_country_get(dt, key, ip)
geoip2_dated_city_get(dt, key, ip)
geoip2_dated_asn_get(dt, key, ip)
```

`key` is any attribute of the corresponding trie dict:

- **country**: `country_geoname_id`, `country_is_in_european_union`, `country_iso_code`, `country_name`
- **city**: `city_geoname_id`, `city_name`, `location_accuracy_radius`, `location_latitude`, `location_longitude`, `location_metro_code`, `location_time_zone`, `postal_code`
- **asn**: `autonomous_system_number`, `autonomous_system_organization`, `isp`, `organization`

```sql
SELECT geoip2_dated_city_get(now(), 'postal_code', '8.8.8.8');
SELECT geoip2_dated_asn_get(now(), 'autonomous_system_number', '1.1.1.1');
```

### Dated lookups

The dated functions take a date and resolve the month **before** that date's
month (`toYYYYMM(addMonths(dt, -1))`), i.e. data labelled month *M* is treated as
active for dates in month *M+1*:

```sql
-- with month 202606 loaded, a July date resolves to it:
SELECT geoip2_dated_country(toDate('2026-07-15'), '8.8.8.8');  -- United States
```

If the resolved month is not loaded, the function **falls back to the main
dictionary** (latest data). Because of the `-1` offset, the convenience
functions (which call the dated functions with `now()`) normally resolve via
this fallback unless you have last month's release loaded too. For
point-in-time history, load several months and the dated dicts are selected
automatically through `meta_geoip2_dict`.

---

## Design notes & limitations

**Why the dated machinery exists.** The original goal was *historical* geo lookup:
given a table of events with a timestamp and an IP, recover the geo of that IP
**as it was at that time**. That's why `dt` is threaded through every function and
why there's a `meta_geoip2_dict` mapping each month to its own dated `ip_trie`
dictionary.

**The hard limit: `dictGet` needs a constant dictionary name.** In
[`sql/02_common_funcs.sql`](sql/02_common_funcs.sql) the dated getter resolves the
dictionary name from the date and then calls:

```sql
dictGetOrNull( x_geoip2_dated_dictname(dt, db_type), key, tuple(<ip>) )
```

ClickHouse requires the **first argument of `dictGet*` to be a constant**.
`x_geoip2_dated_dictname(dt, …)` only folds to a constant when `dt` itself is
constant. So:

| Call | Resolved dict name | Works over a table? |
|---|---|---|
| `geoip2_country(ip_col)` = `…(now(), ip_col)` | constant | ✅ yes |
| `geoip2_dated_country(toDate('2023-05-15'), ip_col)` | constant (literal) | ✅ yes |
| `geoip2_dated_country(timestamp_col, ip_col)` | **per-row** | ❌ rejected |

The *key* (the IP) being a column is fine — that is what dictionaries are for. The
thing that **cannot vary per row** is the date-driven dictionary selection. So the
one use case this design was built for — enriching a whole historical table from
its own timestamp column in a single pass — is exactly the one `dictGet` cannot do.
This is **not** a version quirk: in current ClickHouse (24.x / 25.x) a dictionary is
still resolved once per query, not per row.

**What to do instead:**

- **Enrich at write time with a materialized view** *(the approach used in
  production)*. On insert the date is a constant, so the lookup is legal; the geo is
  baked into the row and is accurate as of the insertion time. This is the idiomatic
  ClickHouse pattern and sidesteps the limitation entirely.
- **For batch back-fill over existing history**, use a range **`JOIN`** against the
  dated source tables (`geoip2_<type>__YYYYMM`) — match the IP into the CIDR range
  *and* the row's month — instead of `dictGet`. A `JOIN` evaluates per-row on both
  sides, so the month is allowed to vary per row.

The dated functions stay useful for **constant-date point lookups** (dashboards,
ad-hoc "where was this IP in 2024-03") and for the automatic current/fallback
dictionary — just don't hand them a per-row timestamp column.

---

## Production deployment (bare-metal / cron)

The updater is designed to run **on a host that has `clickhouse-client`
pointing at a local ClickHouse server** — the simplest setup, since the
`default` user works over localhost for both the script and the dictionaries'
internal connections.

```bash
# 1. (optional) prebuild the converter — otherwise the updater fetches a
#    prebuilt release binary, or builds it if Go is present (see Install)
go build -trimpath -o bin/mmdb2csv ./cmd/mmdb2csv

# 2. Make sure `clickhouse-client` connects with no flags
clickhouse-client -q 'SELECT 1'

# 3. Run the updater
WORK_DIR="$PWD" bin/clickhouse-geoip-updater.sh
```

Schedule it monthly with cron (db-ip publishes new Lite files at the start of
each month):

```cron
# 03:17 on the 2nd of each month, current month's release
17 3 2 * *  cd /opt/clickhouse-geoip && WORK_DIR=/opt/clickhouse-geoip bin/clickhouse-geoip-updater.sh >> /opt/clickhouse-geoip/cron.log 2>&1
```

If your ClickHouse requires credentials or is remote, point `clickhouse-client`
at it via `/etc/clickhouse-client/config.xml` (host/port/user/password) — the
script intentionally calls `clickhouse-client` with no connection flags so this
config applies everywhere. The dictionaries' internal `SOURCE(CLICKHOUSE(...))`
connections use the server's **`default`** user over loopback, so that user must
be able to `SELECT` from the `geoip` tables (true on a stock install).

---

## Configuration

All via environment variables (defaults shown):

| Variable | Default | Description |
|---|---|---|
| `WORK_DIR` | parent of `bin/` | Working dir for `db/`, `sql/`, logs. |
| `CLICKHOUSE_DB` | `geoip` | Target database. **Keep `geoip`** — the SQL and functions hard-code it. |
| `GEOIP_DATE` | `$(date +%Y-%m)` | db-ip Lite release to fetch, e.g. `2026-06`. |
| `CLICKHOUSE_YYYYMM` | `$(date +%Y%m)` | Month label / dated-object suffix, e.g. `202606`. |
| `GEOIP_COUNTRY_URL` / `GEOIP_CITY_URL` / `GEOIP_ASN_URL` | db-ip URLs derived from `GEOIP_DATE` | Override the download source. |
| `MMDB2CSV_VERSION` | `latest` | Release tag of the prebuilt `mmdb2csv` to download, e.g. `v0.1.0`. |
| `GITHUB_REPO` | `sintoniastrategy/clickhouse-geoip` | Repo to fetch the `mmdb2csv` release from. |

Load a specific past month (download + label must agree):

```bash
docker compose run --rm -e GEOIP_DATE=2026-05 -e CLICKHOUSE_YYYYMM=202605 updater
```

---

## Monthly updates

Re-run the updater. It:

- skips files/tables already present for that month (idempotent),
- inserts a new `geoip2_<type>__YYYYMM` set when the month changes,
- refreshes `geoip2_<type>` (main) to the newest month,
- `SYSTEM RELOAD`s the dictionaries so changes are visible immediately.

Old downloaded files in `db/` are pruned after 90 days. Old dated tables/dicts
are **not** dropped automatically — keep them for history, or drop manually:

```sql
DROP DICTIONARY IF EXISTS geoip.geoip2_city_trie__202601;
DROP TABLE      IF EXISTS geoip.geoip2_city__202601;
DELETE FROM geoip.meta_geoip2 WHERE yyyymm = 202601;
```

---

## Operational notes & gotchas

These were verified while building this setup (ClickHouse 24.8):

- **The `default` user must exist (loopback).** `ip_trie` and `meta_geoip2_dict`
  dictionaries open an internal connection as `default` to read their source
  tables. If you delete `default` (e.g. by setting `CLICKHOUSE_USER` on the
  official image, which writes `<default remove="remove"/>`), every dictionary
  fails with `AUTHENTICATION_FAILED`. The compose stack therefore *adds* a
  `geoip` user via a mounted `users.d` file and leaves `default` intact.
- **CSV is loaded with `CSVWithNames`.** `mmdb2csv` emits a header row, so the
  load uses `FORMAT CSVWithNames` (header-skipping, name-matched) — plain
  `FORMAT CSV` would try to parse the header as data.
- **`input_format_csv_empty_as_default = 1`** is set on the insert: city rows
  without a subdivision emit an empty `subdivisions_geoname_id` (UInt64) that
  would otherwise fail to parse.
- **Database bootstrap:** the schema is applied only after
  `CREATE DATABASE IF NOT EXISTS geoip`, because connecting with `-d geoip`
  requires the DB to already exist.
- **Dictionary freshness:** `meta_geoip2_dict` is `LIFETIME(0)` (never
  auto-reloads) and the trie dicts cache for `LIFETIME(14400)`, so the updater
  ends with `SYSTEM RELOAD DICTIONARY` to make new data/months visible at once.
- **`CLICKHOUSE_DB` is effectively fixed to `geoip`** — the SQL files and UDFs
  reference `geoip.*` directly.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `AUTHENTICATION_FAILED` inside a `dictGet`/function | `default` user missing or can't read the tables. Don't remove `default`; ensure it works over loopback. |
| `Dictionary (geoip.geoip2_*__YYYYMM) not found` | `meta_geoip2` holds a table name instead of the trie dict name — re-run the updater (fixed in `insert_meta`); `TRUNCATE meta_geoip2` first if it has stale rows. |
| `Database geoip does not exist` on the first schema | Run via the updater (it pre-creates the DB), or `CREATE DATABASE geoip` manually. |
| Lookups return stale data after an update | `SYSTEM RELOAD DICTIONARY geoip.geoip2_country_trie` (and the others). |
| `mmdb2csv binary not found` | The updater auto-fetches/builds it; by hand: `go build -o bin/mmdb2csv ./cmd/mmdb2csv` (see [Install](#install)). |
| `docker compose build` fails writing `~/.docker/buildx/...` | Sandboxed `$HOME`: `export BUILDX_CONFIG="$PWD/.cache/buildx"` then `docker build -t ch-geoip-updater:local .` |
| db-ip download 404 | That month isn't published yet — set `GEOIP_DATE` to the previous month. |

---

## Repository layout

```
bin/clickhouse-geoip-updater.sh   Orchestrates download → convert → load → dicts
cmd/mmdb2csv/                     Go source for the MMDB→CSV converter (main)
internal/csvdumper/               Per-db-type CSV row dumpers
sql/00_base.sql                   geoip DB, meta table + dict
sql/01_*.sql.template             Per-type tables + ip_trie dicts (YYYYMM templated)
sql/02_common_funcs.sql           Dict-resolution UDFs
sql/03_*_funcs.sql                Public country/city/asn UDFs
Dockerfile                        Updater image (Go build + clickhouse-client)
docker-compose.yml                ClickHouse server + one-shot updater
docker/clickhouse-client.xml      Client connection config (baked into the image)
docker/clickhouse-users.xml       Adds the `geoip` user (keeps `default`)
.goreleaser.yaml                  Multi-platform mmdb2csv release build (GoReleaser)
.github/workflows/release.yml     Tag v* → GoReleaser → GitHub release binaries
LICENSE                           MIT (code); data is db-ip CC BY 4.0
```

The `*.sql.template` files are rendered at run time into `*.yyyymm.sql` (dated
objects) and `*.main.sql` (non-dated objects) by substituting `YYYYMM`.

---

## License

- **Code** — the `mmdb2csv` converter, the updater script, the SQL, and the
  Docker setup — is released under the [MIT License](LICENSE).
- **Data** — the **db-ip.com IP-to-* Lite** databases — is licensed under
  [Creative Commons Attribution 4.0 (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
  Any product using this data must attribute db-ip.com (e.g. "IP Geolocation by
  DB-IP"). See <https://db-ip.com/db/lite.php>.
