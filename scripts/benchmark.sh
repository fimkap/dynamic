#!/usr/bin/env bash
# Load a csv file into ScyllaDB several times and print each run's summary and the rows stored.
# Drops the keyspace `dynamic` before every run, so each one starts from an empty table.
#
#   scripts/benchmark.sh 232.csv 3 --in-flight 512
#
# Needs a release build (swift build -c release) and ScyllaDB running in the Docker container
# named by SCYLLA_CONTAINER (default: dy-scylla).
set -euo pipefail

file=${1:?usage: scripts/benchmark.sh <file.csv> [runs] [loader options...]}
runs=${2:-3}
shift $(( $# < 2 ? $# : 2 ))
container=${SCYLLA_CONTAINER:-dy-scylla}
table="c$(basename "${file%.*}")"
loader="$(dirname "$0")/../.build/release/dynamic"

for run in $(seq "$runs"); do
    docker exec "$container" cqlsh -e "DROP KEYSPACE IF EXISTS dynamic"
    summary=$("$loader" "$@" "$file" | grep '^Wrote' || true)
    stored=$(docker exec "$container" cqlsh --request-timeout=600 -e "SELECT COUNT(*) FROM dynamic.$table" | sed -n 4p | tr -d ' ')
    echo "run $run: $summary Stored: $stored rows."
done
