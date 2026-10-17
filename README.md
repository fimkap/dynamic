# dynamic

Loads a large product CSV file into ScyllaDB from Swift: a million rows, read as a stream and written asynchronously with backpressure, in constant memory.

It began in February 2020 as a take-home assignment for a job interview. In October 2026 I came back to it: I answered the questions from the original code review, ran it against a current ScyllaDB, and measured each change. Each change is its own commit, with its reasons and measurements in the message.

## Quick start

You need Docker and Swift 6.1 or later, on macOS or Linux.

```
docker run --name dy-scylla -p 9042:9042 -d scylladb/scylla:latest --smp 2 --memory 4G --overprovisioned 1
swift build -c release
.build/release/dynamic 232.csv 1000000     # generate a million products
.build/release/dynamic 232.csv             # load them into dynamic.c232
```

The file name is a customer id, and the table is named after it. A load ends with a summary:

```
Wrote 1000000 rows in 19.5 s (51336 rows/s). Retries: 0. Failed rows: 0. Skipped as invalid: 0. Peak memory: 7 MB.
```

`swift test` runs the unit tests, which need no database. `scripts/benchmark.sh` measures a load in about a minute. Both are described under *Tests*.

`--in-flight <writes>` caps the writes outstanding at a time (default 512), and `--connections <count>` sets the number of connections (default 8). The exit code is 0 when every row was written and 1 otherwise. Writing a row again stores the same values, so after a partial failure it's safe to run the file again.

## The assignment

Write a Swift program that indexes a CSV file of a million products into Cassandra or ScyllaDB, into a table shaped like the file, and document how to run it and the architectural choices:

```
product_id, product_name, product_image_url, product_price, product_categories, product_stock
123, iPhone11, http://apple.com/iphone11, 650.00, cellular, 500
```

My 2020 solution used an unofficial Swift driver and wrote rows from 64 threads, each blocking on one query at a time. An asynchronous version saw some of its writes fail, so I shipped the blocking one. The code review asked:

1. The CSV parsing ignores the spec, such as quoted fields. How would you handle it?
2. Each query is built as text. Does the library support bound statements?
3. How would you write collections, tuples or user-defined types?
4. How do you provide backpressure? Are the calls blocking?
5. Every row goes into an operation queue up front. Won't a large file run out of memory?

## What I found coming back to it

**Current ScyllaDB rejected the 2020 schema, and the program hung instead of saying so.** ScyllaDB now distributes a keyspace's data with tablets, which don't support `SimpleStrategy`. The driver swallowed the error and waited forever. The keyspace now uses `NetworkTopologyStrategy`.

**The driver's request layer was broken in five ways.** [nio-scylladb](https://gitlab.nexustls.com/libraries/nio-scylladb), a port of Vapor's PostgreSQL driver to CQL:

1. never completes a request that ScyllaDB answered with an error, so the request waits forever;
2. reuses request ids under load, matching replies to the wrong requests, and eventually crashes;
3. can't send bound values, and has no prepared statements;
4. never closes an open connection;
5. leaks about 200 bytes on every request, because it drops the promise of each write.

It has no license, so I didn't fork it. The loader keeps only its message type and frame decoder, and does the rest in a connection layer of its own, `CQLConnection.swift`.

**Measuring found one more leak, in my own code.** On macOS, the CSV reader's 64 KB chunks were autoreleased objects, and the main thread of a command-line program never drains its autorelease pool, so the loader held the whole file in memory. A heap snapshot showed 639 live chunks. Each read now drains its own pool.

**The 2020 "6 minutes" was mostly the environment.** The same blocking code loads a million rows in 37 s today.

## How it works

```
CSV file ─▶ CSVReader ─▶ Product ─▶ 512 slots ─▶ prepared EXECUTE ─▶ 8 connections ─▶ ScyllaDB
            streaming,    validated,  the reader     5 s timeout,        one event loop
            RFC 4180      typed       waits when     retries             per CPU core
                                      all are taken
```

- **Streaming parser.** `CSVReader` reads the file in 64 KB chunks and walks the bytes with a five-state machine, so a quoted field can hold commas, `""` and line breaks. It holds one chunk at a time. A malformed record is reported with its line number and skipped.
- **Prepared statement.** The insert is prepared once per connection; each row then sends only the statement's id and its values in the CQL binary encoding. ScyllaDB parses one statement instead of a million, and values never need escaping.
- **Backpressure.** At most 512 writes are outstanding. When all 512 slots are taken, the reader waits for one to finish before reading the next row, so memory stays flat however large the file is, and ScyllaDB is never sent more than it is already handling.
- **Errors, timeouts and retries.** A write that fails with an error worth retrying, such as overload or a timeout, or that gets no answer within 5 seconds, is retried on the next connection after a random, growing delay. Retrying is safe because the insert is idempotent: writing the same primary key again stores the same row.
- **One row per request.** Each row is its own partition, and a batch across partitions makes one node coordinate all of it, which is slower than sending the rows directly. Writes use consistency ONE: the replica that owns the row confirms it.

