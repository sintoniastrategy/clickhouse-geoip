CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

CREATE TABLE IF NOT EXISTS geoip2_asn (
    prefix String,

    autonomous_system_number UInt64,
    autonomous_system_organization String,
    isp String,
    organization String
)
ENGINE = MergeTree
ORDER BY (prefix);

CREATE DICTIONARY IF NOT EXISTS geoip2_asn_trie (
    prefix String,

    autonomous_system_number UInt64,
    autonomous_system_organization String,
    isp String,
    organization String
)
PRIMARY KEY prefix
SOURCE(CLICKHOUSE(DB 'geoip' TABLE 'geoip2_asn'))
LAYOUT(ip_trie)
LIFETIME(14400);

CREATE TABLE IF NOT EXISTS geoip2_asn_history (
    yyyymm UInt32,

    prefix String,

    autonomous_system_number UInt64,
    autonomous_system_organization String,
    isp String,
    organization String,

    net_start IPv6 MATERIALIZED
        tupleElement(IPv6CIDRToRange(toIPv6(splitByChar('/', prefix)[1]),
            toUInt8(toUInt16(splitByChar('/', prefix)[2]) + if(position(prefix, ':') = 0, 96, 0))), 1),
    net_end IPv6 MATERIALIZED
        tupleElement(IPv6CIDRToRange(toIPv6(splitByChar('/', prefix)[1]),
            toUInt8(toUInt16(splitByChar('/', prefix)[2]) + if(position(prefix, ':') = 0, 96, 0))), 2),

    INDEX idx_net_end net_end TYPE minmax GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY yyyymm
ORDER BY (yyyymm, net_start);
