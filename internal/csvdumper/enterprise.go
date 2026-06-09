package csvdumper

import (
	"encoding/csv"
	"fmt"

	"github.com/oschwald/geoip2-golang"
	"github.com/oschwald/maxminddb-golang"
)

var enterpriseColumns = []Column[geoip2.Enterprise]{
	{
		Header: "city_confidence",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.City.Confidence) },
	},
	{
		Header: "city_geoname_id",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.City.GeoNameID) },
	},
	{
		Header: "city_name",
		Getter: func(r *geoip2.Enterprise) string { return r.City.Names["en"] },
	},
	{
		Header: "continent_code",
		Getter: func(r *geoip2.Enterprise) string { return r.Continent.Code },
	},
	{
		Header: "continent_geoname_id",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.Continent.GeoNameID) },
	},
	{
		Header: "continent_name",
		Getter: func(r *geoip2.Enterprise) string { return r.Continent.Names["en"] },
	},
	{
		Header: "country_geoname_id",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.Country.GeoNameID) },
	},
	{
		Header: "country_iso_code",
		Getter: func(r *geoip2.Enterprise) string { return r.Country.IsoCode },
	},
	{
		Header: "country_name",
		Getter: func(r *geoip2.Enterprise) string { return r.Country.Names["en"] },
	},
	{
		Header: "country_confidence",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.Country.Confidence) },
	},
	{
		Header: "country_is_in_european_union",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.Country.IsInEuropeanUnion) },
	},
	{
		Header: "location_accuracy_radius",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.Location.AccuracyRadius) },
	},
	{
		Header: "location_latitude",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.Location.Latitude) },
	},
	{
		Header: "location_longitude",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.Location.Longitude) },
	},
	{
		Header: "location_metro_code",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.Location.MetroCode) },
	},
	{
		Header: "location_time_zone",
		Getter: func(r *geoip2.Enterprise) string { return r.Location.TimeZone },
	},
	{
		Header: "postal_code",
		Getter: func(r *geoip2.Enterprise) string { return r.Postal.Code },
	},
	{
		Header: "postal_confidence",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.Postal.Confidence) },
	},
	{
		Header: "registered_country_geoname_id",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.RegisteredCountry.GeoNameID) },
	},
	{
		Header: "registered_country_iso_code",
		Getter: func(r *geoip2.Enterprise) string { return r.RegisteredCountry.IsoCode },
	},
	{
		Header: "registered_country_name",
		Getter: func(r *geoip2.Enterprise) string { return r.RegisteredCountry.Names["en"] },
	},
	{
		Header: "registered_country_confidence",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.RegisteredCountry.Confidence) },
	},
	{
		Header: "registered_country_is_in_european_union",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.RegisteredCountry.IsInEuropeanUnion) },
	},
	{
		Header: "represented_country_geoname_id",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.RepresentedCountry.GeoNameID) },
	},
	{
		Header: "represented_country_is_in_european_union",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.RepresentedCountry.IsInEuropeanUnion) },
	},
	{
		Header: "represented_country_iso_code",
		Getter: func(r *geoip2.Enterprise) string { return r.RepresentedCountry.IsoCode },
	},
	{
		Header: "represented_country_name",
		Getter: func(r *geoip2.Enterprise) string { return r.RepresentedCountry.Names["en"] },
	},
	{
		Header: "represented_country_type",
		Getter: func(r *geoip2.Enterprise) string { return r.RepresentedCountry.Type },
	},
	{
		Header: "subdivisions_geoname_id",
		Getter: func(r *geoip2.Enterprise) string {
			if len(r.Subdivisions) == 0 {
				return ""
			}
			return fmt.Sprintf("%d", r.Subdivisions[0].GeoNameID)
		},
	},
	{
		Header: "subdivisions_iso_code",
		Getter: func(r *geoip2.Enterprise) string {
			if len(r.Subdivisions) == 0 {
				return ""
			}
			return r.Subdivisions[0].IsoCode
		},
	},
	{
		Header: "subdivisions_name",
		Getter: func(r *geoip2.Enterprise) string {
			if len(r.Subdivisions) == 0 {
				return ""
			}
			return r.Subdivisions[0].Names["en"]
		},
	},
	{
		Header: "subdivisions_confidence",
		Getter: func(r *geoip2.Enterprise) string {
			if len(r.Subdivisions) == 0 {
				return ""
			}
			return fmt.Sprintf("%d", r.Subdivisions[0].Confidence)
		},
	},
	{
		Header: "traits_autonomous_system_number",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%d", r.Traits.AutonomousSystemNumber) },
	},
	{
		Header: "traits_autonomous_system_organization",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.AutonomousSystemOrganization },
	},
	{
		Header: "traits_connection_type",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.ConnectionType },
	},
	{
		Header: "traits_domain",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.Domain },
	},
	{
		Header: "traits_is_anonymous_proxy",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.Traits.IsAnonymousProxy) },
	},
	{
		Header: "traits_is_legitimate_proxy",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.Traits.IsLegitimateProxy) },
	},
	{
		Header: "traits_is_satellite_provider",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.Traits.IsSatelliteProvider) },
	},
	{
		Header: "traits_isp",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.ISP },
	},
	{
		Header: "traits_mobile_country_code",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.MobileCountryCode },
	},
	{
		Header: "traits_mobile_network_code",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.MobileNetworkCode },
	},
	{
		Header: "traits_organization",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.Organization },
	},
	{
		Header: "traits_static_ip_score",
		Getter: func(r *geoip2.Enterprise) string { return fmt.Sprintf("%v", r.Traits.StaticIPScore) },
	},
	{
		Header: "traits_user_type",
		Getter: func(r *geoip2.Enterprise) string { return r.Traits.UserType },
	},
}

func DumpEnterprise(networks *maxminddb.Networks, writer *csv.Writer, noQuotes bool) error {
	rec := geoip2.Enterprise{}
	return DumpRows(networks, writer, noQuotes, &rec, enterpriseColumns)
}
