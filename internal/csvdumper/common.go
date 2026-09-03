package csvdumper

import (
	"encoding/csv"
	"log"
	"net/netip"
	"strings"

	"github.com/oschwald/maxminddb-golang"
)

// maxminddbNetworks aliases the iterator so the generic signature below
// stays readable.
type maxminddbNetworks = maxminddb.Networks

func removeUnsafeChars(strarr []string) []string {
	output := []string{}
	replacer := strings.NewReplacer("\"", "", "'", "")

	for _, str := range strarr {
		output = append(output, strings.TrimSpace(replacer.Replace(str)))
	}
	return output
}

type ValueGetter[R any] func(*R) string

type Column[R any] struct {
	Header string
	Getter ValueGetter[R]
}

func writeRow(writer *csv.Writer, row []string, noQuotes bool) error {
	if noQuotes {
		return writer.Write(removeUnsafeChars(row))
	}
	return writer.Write(row)
}

func sameValues(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func DumpRows[R any](
	networks *maxminddbNetworks,
	writer *csv.Writer,
	noQuotes bool,
	collapse bool,
	record *R,
	cols []Column[R],
) error {
	// headers: prepend prefix
	headers := make([]string, 0, len(cols)+1)
	headers = append(headers, "prefix")
	for _, c := range cols {
		headers = append(headers, c.Header)
	}
	if err := writer.Write(headers); err != nil {
		return err
	}

	emit := func(prefixes []netip.Prefix, values []string) error {
		for _, p := range prefixes {
			row := make([]string, 0, len(values)+1)
			row = append(row, p.String())
			row = append(row, values...)
			if err := writeRow(writer, row, noQuotes); err != nil {
				return err
			}
		}
		return nil
	}

	var (
		pending  run
		prev     []string
		havePrev bool
	)

	for networks.Next() {
		// The same struct is reused for every network and maxminddb leaves
		// fields absent from a record untouched, so without clearing it a
		// missing field silently inherits the previous row's value. Not
		// hypothetical: measured over all 88 815 946 networks of DB-IP's
		// Location+ISP database, 9 246 803 (10.4%) carry no organization
		// and 1 550 298 (1.7%) no autonomous_system_number — and without
		// this every one of them was served the previous network's value.
		var zero R
		*record = zero

		subnet, err := networks.Network(record)
		if err != nil {
			log.Fatalln(err)
		}

		values := make([]string, 0, len(cols))
		for _, c := range cols {
			values = append(values, c.Getter(record))
		}

		prefix, convertible := netip.Prefix{}, false
		if collapse {
			prefix, convertible = toPrefix(subnet)
		}
		if !collapse || !convertible {
			row := make([]string, 0, len(values)+1)
			row = append(row, subnet.String())
			row = append(row, values...)
			if err := writeRow(writer, row, noQuotes); err != nil {
				return err
			}
			continue
		}

		if havePrev && (!sameValues(prev, values) || pending.full()) {
			if err := emit(pending.drain(), prev); err != nil {
				return err
			}
		}
		pending.add(prefix)
		prev = values
		havePrev = true
	}

	if havePrev {
		if err := emit(pending.drain(), prev); err != nil {
			return err
		}
	}
	return nil
}
