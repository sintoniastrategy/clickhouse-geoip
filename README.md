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
db-ip                     bin/mmdb2csv  ──pipe──▶  clickhouse-client
.mmdb.gz  ──gunzip──▶ .mmdb ──────────▶ .csv ──────INSERT──────▶  geoip2_<type>__staging
                                                                    │            │
                                              EXCHANGE TABLES ──────┘            └────── INSERT … SELECT
                                                       ▼                                        ▼
  geoip2_<type>  ──ip_trie──▶  geoip2_<type>_trie                          geoip2_<type>_history
  (MergeTree, live)            (the only dictionary; every function reads)  (MergeTree, PARTITION BY yyyymm;
                                                                            no dictionary over it)
```

For each db type (`country`, `city`, `asn`) the updater
[`bin/clickhouse-geoip-updater.sh`](bin/clickhouse-geoip-updater.sh):

1. **Downloads** the monthly db-ip Lite file
   (`https://download.db-ip.com/free/dbip-<type>-lite-YYYY-MM.mmdb.gz`).
2. **Converts** it to CSV with [`mmdb2csv`](cmd/mmdb2csv/) (a Go tool using the
   MaxMind `geoip2`/`maxminddb` readers — db-ip Lite uses the same MMDB schema).
3. **Streams** it into `geoip2_<type>__staging` — nothing is written to disk
   as CSV, and nothing goes live yet.
4. **Archives** the month as a partition of `geoip2_<type>_history`, unless
   `GEOIP_SNAPSHOTS=0`.
5. **Publishes** every staged type with a single `EXCHANGE TABLES`, so the
   live tables are never empty and the three types never disagree about which
   month they hold.
6. **Reloads** `geoip2_<type>_trie` so the new data is visible at once.

