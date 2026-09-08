CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

-- Live data
CREATE TABLE IF NOT EXISTS geoip2_city (
    prefix String,

    city_geoname_id UInt64,
    city_name String,

    continent_code String,
    continent_geoname_id UInt64,
    continent_name String,

    country_geoname_id UInt64,
    country_is_in_european_union BOOL,
    country_iso_code String,
    country_name String,

    location_accuracy_radius UInt16,
    location_latitude Float64,
    location_longitude Float64,
    location_metro_code UInt64,
    location_time_zone String,

    postal_code String,

    registered_country_geoname_id UInt64,
    registered_country_is_in_european_union BOOL,
    registered_country_iso_code String,
    registered_country_name String,

    represented_country_geoname_id UInt64,
    represented_country_is_in_european_union BOOL,
    represented_country_iso_code String,
    represented_country_name String,
    represented_country_type String,

    subdivisions_geoname_id UInt64,
    subdivisions_iso_code String,
    subdivisions_name String,

    traits_is_anonymous_proxy BOOL,
    traits_is_satellite_provider BOOL
)
ENGINE = MergeTree
ORDER BY (prefix);

CREATE DICTIONARY IF NOT EXISTS geoip2_city_trie (
    prefix String,

    city_geoname_id UInt64,
    city_name String,

    location_accuracy_radius UInt16,
    location_latitude Float64,
    location_longitude Float64,
    location_metro_code UInt64,
    location_time_zone String,

    postal_code String
)
PRIMARY KEY prefix
SOURCE(CLICKHOUSE(DB 'geoip' TABLE 'geoip2_city'))
LAYOUT(ip_trie)
LIFETIME(14400);

CREATE TABLE IF NOT EXISTS geoip2_city_history (
    yyyymm UInt32,

    prefix String,

    city_geoname_id UInt64,
    city_name String,

    continent_code String,
    continent_geoname_id UInt64,
    continent_name String,

    country_geoname_id UInt64,
    country_is_in_european_union BOOL,
    country_iso_code String,
    country_name String,

    location_accuracy_radius UInt16,
    location_latitude Float64,
    location_longitude Float64,
    location_metro_code UInt64,
    location_time_zone String,

    postal_code String,

    registered_country_geoname_id UInt64,
    registered_country_is_in_european_union BOOL,
    registered_country_iso_code String,
    registered_country_name String,

    represented_country_geoname_id UInt64,
    represented_country_is_in_european_union BOOL,
    represented_country_iso_code String,
    represented_country_name String,
    represented_country_type String,

    subdivisions_geoname_id UInt64,
    subdivisions_iso_code String,
    subdivisions_name String,

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
