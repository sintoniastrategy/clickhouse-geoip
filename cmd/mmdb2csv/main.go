package main

import (
	"encoding/csv"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/sintoniastrategy/clickhouse-geoip/internal/csvdumper"

	"github.com/oschwald/maxminddb-golang"
)

// version is set at build time via -ldflags (GoReleaser injects the release tag).
var version = "dev"

// ClickHouse CSV mode
var (
	noQuotes    bool
	dbTypeFlag  string
	dbPathFlag  string
	showVersion bool
)

func init() {
	flag.BoolVar(&noQuotes, "no-quotes", false, "do not quote fields")
	flag.StringVar(&dbTypeFlag, "db-type", "", "database type to dump: city, connections, country, isp, enterprise")
	flag.StringVar(&dbPathFlag, "db-path", "", "path to the MMDB file")
	flag.BoolVar(&showVersion, "version", false, "print version and exit")
}

func main() {
	flag.Parse()

	if showVersion {
		fmt.Println("mmdb2csv", version)
		return
	}

	// Determine MMDB path
	fullPath := dbPathFlag
	if fullPath == "" {
		if flag.NArg() > 0 {
			fullPath = flag.Args()[0]
		} else {
			log.Fatal("Please provide --db-path to the mmdb file")
		}
	}

	// open mmdb
	db, err := maxminddb.Open(fullPath)
	if err != nil {
		log.Fatal(err)
	}
	defer func(db *maxminddb.Reader) {
		err := db.Close()
		if err != nil {
			// ignore
		}
	}(db)

	// open CSV writer, and write header
	writer := csv.NewWriter(os.Stdout)
	defer writer.Flush()

	// skip aliased networks
	networks := db.Networks(maxminddb.SkipAliasedNetworks)
	if networks.Err() != nil {
		log.Fatalln(networks.Err())
	}
	var err2 error
	switch strings.ToLower(dbTypeFlag) {
	case "city":
		err2 = csvdumper.DumpCity(networks, writer, noQuotes)
	case "connections":
		err2 = csvdumper.DumpConnections(networks, writer, noQuotes)
	case "country":
		err2 = csvdumper.DumpCountry(networks, writer, noQuotes)
	case "isp", "asn":
		err2 = csvdumper.DumpISP(networks, writer, noQuotes)
	case "enterprise":
		err2 = csvdumper.DumpEnterprise(networks, writer, noQuotes)
	default:
		log.Fatal("Please provide --db-type as one of: city, connections, country, isp, enterprise")
	}
	if err2 != nil {
		log.Fatal(err2.Error())
	}
	if networks.Err() != nil {
		log.Panic(networks.Err())
	}
}
