CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

CREATE TABLE IF NOT EXISTS meta_geoip2 (
    yyyymm UInt32,
    db_type String,
    target_dict String
)
ENGINE = MergeTree
ORDER BY (yyyymm, db_type);

CREATE DICTIONARY IF NOT EXISTS meta_geoip2_dict (
    yyyymm UInt32,
    db_type String,
    target_dict String
)
PRIMARY KEY (yyyymm, db_type)
SOURCE(CLICKHOUSE(DB 'geoip' TABLE 'meta_geoip2'))
LAYOUT(complex_key_hashed)
LIFETIME(0);

