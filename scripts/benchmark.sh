#!/usr/bin/env bash
# Measure the loader against a running ScyllaDB, in about a minute.
#
# Loads 250,000 rows, then 1,000,000, each into an empty keyspace (the keyspace `dynamic` is
# dropped first), and checks how many rows were stored. The loader reports its own time,
# throughput and peak memory. Two sizes, because peak memory that stays the same between
# them shows that memory doesn't grow with the file.
#
#   scripts/benchmark.sh
#   scripts/benchmark.sh --in-flight 4096
#
# Needs ScyllaDB in the Docker container named by SCYLLA_CONTAINER (default: dy-scylla).
# The test files are generated on first use, in this directory's parent.
set -euo pipefail
cd "$(dirname "$0")/.."
container=${SCYLLA_CONTAINER:-dy-scylla}
loader=.build/release/dynamic

swift build -c release -q
for rows in 250000 1000000; do
    file="$rows.csv"
    [[ -f $file ]] || "$loader" "$file" "$rows"
    docker exec "$container" cqlsh -e "DROP KEYSPACE IF EXISTS dynamic"
    "$loader" "$@" "$file" || true
    stored=$(docker exec "$container" cqlsh --request-timeout=300 -e "SELECT COUNT(*) FROM dynamic.c$rows" | sed -n 4p | tr -d ' ')
    echo "  rows stored: $stored"
done
