CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

DROP FUNCTION IF EXISTS geoip2_dated_asn_org;
CREATE FUNCTION geoip2_dated_asn_org AS (dt, ip) ->
    geoip2_dated_asn_get(dt, 'autonomous_system_organization', ip)
;

DROP FUNCTION IF EXISTS geoip2_asn_org;
CREATE FUNCTION geoip2_asn_org AS (ip) ->
    geoip2_dated_asn_org(now(), ip)
;
