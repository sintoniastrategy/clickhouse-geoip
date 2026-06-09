CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

DROP FUNCTION IF EXISTS geoip2_dated_city;
CREATE FUNCTION geoip2_dated_city AS (dt, ip) ->
    geoip2_dated_city_get(dt, 'city_name', ip)
;

DROP FUNCTION IF EXISTS geoip2_city;
CREATE FUNCTION geoip2_city AS (ip) ->
    geoip2_dated_city(now(), ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_city_lat;
CREATE FUNCTION geoip2_dated_city_lat AS (dt, ip) ->
    geoip2_dated_city_get(dt, 'location_latitude', ip)
;

DROP FUNCTION IF EXISTS geoip2_city_lat;
CREATE FUNCTION geoip2_city_lat AS (ip) ->
    geoip2_dated_city_lat(now(), ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_city_lon;
CREATE FUNCTION geoip2_dated_city_lon AS (dt, ip) ->
    geoip2_dated_city_get(dt, 'location_longitude', ip)
;

DROP FUNCTION IF EXISTS geoip2_city_lon;
CREATE FUNCTION geoip2_city_lon AS (ip) ->
    geoip2_dated_city_lon(now(), ip)
;
