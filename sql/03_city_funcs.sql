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

-- Point-in-time lookups read the history table, not a dictionary. The
-- month is a column, so nothing has to resolve a dictionary name — which
-- is what used to make a missing month fail with Code: 36 instead of
-- returning NULL. A month that was never loaded now yields no rows, and
-- the subquery gives NULL by itself.
--
-- toIPv6OrNull() rather than toIPv6(): a malformed address must return
-- NULL, not throw. It does not cost index pruning — measured, the same
-- single granule either way.
--
-- Constant dt and ip only. A correlated scalar subquery is not supported,
-- so these cannot be applied to a column; for bulk work join
-- geoip2_<type>_history on (yyyymm, net_start) directly. dictGet had the
-- same limit from the other side — it needs a constant dictionary name.

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