## Measurements

One machine: a MacBook with an Apple M1 (8 cores, 16 GB) and ScyllaDB 2026.3.3 in Docker, started as in the quick start. Each load starts from an empty keyspace, and `SELECT COUNT(*)` checks every row afterwards. Times are medians of three runs.

| Version | 1M rows | Rows/s | Peak memory |
|---|---|---|---|
| 2020 write path: 64 blocking threads, query text | 37.3 s | 26,800 | 818 MB |
| + prepared statement | 26.2 s | 38,200 | 875 MB |
| + asynchronous writes with backpressure | 19.9 s | 50,300 | 264 MB |
| + own connection layer, chunk leak fixed | 19.5 s | 51,300 | **7 MB** |

The prepared statement saves the server's parsing; going asynchronous saves 64 threads blocking and waking. The last step is about memory, not speed: 7 MB at 250,000 rows and at 1,000,000, so memory no longer depends on the file. Memory here is macOS's peak memory footprint, which counts memory the system has compressed. The resident size doesn't, and it understated the 2020 loader three times over.

Three experiments, each run once:

- **Pausing ScyllaDB** for 10 seconds mid-load: the reader stopped when all 512 slots were full, every write in flight timed out twice (1,024 retries), and all 1,000,000 rows were stored.
- **No limit on writes in flight**, as in my 2020 async attempt. Through the driver, memory reached 3.8 GB, ScyllaDB answered 70,099 writes with timeouts, and the driver crashed on a reply to a request id it had reused. Through the new connection layer, the run finished in 24 s with 99.4% of rows confirmed and the rest reported. Both times ScyllaDB stored more rows than the loader confirmed: a timeout means "unknown", not "failed", which is why idempotent inserts matter.
- **The size of the window**, measured before the new connection layer: 64 writes in flight gave 41,700 rows/s, 512 gave 50,300, and 8,192 gave 71,700. Throughput is the writes in flight divided by the time each takes (Little's law), so a larger window helps until ScyllaDB saturates. 512 stays the default because the window caps the load one loader puts on a server it knows nothing about.

## Tests

The unit tests (`swift test`) need no database and run in under a tenth of a second once built. Each file checks one idea:

- `CSVReaderTests`: the RFC 4180 rules, recovery from malformed records, and every input read at chunk sizes from 1 byte up, because chunk boundaries are where a streaming parser breaks.
- `ProductTests`: validation against the column types, such as ids that must fit a 32-bit `int`.
- `PreparedStatementTests`: the exact bytes of PREPARE, EXECUTE and the encoded values, checked against the protocol specification. One wrong byte and ScyllaDB rejects or misreads the request.
- `CQLConnectionTests`: the request layer on SwiftNIO's in-memory `EmbeddedChannel`, one test for each thing the driver got wrong: replies out of order, error frames, completed writes, id reuse, unknown frames, and closing.
- `RetriesTests`: timeouts and retry delays on a virtual clock, so a 5-second timeout takes no time.
- `TallyTests` and `CSVCreatorTests`: counting from many threads, and a generated file that reads back unchanged.

`scripts/benchmark.sh` needs ScyllaDB and takes about a minute. It loads 250,000 rows and then a million, checks the stored count, and prints the loader's time, throughput and peak memory. It uses two sizes because the same peak memory at both shows that memory doesn't grow with the file.

## Not done yet

- **Collections and user-defined types** (question 3). The table has only scalar columns. A `set<text>` is easy to send: in protocol v3 it's a 4-byte element count, then each element as a 4-byte length and its bytes, so `CQLValue` would gain a `set` case.
- **Shard-aware routing.** ScyllaDB splits its data among CPU cores, and its own drivers send each request straight to the core that owns the row. This loader's requests land wherever the connection does.
- **Decimal prices.** `product_price` is a CQL `float`, as in 2020; money should be a `decimal`.

## Layout

```
Sources/dynamic/
  main.swift               command line, exit codes
  CSVReader.swift          streaming RFC 4180 parser
  Product.swift            row validation
  CSVCreator.swift         test-file generator
  driver.swift             schema, the write loop, retries
  CQLConnection.swift      handshake, request ids, errors
  PreparedStatement.swift  PREPARE and EXECUTE
  Retries.swift            timeouts and retry delays
  ConnectionPool.swift     round-robin connections
  Tally.swift              counts, summary, peak memory
Tests/dynamicTests/        one file per idea above
scripts/benchmark.sh       the one-minute measurement
```
