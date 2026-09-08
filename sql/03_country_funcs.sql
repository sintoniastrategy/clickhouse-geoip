CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

DROP FUNCTION IF EXISTS geoip2_country;
CREATE FUNCTION geoip2_country AS (ip) ->
    geoip2_country_get('country_name', ip)
;

DROP FUNCTION IF EXISTS geoip2_country_iso_code;
CREATE FUNCTION geoip2_country_iso_code AS (ip) ->
    geoip2_country_get('country_iso_code', ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_country;
CREATE FUNCTION geoip2_dated_country AS (dt, ip) ->
    (SELECT country_name FROM geoip.geoip2_country_history
     WHERE yyyymm = toYYYYMM(addMonths(dt, -1))
       AND net_start <= toIPv6OrNull(ip) AND toIPv6OrNull(ip) <= net_end
     ORDER BY net_start DESC LIMIT 1)
;

DROP FUNCTION IF EXISTS geoip2_dated_country_iso_code;
CREATE FUNCTION geoip2_dated_country_iso_code AS (dt, ip) ->
    (SELECT country_iso_code FROM geoip.geoip2_country_history
     WHERE yyyymm = toYYYYMM(addMonths(dt, -1))
       AND net_start <= toIPv6OrNull(ip) AND toIPv6OrNull(ip) <= net_end
     ORDER BY net_start DESC LIMIT 1)
;
