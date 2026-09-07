package csvdumper

import (
	"encoding/csv"
	"net/netip"
	"slices"
	"strings"

	"github.com/oschwald/maxminddb-golang"
)

type ValueGetter[R any] func(*R) string

type Column[R any] struct {
	Header string
	Getter ValueGetter[R]
}

var unsafeChars = strings.NewReplacer(`"`, "", "'", "")

func dumpRow(writer *csv.Writer, prefix string, values []string, noQuotes bool) error {
	row := make([]string, 0, len(values)+1)
	row = append(row, prefix)
	row = append(row, values...)
	if noQuotes {
		for i, field := range row {
			row[i] = strings.TrimSpace(unsafeChars.Replace(field))
		}
	}
	return writer.Write(row)
}

type collapser struct {
	writer   *csv.Writer
	noQuotes bool

	stack  mergeStack
	values []string
	open   bool
}

func (c *collapser) add(p netip.Prefix, values []string) error {
	if c.open && (!slices.Equal(c.values, values) || c.stack.full()) {
		if err := c.flush(); err != nil {
			return err
		}
	}
	c.stack.push(p)
	c.values = values
	c.open = true
	return nil
}

func (c *collapser) flush() error {
	if !c.open {
		return nil
	}
	for _, p := range c.stack.drain() {
		if err := dumpRow(c.writer, p.String(), c.values, c.noQuotes); err != nil {
			return err
		}
	}
	c.open = false
	return nil
}

func DumpRows[R any](
	networks *maxminddb.Networks,
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

	runs := collapser{writer: writer, noQuotes: noQuotes}

	for networks.Next() {
		// maxminddb leaves absent fields untouched and the struct is reused for
		// the whole traversal, so without this a missing field inherits the
		// previous network's value
		var zero R
		*record = zero

		subnet, err := networks.Network(record)
		if err != nil {
			return err
		}

		values := make([]string, 0, len(cols))
		for _, c := range cols {
			values = append(values, c.Getter(record))
		}

		prefix, mergeable := netip.Prefix{}, false
		if collapse {
			prefix, mergeable = toPrefix(subnet)
		}
		if !mergeable {
			if err := dumpRow(writer, subnet.String(), values, noQuotes); err != nil {
				return err
			}
			continue
		}
		if err := runs.add(prefix, values); err != nil {
			return err
		}
	}

	return runs.flush()
}
