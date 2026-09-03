-- Nothing to create here any more. This file held meta_geoip2 and
-- meta_geoip2_dict, the registry that mapped a month to the dictionary
-- built over it. History lives in geoip2_<type>_history now, one partition
-- per month, so the month is a column and there is nothing to resolve.
--
-- Kept rather than deleted: the updater executes every .sql in sql/, and
-- releases are unpacked in place, so a file removed upstream would linger
-- on hosts that already have it and keep recreating what it creates.
CREATE DATABASE IF NOT EXISTS geoip;
