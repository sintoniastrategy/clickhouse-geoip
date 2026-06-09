package csvdumper

import (
	"encoding/csv"
	"log"
	"strings"

	"github.com/oschwald/maxminddb-golang"
)

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

func DumpRows[R any](
	networks *maxminddb.Networks,
	writer *csv.Writer,
	noQuotes bool,
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

	for networks.Next() {
		subnet, err := networks.Network(record)
		if err != nil {
			log.Fatalln(err)
		}
		row := make([]string, 0, len(cols)+1)
		row = append(row, subnet.String())
		for _, c := range cols {
			row = append(row, c.Getter(record))
		}
		if noQuotes {
			err = writer.Write(removeUnsafeChars(row))
		} else {
			err = writer.Write(row)
		}
		if err != nil {
			return err
		}
	}
	return nil
}