Current-data functions (`geoip2_country`, …) read the dictionary.
Point-in-time functions (`geoip2_dated_country(dt, ip)`, …) read the history
table — see [dated lookups](#dated-lookups).

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
| `geoip2_country`, `geoip2_city`, `geoip2_asn` | Live data, full column set. Replaced wholesale by each load. |
| `geoip2_<type>_history` | Every kept month, one partition per `yyyymm`. Same columns plus `yyyymm` and two `MATERIALIZED` range bounds. |
| `geoip2_<type>__staging` | Exists only during a load; swapped in and dropped. |

### Dictionaries

| Dictionary | Layout | Notes |
|---|---|---|
| `geoip2_<type>_trie` | `ip_trie` | The only dictionary, `LIFETIME(14400)`. Nothing is built over history. |

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
geoip2_country_get(key, ip)
geoip2_city_get(key, ip)
geoip2_asn_get(key, ip)
```

`key` is any attribute of the corresponding trie dict:

- **country**: `country_geoname_id`, `country_is_in_european_union`, `country_iso_code`, `country_name`
- **city**: `city_geoname_id`, `city_name`, `location_accuracy_radius`, `location_latitude`, `location_longitude`, `location_metro_code`, `location_time_zone`, `postal_code`
- **asn**: `autonomous_system_number`, `autonomous_system_organization`, `isp`, `organization`

```sql
SELECT geoip2_city_get('postal_code', '8.8.8.8');
SELECT geoip2_asn_get('autonomous_system_number', '1.1.1.1');
```

These exist only for current data. There is no dated equivalent — see below.

### Dated lookups

`geoip2_dated_<x>(dt, ip)` reads `geoip2_<type>_history`, not a dictionary.
`dt` resolves to the month **before** its own (`toYYYYMM(addMonths(dt, -1))`),
so data labelled month *M* serves dates in *M+1*:

```sql
-- with 202607 and 202608 loaded
SELECT geoip2_dated_city(toDate('2026-08-15'), '32.94.23.0');  -- New York, from 202607
SELECT geoip2_dated_city(toDate('2026-09-15'), '32.94.23.0');  -- Dallas,   from 202608
```

A month that was never loaded yields no rows, so the function returns `NULL`.
A malformed address returns `NULL` too — the lookup uses `toIPv6OrNull`.

**Why a table and not a dictionary.** An `ip_trie` over one month of a
granular database runs to tens of gigabytes, it is never evicted once loaded
(there is no `SYSTEM UNLOAD DICTIONARY`, and `ip_trie` has no bounded
layout), and touching five months could exhaust a host. The same month as a
partition costs disk and no memory at all. Measured on one lookup: a single
granule range, a few MiB read, single-digit milliseconds — fine for the
ad-hoc and dashboard queries this is for.

Ranges make it work. The converter emits CIDR strings and the traversal
yields **disjoint** networks, so exactly one range contains any address, and
`ORDER BY net_start DESC LIMIT 1` gives what longest-prefix matching would.
`net_start`/`net_end` are `MATERIALIZED` and part of the sorting key, so the
primary key prunes on them. An IPv4 prefix maps into `::ffff:0:0/96`, so one
expression covers both families.

**Two limits worth knowing.**

`dt` and `ip` must be **constants**. A correlated scalar subquery is not
supported, so these functions cannot be applied to a column. For bulk work,
join the history table directly — and unlike the dictionary version, that
actually works with the month varying per row:

```sql
SELECT e.ip, argMax(h.city_name, length(h.prefix)) AS city
FROM events AS e
ARRAY JOIN <candidate prefixes of e.ip> AS cand
LEFT JOIN geoip.geoip2_city_history AS h
       ON h.yyyymm = toYYYYMM(addMonths(e.ts, -1)) AND h.prefix = cand
GROUP BY e.ip;
```

There is **no generic dated getter**. `dictGet` took the attribute name as a
string argument; a subquery cannot select a column by a string, so only the
named wrappers exist. Reach anything else by querying
`geoip2_<type>_history` directly.

---

## Design notes & limitations

### Why the current-data path is still a dictionary

Longest-prefix matching by IP inside a scalar expression is the one thing a
table cannot do, and the production consumer — a materialized view that
enriches rows as they are inserted — needs exactly that, per row, at insert
rate. So the live month stays an `ip_trie` and history does not.

### `dictGet` needs a constant dictionary name

Earlier versions resolved a per-month dictionary from the date and called
`dictGetOrNull(<name>, key, tuple(<ip>))`. ClickHouse requires the first
argument of `dictGet*` to be a constant, and a name computed from a column
is not. So:

| Call | Resolved dict name | Works over a table? |
|---|---|---|
| `geoip2_country(ip_col)` | constant | ✅ yes |
| `geoip2_dated_country(toDate('2023-05-15'), ip_col)` | constant (literal) | ✅ yes |
| `geoip2_dated_country(timestamp_col, ip_col)` | **per-row** | ❌ rejected |

The *key* being a column is fine — that is what dictionaries are for. What
cannot vary per row is the date-driven dictionary selection. So the one use
case the design was built for — enriching a whole historical table from its
own timestamp column — was exactly the one it could not serve. This is not a
version quirk: in current ClickHouse a dictionary is still resolved once per
query.

The history table has no such limit on the join path, which is why the
recipe above works.

### Upgrading from a version with dated dictionaries

Nothing here drops anything. The updater stops *creating* the old objects
and leaves what already exists, so an upgrade never destroys data on its
own — but it also means a server that ran an earlier release keeps a layer
that no longer has anything under it. Run this once, by hand.

The functions first. They are the misleading part: an orphaned
`geoip2_dated_city_get()` still resolves a dictionary name out of
`meta_geoip2`, which this version stops maintaining, so the call fails with
`Code: 36` rather than saying the function is gone. Drop them and a
forgotten caller gets `UNKNOWN_FUNCTION` instead.

```sql
-- the generic getters: no table-backed equivalent exists, because dictGet
-- took the attribute name as a string and a subquery cannot select a
-- column by a string
DROP FUNCTION IF EXISTS geoip2_dated_city_get;
DROP FUNCTION IF EXISTS geoip2_dated_country_get;
DROP FUNCTION IF EXISTS geoip2_dated_asn_get;

-- and the layer they resolved through
DROP FUNCTION IF EXISTS x_geoip2_dated_dict_get;
DROP FUNCTION IF EXISTS x_geoip2_dated_dictname;
```

Order matters only against the updater, not among these: run them **after**
a load with the new version, because until `sql/03_*_funcs.sql` has run the
named getters (`geoip2_dated_city` and friends) still route through
`x_geoip2_dated_dict_get`, and dropping it first breaks them.

Then the objects — but only once the months you care about are in
`geoip2_<type>_history`, because until then the month tables are the only
copy:

```sql
-- fill history from a month table first
INSERT INTO geoip.geoip2_city_history SELECT 202601, * FROM geoip.geoip2_city__202601;

-- then drop, dictionary before table: ClickHouse refuses to drop a table a
-- dictionary still reads, with Code: 630 HAVE_DEPENDENT_OBJECTS
DROP DICTIONARY IF EXISTS geoip.geoip2_city_trie__202601;
DROP TABLE      IF EXISTS geoip.geoip2_city__202601;

-- the registry, once no month tables are left
DROP DICTIONARY IF EXISTS geoip.meta_geoip2_dict;
DROP TABLE      IF EXISTS geoip.meta_geoip2;

-- and the empty fallbacks, if a version that made them ever ran here
DROP DICTIONARY IF EXISTS geoip.geoip2_city_trie__absent;
DROP TABLE      IF EXISTS geoip.geoip2_city__absent;
```

`SELECT <yyyymm>, *` works because the month table has the same columns in
the same order as the history table minus `yyyymm` — both came from one
template. Check the row counts before dropping anything.

### Enrich at write time where you can

On insert the date is a constant, so the lookup is legal, the geo is baked
into the row, and it is accurate as of insertion. This is the idiomatic
ClickHouse pattern, and it means a query over old rows already reads the geo
recorded back then — which is most of what point-in-time lookups get asked
for.

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
| `GEOIP_COUNTRY_FILE` / `GEOIP_CITY_FILE` / `GEOIP_ASN_FILE` | empty | Use an `.mmdb` already on disk instead of downloading one. A single combined database may back all three. Set `GEOIP_DATE` and `CLICKHOUSE_YYYYMM` to the month that file *is*, since they otherwise come from the clock and would mislabel it. |
| `GEOIP_SNAPSHOTS` | `1` | Keep each month as a partition of `geoip2_<type>_history`, so `geoip2_dated_*` can answer. History is a table and nothing else, so a kept month costs disk and no memory. `0` loads the live tables only, and the dated getters return `NULL` for every month. |
| `GEOIP_COLLAPSE` | `1` | Pass `-collapse` to the converter: merge consecutive networks with identical values into the largest aligned prefixes. Lookups are unchanged. `0` dumps every network verbatim. |
| — | — | The converter is piped straight into `clickhouse-client`, so no CSV is written. `db/` holds only the downloaded `.mmdb` files and a few-byte `*.loaded` marker per month and type. |
| `GITHUB_REPO` | `sintoniastrategy/clickhouse-geoip` | Repo to fetch the `mmdb2csv` release from. |

Load a specific past month (download + label must agree):

```bash
docker compose run --rm -e GEOIP_DATE=2026-05 -e CLICKHOUSE_YYYYMM=202605 updater
```

---

## Monthly updates

Re-run the updater. It:

- skips files/tables already present for that month (idempotent),
- adds a `geoip2_<type>_history` partition when the month changes,
- swaps the live tables to the new month with one `EXCHANGE TABLES`,
- `SYSTEM RELOAD`s the dictionaries so changes are visible immediately.

Old downloaded files in `db/` are pruned after 90 days; the markers are a few
bytes and outlive them deliberately. History partitions are **not** dropped
automatically — keep them, or drop one:

```sql
ALTER TABLE geoip.geoip2_city_history DROP PARTITION 202601;
```

---

## Operational notes & gotchas

These were verified while building this setup (ClickHouse 24.8):

- **The `default` user must exist (loopback).** `ip_trie` dictionaries open an
  internal connection as `default` to read their source tables. If you delete `default` (e.g. by setting `CLICKHOUSE_USER` on the
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
- **Dictionary freshness:** the trie dicts cache for `LIFETIME(14400)`, so the
  updater ends with `SYSTEM RELOAD DICTIONARY` to make new data visible at
  once. History needs no reload — it is a table.
- **`CLICKHOUSE_DB` is effectively fixed to `geoip`** — the SQL files and UDFs
  reference `geoip.*` directly.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `AUTHENTICATION_FAILED` inside a `dictGet`/function | `default` user missing or can't read the tables. Don't remove `default`; ensure it works over loopback. |
| `geoip2_dated_*` returns `NULL` for a month you expected | That month has no partition in `geoip2_<type>_history`. Check with `SELECT DISTINCT yyyymm FROM geoip.geoip2_city_history`. Remember the offset: a September date reads the month labelled August. |
| `Correlated subqueries are not supported` from a dated getter | It was applied to a column. `dt` and `ip` must be constants; join `geoip2_<type>_history` for bulk work. |
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
sql/00_base.sql                   geoip DB
sql/01_*.sql                      Per-type live table + ip_trie dict + history table
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

Every `sql/*.sql` is executed in name order. Earlier versions rendered the
per-type schemas from `*.sql.template` into generated `*.main.sql`,
`*.yyyymm.sql` and `*.absent.sql`; there is nothing left to substitute, so the
updater deletes those leftovers — a release unpacked in place would otherwise
keep executing them.

---

## License

- **Code** — the `mmdb2csv` converter, the updater script, the SQL, and the
  Docker setup — is released under the [MIT License](LICENSE).
- **Data** — the **db-ip.com IP-to-* Lite** databases — is licensed under
  [Creative Commons Attribution 4.0 (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
  Any product using this data must attribute db-ip.com (e.g. "IP Geolocation by
  DB-IP"). See <https://db-ip.com/db/lite.php>.
