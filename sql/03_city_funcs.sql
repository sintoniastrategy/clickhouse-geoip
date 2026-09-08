CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

DROP FUNCTION IF EXISTS geoip2_city;
CREATE FUNCTION geoip2_city AS (ip) ->
    geoip2_city_get('city_name', ip)
;

DROP FUNCTION IF EXISTS geoip2_city_lat;
CREATE FUNCTION geoip2_city_lat AS (ip) ->
    geoip2_city_get('location_latitude', ip)
;

DROP FUNCTION IF EXISTS geoip2_city_lon;
CREATE FUNCTION geoip2_city_lon AS (ip) ->
    geoip2_city_get('location_longitude', ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_city;
CREATE FUNCTION geoip2_dated_city AS (dt, ip) ->
    (SELECT city_name FROM geoip.geoip2_city_history
     WHERE yyyymm = toYYYYMM(addMonths(dt, -1))
       AND net_start <= toIPv6OrNull(ip) AND toIPv6OrNull(ip) <= net_end
     ORDER BY net_start DESC LIMIT 1)
;

DROP FUNCTION IF EXISTS geoip2_dated_city_lat;
CREATE FUNCTION geoip2_dated_city_lat AS (dt, ip) ->
    (SELECT location_latitude FROM geoip.geoip2_city_history
     WHERE yyyymm = toYYYYMM(addMonths(dt, -1))
       AND net_start <= toIPv6OrNull(ip) AND toIPv6OrNull(ip) <= net_end
     ORDER BY net_start DESC LIMIT 1)
;

DROP FUNCTION IF EXISTS geoip2_dated_city_lon;
CREATE FUNCTION geoip2_dated_city_lon AS (dt, ip) ->
    (SELECT location_longitude FROM geoip.geoip2_city_history
     WHERE yyyymm = toYYYYMM(addMonths(dt, -1))
       AND net_start <= toIPv6OrNull(ip) AND toIPv6OrNull(ip) <= net_end
     ORDER BY net_start DESC LIMIT 1)
;
