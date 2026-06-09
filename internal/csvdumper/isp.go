package csvdumper

import (
	"encoding/csv"
	"fmt"

	"github.com/oschwald/geoip2-golang"
	"github.com/oschwald/maxminddb-golang"
)

var ispColumns = []Column[geoip2.ISP]{
	{
		Header: "autonomous_system_number",
		Getter: func(r *geoip2.ISP) string { return fmt.Sprintf("%d", r.AutonomousSystemNumber) },
	},
	{
		Header: "autonomous_system_organization",
		Getter: func(r *geoip2.ISP) string { return r.AutonomousSystemOrganization },
	},
	{
		Header: "isp",
		Getter: func(r *geoip2.ISP) string { return r.ISP },
	},
	{
		Header: "organization",
		Getter: func(r *geoip2.ISP) string { return r.Organization },
	},
}

func DumpISP(networks *maxminddb.Networks, writer *csv.Writer, noQuotes bool) error {
	rec := geoip2.ISP{}
	return DumpRows(networks, writer, noQuotes, &rec, ispColumns)
}
