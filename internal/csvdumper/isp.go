package csvdumper

import (
	"encoding/csv"
	"fmt"

	"github.com/oschwald/maxminddb-golang"
)

// ispRecord covers both shapes these fields arrive in: GeoIP2-ISP carries
// them at the top level, Enterprise-shaped databases nest them under traits
// and leave the top empty — DB-IP's "IP to Location + ISP" is one of those.
// Without reading both, -db-type asn emits empty ASN columns and no error.
type ispRecord struct {
	AutonomousSystemNumber       uint   `maxminddb:"autonomous_system_number"`
	AutonomousSystemOrganization string `maxminddb:"autonomous_system_organization"`
	ISP                          string `maxminddb:"isp"`
	Organization                 string `maxminddb:"organization"`

	Traits struct {
		AutonomousSystemNumber       uint   `maxminddb:"autonomous_system_number"`
		AutonomousSystemOrganization string `maxminddb:"autonomous_system_organization"`
		ISP                          string `maxminddb:"isp"`
		Organization                 string `maxminddb:"organization"`
	} `maxminddb:"traits"`
}

func firstNonEmpty(top, nested string) string {
	if top != "" {
		return top
	}
	return nested
}

func firstNonZero(top, nested uint) uint {
	if top != 0 {
		return top
	}
	return nested
}

var ispColumns = []Column[ispRecord]{
	{
		Header: "autonomous_system_number",
		Getter: func(r *ispRecord) string {
			return fmt.Sprintf("%d", firstNonZero(r.AutonomousSystemNumber, r.Traits.AutonomousSystemNumber))
		},
	},
	{
		Header: "autonomous_system_organization",
		Getter: func(r *ispRecord) string {
			return firstNonEmpty(r.AutonomousSystemOrganization, r.Traits.AutonomousSystemOrganization)
		},
	},
	{
		Header: "isp",
		Getter: func(r *ispRecord) string { return firstNonEmpty(r.ISP, r.Traits.ISP) },
	},
	{
		Header: "organization",
		Getter: func(r *ispRecord) string { return firstNonEmpty(r.Organization, r.Traits.Organization) },
	},
}

func DumpISP(networks *maxminddb.Networks, writer *csv.Writer, noQuotes bool, collapse bool) error {
	rec := ispRecord{}
	return DumpRows(networks, writer, noQuotes, collapse, &rec, ispColumns)
}
