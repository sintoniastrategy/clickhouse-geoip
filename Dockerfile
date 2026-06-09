# syntax=docker/dockerfile:1
#
# "updater" image: builds mmdb2csv from source and ships a clickhouse-client
# so bin/clickhouse-geoip-updater.sh can run as a one-shot batch job against a
# remote ClickHouse server.

# --- Stage 1: build mmdb2csv from Go source ---
FROM golang:1.23-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/mmdb2csv ./cmd/mmdb2csv

# --- Stage 2: updater runtime ---
FROM debian:bookworm-slim AS runtime

# clickhouse-client (single multi-call binary) is copied from the official
# server image; curl/gzip/ca-certificates are needed by the updater script.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gzip \
 && rm -rf /var/lib/apt/lists/*

COPY --from=clickhouse/clickhouse-server:24.8 /usr/bin/clickhouse /usr/bin/clickhouse
RUN ln -s /usr/bin/clickhouse /usr/bin/clickhouse-client \
 && clickhouse-client --version

WORKDIR /app
COPY --from=build /out/mmdb2csv /app/bin/mmdb2csv
COPY bin/clickhouse-geoip-updater.sh /app/bin/clickhouse-geoip-updater.sh
COPY sql/ /app/sql/
RUN chmod +x /app/bin/mmdb2csv /app/bin/clickhouse-geoip-updater.sh

# Point bare `clickhouse-client` calls at the compose service by default.
COPY docker/clickhouse-client.xml /etc/clickhouse-client/config.xml

ENV WORK_DIR=/app \
    CLICKHOUSE_DB=geoip

ENTRYPOINT ["/app/bin/clickhouse-geoip-updater.sh"]
