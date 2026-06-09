package csvdumper

import (
	"encoding/csv"
	"fmt"

	"github.com/oschwald/geoip2-golang"
	"github.com/oschwald/maxminddb-golang"
)

var countryColumns = []Column[geoip2.Country]{
	{
		Header: "continent_code",
		Getter: func(r *geoip2.Country) string { return r.Continent.Code },
	},
	{
		Header: "continent_geoname_id",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%d", r.Continent.GeoNameID) },
	},
	{
		Header: "continent_name",
		Getter: func(r *geoip2.Country) string { return r.Continent.Names["en"] },
	},
	{
		Header: "country_geoname_id",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%d", r.Country.GeoNameID) },
	},
	{
		Header: "country_is_in_european_union",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%v", r.Country.IsInEuropeanUnion) },
	},
	{
		Header: "country_iso_code",
		Getter: func(r *geoip2.Country) string { return r.Country.IsoCode },
	},
	{
		Header: "country_name",
		Getter: func(r *geoip2.Country) string { return r.Country.Names["en"] },
	},
	{
		Header: "registered_country_geoname_id",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%d", r.RegisteredCountry.GeoNameID) },
	},
	{
		Header: "registered_country_is_in_european_union",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%v", r.RegisteredCountry.IsInEuropeanUnion) },
	},
	{
		Header: "registered_country_iso_code",
		Getter: func(r *geoip2.Country) string { return r.RegisteredCountry.IsoCode },
	},
	{
		Header: "registered_country_name",
		Getter: func(r *geoip2.Country) string { return r.RegisteredCountry.Names["en"] },
	},
	{
		Header: "represented_country_geoname_id",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%d", r.RepresentedCountry.GeoNameID) },
	},
	{
		Header: "represented_country_is_in_european_union",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%v", r.RepresentedCountry.IsInEuropeanUnion) },
	},
	{
		Header: "represented_country_iso_code",
		Getter: func(r *geoip2.Country) string { return r.RepresentedCountry.IsoCode },
	},
	{
		Header: "represented_country_type",
		Getter: func(r *geoip2.Country) string { return r.RepresentedCountry.Type },
	},
	{
		Header: "traits_is_anonymous_proxy",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%v", r.Traits.IsAnonymousProxy) },
	},
	{
		Header: "traits_is_satellite_provider",
		Getter: func(r *geoip2.Country) string { return fmt.Sprintf("%v", r.Traits.IsSatelliteProvider) },
	},
}

func DumpCountry(networks *maxminddb.Networks, writer *csv.Writer, noQuotes bool) error {
	rec := geoip2.Country{}
	return DumpRows(networks, writer, noQuotes, &rec, countryColumns)
}
