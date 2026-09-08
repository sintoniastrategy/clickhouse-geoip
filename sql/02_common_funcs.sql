CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

-- Current-data lookups

DROP FUNCTION IF EXISTS x_geoip2_dict_get;
CREATE FUNCTION x_geoip2_dict_get as (db_type, dict_key, ip) ->
    multiIf(
        isIPv4String(ip),
        dictGetOrNull(CONCAT('geoip.geoip2_', db_type, '_trie'), dict_key, tuple(IPv4StringToNumOrDefault(toString(ip)))),
        isIPv6String(ip),
        dictGetOrNull(CONCAT('geoip.geoip2_', db_type, '_trie'), dict_key, tuple(IPv6StringToNumOrDefault(toString(ip)))),
        NULL
    )
;

-- DB specific functions

DROP FUNCTION IF EXISTS geoip2_city_get;
CREATE FUNCTION geoip2_city_get AS (dict_key, ip) ->
    x_geoip2_dict_get('city', dict_key, ip)
;

DROP FUNCTION IF EXISTS geoip2_country_get;
CREATE FUNCTION geoip2_country_get AS (dict_key, ip) ->
    x_geoip2_dict_get('country', dict_key, ip)
;

DROP FUNCTION IF EXISTS geoip2_asn_get;
CREATE FUNCTION geoip2_asn_get AS (dict_key, ip) ->
    x_geoip2_dict_get('asn', dict_key, ip)
;
