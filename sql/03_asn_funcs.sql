CREATE DATABASE IF NOT EXISTS geoip;
USE geoip;

DROP FUNCTION IF EXISTS geoip2_asn_org;
CREATE FUNCTION geoip2_asn_org AS (ip) ->
    geoip2_asn_get('autonomous_system_organization', ip)
;

DROP FUNCTION IF EXISTS geoip2_dated_asn_org;
CREATE FUNCTION geoip2_dated_asn_org AS (dt, ip) ->
    (SELECT autonomous_system_organization FROM geoip.geoip2_asn_history
     WHERE yyyymm = toYYYYMM(addMonths(dt, -1))
       AND net_start <= toIPv6OrNull(ip) AND toIPv6OrNull(ip) <= net_end
     ORDER BY net_start DESC LIMIT 1)
;
