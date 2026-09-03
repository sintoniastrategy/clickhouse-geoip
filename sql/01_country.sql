CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

-- Live data. Replaced wholesale by each load: the updater fills a staging
-- copy and swaps it in with EXCHANGE TABLES.
CREATE TABLE IF NOT EXISTS geoip2_country (
    prefix String,

    continent_code String,
    continent_geoname_id UInt64,
    continent_name String,

    country_geoname_id UInt64,
    country_is_in_european_union BOOL,
    country_iso_code String,
    country_name String,

    registered_country_geoname_id UInt64,
    registered_country_is_in_european_union BOOL,
    registered_country_iso_code String,
    registered_country_name String,

    represented_country_geoname_id UInt64,
    represented_country_is_in_european_union BOOL,
    represented_country_iso_code String,
    represented_country_type String,

    traits_is_anonymous_proxy BOOL,
    traits_is_satellite_provider BOOL
)
ENGINE = MergeTree
ORDER BY (prefix);

-- The only dictionary. Longest-prefix matching by IP inside a scalar
-- expression is the one thing a table cannot do, and the netprobe
-- materialized view needs exactly that on every insert.
CREATE DICTIONARY IF NOT EXISTS geoip2_country_trie (
    prefix String,

    country_geoname_id UInt64,
    country_is_in_european_union BOOL,
    country_iso_code String,
    country_name String
)
PRIMARY KEY prefix
SOURCE(CLICKHOUSE(DB 'geoip' TABLE 'geoip2_country'))
LAYOUT(ip_trie)
LIFETIME(14400);

-- History, one partition per month, and no dictionary over it. A month
-- here costs disk and nothing else; as an ip_trie the same month would
-- cost roughly ten times as much in RAM and stay resident for good,
-- because dictionaries have no eviction.
--
-- net_start/net_end are derived, not dumped: the converter emits a CIDR
-- string, and a range is what the primary key can prune on. An IPv4
-- prefix maps into ::ffff:0:0/96, so shifting its length by 96 lets one
-- expression cover both families with no branch — `if` does not
-- short-circuit here, and toIPv4() on an IPv6 string throws.
CREATE TABLE IF NOT EXISTS geoip2_country_history (
    yyyymm UInt32,

    prefix String,

    continent_code String,
    continent_geoname_id UInt64,
    continent_name String,

    country_geoname_id UInt64,
    country_is_in_european_union BOOL,
    country_iso_code String,
    country_name String,

    registered_country_geoname_id UInt64,
    registered_country_is_in_european_union BOOL,
    registered_country_iso_code String,
    registered_country_name String,

    represented_country_geoname_id UInt64,
    represented_country_is_in_european_union BOOL,
    represented_country_iso_code String,
    represented_country_type String,

    traits_is_anonymous_proxy BOOL,
    traits_is_satellite_provider BOOL,

    net_start IPv6 MATERIALIZED
        tupleElement(IPv6CIDRToRange(toIPv6(splitByChar('/', prefix)[1]),
            toUInt8(toUInt16(splitByChar('/', prefix)[2]) + if(position(prefix, ':') = 0, 96, 0))), 1),
    net_end IPv6 MATERIALIZED
        tupleElement(IPv6CIDRToRange(toIPv6(splitByChar('/', prefix)[1]),
            toUInt8(toUInt16(splitByChar('/', prefix)[2]) + if(position(prefix, ':') = 0, 96, 0))), 2)
)
ENGINE = MergeTree
PARTITION BY yyyymm
ORDER BY (yyyymm, net_start);
