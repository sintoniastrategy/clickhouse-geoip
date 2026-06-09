CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

-- Common functions

DROP FUNCTION IF EXISTS x_geoip2_dated_dictname;
CREATE FUNCTION x_geoip2_dated_dictname as (dt, db_type) ->
    'geoip.' || dictGetOrDefault('geoip.meta_geoip2_dict', 'target_dict', tuple(toYYYYMM(addMonths(dt, -1)), db_type),
        CONCAT('geoip2_', db_type, '_trie')
    )
;

DROP FUNCTION IF EXISTS x_geoip2_dated_dict_get;
CREATE FUNCTION x_geoip2_dated_dict_get as (dt, db_type, dict_key, ip) ->
    multiIf(
        isIPv4String(ip),
        dictGetOrNull(x_geoip2_dated_dictname(dt, db_type), dict_key, tuple(IPv4StringToNumOrDefault(toString(ip)))),
        isIPv6String(ip),
        dictGetOrNull(x_geoip2_dated_dictname(dt, db_type), dict_key, tuple(IPv6StringToNumOrDefault(toString(ip)))),
        NULL
    )
;

-- DB specific functions

DROP FUNCTION IF EXISTS geoip2_dated_city_get;
CREATE FUNCTION geoip2_dated_city_get AS (dt, dict_key, ip) ->
    x_geoip2_dated_dict_get(dt, 'city', dict_key, ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_country_get;
CREATE FUNCTION geoip2_dated_country_get AS (dt, dict_key, ip) ->
    x_geoip2_dated_dict_get(dt, 'country', dict_key, ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_asn_get;
CREATE FUNCTION geoip2_dated_asn_get AS (dt, dict_key, ip) ->
    x_geoip2_dated_dict_get(dt, 'asn', dict_key, ip)
;
