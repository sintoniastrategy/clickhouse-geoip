CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

DROP FUNCTION IF EXISTS geoip2_dated_country;
CREATE FUNCTION geoip2_dated_country AS (dt, ip) ->
    geoip2_dated_country_get(dt, 'country_name', ip)
;

DROP FUNCTION IF EXISTS geoip2_country;
CREATE FUNCTION geoip2_country AS (ip) ->
    geoip2_dated_country(now(), ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_country_iso_code;
CREATE FUNCTION geoip2_dated_country_iso_code AS (dt, ip) ->
    geoip2_dated_country_get(dt, 'country_iso_code', ip)
;

DROP FUNCTION IF EXISTS geoip2_country_iso_code;
CREATE FUNCTION geoip2_country_iso_code AS (ip) ->
    geoip2_dated_country_iso_code(now(), ip)
;
