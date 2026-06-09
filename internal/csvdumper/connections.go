package csvdumper

import (
	"encoding/csv"

	"github.com/oschwald/geoip2-golang"
	"github.com/oschwald/maxminddb-golang"
)

var connectionsColumns = []Column[geoip2.ConnectionType]{
	{
		Header: "connection_type",
		Getter: func(r *geoip2.ConnectionType) string { return r.ConnectionType },
	},
}

func DumpConnections(networks *maxminddb.Networks, writer *csv.Writer, noQuotes bool) error {
	rec := geoip2.ConnectionType{}
	return DumpRows(networks, writer, noQuotes, &rec, connectionsColumns)
}
