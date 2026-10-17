# dynamic

Loads a large product CSV file into ScyllaDB from Swift: a million rows, through an unofficial CQL driver, with a streaming CSV parser, prepared statements, backpressure and retries.

It started in February 2020 as a take-home assignment for a job interview. In October 2026 I came back to it: I worked through the questions from the original code review, ran it against a current ScyllaDB, and measured every change. This README tells that story, with the numbers.

## Quick start

You need Docker and Swift 6.1 or later, on macOS or Linux.

Start ScyllaDB with two CPU cores and 4 GB of memory:

```
docker run --name dy-scylla -p 9042:9042 -d scylladb/scylla:latest --smp 2 --memory 4G --overprovisioned 1
```

Build, generate a file of a million products, and load it:

```
swift build -c release
.build/release/dynamic 232.csv 1000000
.build/release/dynamic 232.csv
```

The file name is a customer id, and the rows go to the table `dynamic.c232`. A load ends with a summary:

```
Wrote 1000000 rows in 15.6 s (63920 rows/s). Retries: 0. Failed rows: 0. Skipped as invalid: 0. Peak memory: 263 MB.
```

The tests need no database:

```
swift test
```

To measure a load, repeat it from an empty keyspace each time:

```
scripts/benchmark.sh 232.csv 3
```

### Options

```
--in-flight <writes>    most writes outstanding at a time (default 512)
--connections <count>   connections to Scylla (default 8)
```

The exit code is 0 when every row was written, and 1 on an error, or when rows failed or were skipped as invalid. Writing a row again stores the same values, so after a partial failure it's safe to run the file again.

The parser follows RFC 4180, with three allowances: whitespace around a field is ignored, as in the assignment's sample (`123, iPhone11, ...`); a byte-order mark at the start of the file is skipped; and a quote inside an unquoted field is kept as a character.

## The assignment

Write a Swift program that indexes a CSV file of a million products into Cassandra or ScyllaDB, into a table shaped like the file:

```
product_id, product_name, product_image_url, product_price, product_categories, product_stock
123, iPhone11, http://apple.com/iphone11, 650.00, cellular, 500
```

and document how to run it and the architectural choices.

My 2020 solution used an unofficial Swift driver built on SwiftNIO. It read the file line by line and wrote the rows from 64 threads, each blocking on one query at a time. An earlier version wrote asynchronously, but some of its writes failed, so I shipped the blocking one. It loaded a million rows in about 6 minutes.

The code review asked five questions, and they shaped this revision:

1. The CSV parsing ignores the spec, such as quoted fields and `""`. How would you handle it?
2. Each query is built as text. Does the library support bound statements?
3. How would you write collections, tuples or user-defined types?
4. How do you provide backpressure? Are the calls blocking?
5. Every row goes into an operation queue up front. Won't a large file run out of memory?

## What I found coming back to it

**Current ScyllaDB rejected the 2020 schema, and the program hung instead of saying so.** ScyllaDB now places a new keyspace's data with tablets, and tablets don't support `SimpleStrategy`. `CREATE KEYSPACE` failed with "SimpleStrategy doesn't support tablet replication", even with `IF NOT EXISTS`. The driver logged the error and went on waiting for a reply, so the loader sat at 0% CPU indefinitely. The keyspace now uses `NetworkTopologyStrategy`.

**The driver has five bugs that matter.** [nio-scylladb](https://gitlab.nexustls.com/libraries/nio-scylladb) is a port of Vapor's PostgreSQL driver to CQL, and some PostgreSQL assumptions survived the port:

1. **An error never completes its request.** In the PostgreSQL protocol an error is followed by a "ready" message, which is what ends the request. CQL sends nothing after an `ERROR` frame, so the request waits forever. This hung the schema statement, and it's what broke the 2020 async version: under load, ScyllaDB answers some writes with a timeout error, and those writes never finish. The no-limit run below reproduces it.
2. **Request ids are reused under load.** Each connection numbers its requests with a 16-bit counter that wraps around. With more than 65,536 requests outstanding on one connection, a new request takes the id of one still waiting, and replies get matched to the wrong request. The counter also passes through the negative ids that protocol v3 reserves for server events; ScyllaDB accepted those in every run here.
3. **There are no bound values or prepared statements.** The query flags are written as two bytes where protocol v3 has one, so the "values follow" flag never reaches the server, and `PREPARE` isn't implemented.
4. **`close()` never closes an open connection.** Its check is inverted. Connections close only when the event loops shut down.
5. **Every request leaks about 200 bytes.** The driver's request handler never completes the promise of the write it's given. In SwiftNIO a future and the callbacks waiting on it reference each other, and completing the future is what breaks the cycle. So for every request, the uncompleted write future, its callback, and the response future it holds stay in memory for good. The memory measurements below found this one.

The driver has no license file, so I didn't fork it or copy it into this repository. Everything here works around it from the outside, through its public request interface. Bug 5 can't be worked around that way; see *Not done yet*.

**The 2020 "6 minutes" was mostly the environment.** The same blocking code loads a million rows in 37.3 s today. The 2020 run used a debug build on a laptop of that time, with an older Docker.

## What changed

| Commit | Change | Answers |
|---|---|---|
| `ecebd19` | Build as a Swift package and use the driver directly | Builds with `swift build` on macOS and Linux; drops the ScyllaKit layer and its 2020 beta dependencies |
| `ca9f3ea` | Parse CSV files per RFC 4180 | Question 1 |
| `6ff41ef` | Create the keyspace with `NetworkTopologyStrategy` | Current ScyllaDB and its tablets |
| `b511a23` | Insert rows with a prepared statement and bound values | Question 2 |
| `b60bb7b` | Write asynchronously with backpressure, timeouts and retries | Questions 4 and 5; driver bug 1 |
| `7817b51` | Report time, throughput and peak memory; exit non-zero on failures | Measuring all of the above |

The baseline in the measurements is the 2020 code with only the keyspace fix applied, since without it nothing loads at all.

## Architecture

```
CSV file ─▶ CSVReader ─▶ Product ─▶ 512 slots ─▶ prepared EXECUTE ─▶ 8 connections ─▶ ScyllaDB
            streaming,    validated,  the reader     5 s timeout,        one event loop
            RFC 4180      typed       waits when     retries with        per CPU core
                                      all are taken  backoff
```

**Parsing.** `CSVReader` is a five-state machine over bytes, reading the file in 64 KB chunks. In UTF-8 the comma, quote and line-break bytes never occur inside a multi-byte character, so it can scan bytes and decode each field once. A malformed record is reported with its line number and skipped, and loading continues. Every parser test runs its input at chunk sizes down to one byte, which splits every record and every multi-byte character across chunks. I wrote it rather than add a dependency: the spec fits in five states, and it streams.

**Prepared statement.** The insert is prepared once on each connection; each row then sends only the statement's id and its values in the CQL binary encoding. That removes per-row parsing on the server and any need to escape values. The driver can't do it, but its connection sends any request that conforms to its `ScyllaRequest` protocol, so `PrepareRequest` and `ExecuteRequest` build the `PREPARE` and `EXECUTE` messages themselves. The tests check their bytes against the protocol specification.

**Backpressure.** At most 512 writes are outstanding. When all 512 slots are taken, the reader waits for a write to finish before it reads the next row. The reader is the only thread that ever blocks; the event loops never do. ScyllaDB is never sent more than it is already handling, and the loader never holds more than 512 rows, however large the file is. (The driver still leaks a little per request: see *Memory as the file grows*.)

**Timeouts and retries.** Because of driver bug 1, every request races a 5-second timer, and whichever finishes first wins. A failed or timed-out write is retried on the next connection, up to 5 attempts, after a random delay under a ceiling that doubles each time (50 ms, 100 ms, … up to 2 s), so that writes which failed together don't all retry at the same moment. Retrying is safe because the insert is idempotent: writing a row with the same primary key again stores the same values. That also covers a write that timed out on our side but did reach ScyllaDB.

**One row per request, not batches.** Each row has its own partition key. A batch across partitions makes one node coordinate all of it, which is slower than sending the rows directly.

**Consistency ONE.** The replica that owns the row must confirm the write. The 2020 code used ANY, which also accepts a write stored only as a hint for later delivery.

## Measurements

All numbers come from one machine: a MacBook with an Apple M1 (8 cores, 16 GB), running ScyllaDB 2026.3.3 in Docker Desktop, started as in the quick start, with Docker's VM given 4 CPUs and 6 GB and its disk on an external NVMe SSD. The loader runs natively on macOS as a release build. Every run starts from an empty keyspace and loads the same million-row file, and afterwards `SELECT COUNT(*)` checks what was stored. Times are wall clock for the whole process.

| | Time | Rows/s | System CPU | Peak memory |
|---|---|---|---|---|
| 2020 write path: 64 threads, each blocking on query text | 37.3 s | 26,800 | 16.9 s | 818 MB |
| + prepared statement | 26.2 s | 38,200 | 15.8 s | 875 MB |
| + asynchronous writes, 512 in flight | 19.9 s | 50,300 | 11.5 s | 264 MB |

Times and CPU are medians of three runs; memory comes from one further run of each. Every run stored all 1,000,000 rows.

The prepared statement cut the time by 30%: ScyllaDB parses one statement instead of a million, and the client stops building query text. Going asynchronous cut another 24%, and system CPU time, much of it 64 threads blocking and waking, fell by a quarter. The first two versions queue an operation for every row before writing it; the new loader holds at most 512 rows. The asynchronous version also varied most between runs, from 17.1 to 22.8 s.

### Memory as the file grows

| Rows | 2020 write path | New loader |
|---|---|---|
| 1,000,000 | 818 MB | 264 MB |
| 3,000,000 | 2,470 MB | 784 MB |

Backpressure was meant to make the new loader's memory independent of the file, and it doesn't: both grow in proportion, the new loader at a third of the rate. A heap snapshot 15 seconds into a 3M-row load showed why. The objects tied to a request in flight numbered exactly 512 of each kind, as the cap intends. But there were 1.7 million `EventLoopFuture` objects and 850,000 closures: two futures and a closure for every row written so far. `leaks` traced them to reference cycles allocated in `channel.write`, called from the driver's `send()`. That's bug 5.

Memory here is the *peak memory footprint*, which on macOS includes memory the system has compressed. The resident size doesn't, and under memory pressure it misleads: for the 2020 loader on 3M rows it showed 761 MB against a footprint of 2,470 MB. The loader's summary reports the footprint for the same reason.

### How many writes in flight

Single runs of the new loader on the same file:

| Writes in flight | Time | Rows/s |
|---|---|---|
| 64 | 24.0 s | 41,700 |
| 128 | 21.2 s | 47,200 |
| 512 (default) | 19.9 s | 50,300 |
| 2,048 | 16.7 s | 60,100 |
| 8,192 | 13.9 s | 71,700 |
| no limit | crashed after 63 s | |

Throughput is the number of writes in flight divided by the time each one takes (Little's law). With 64 in flight each write takes about 1.5 ms end to end; with 512, about 10 ms; with 8,192, about 114 ms, so ScyllaDB is close to saturated and extra requests mostly wait in its queues. Raising the window keeps paying off up to 8,192 here, 43% faster than the default. The default stays at 512 because the window caps how much load one loader puts on a server it knows nothing about, and on a shared cluster, saturating it to finish a bulk load sooner is the wrong trade. `--in-flight` tunes it for a given server.

### Pausing ScyllaDB mid-load

I paused the ScyllaDB container 5 seconds into a load and resumed it 10 seconds later. The reader stopped as soon as all 512 slots were full. Every write in flight timed out twice, 5 seconds apart, giving exactly 1,024 retries (512 × 2), and succeeded after the resume. On waking, ScyllaDB answered 177 of the abandoned requests with its own `writeTimeout`, the error the driver never passes on. The run took 39.0 s instead of about 20, and all 1,000,000 rows were stored, none failed.

### No limit at all: the 2020 failure, reproduced

With `--in-flight 100000000`, every row is sent as soon as it's read, as in my 2020 async attempt:

- memory reached 3.8 GB;
- ScyllaDB was overloaded and answered 70,099 writes with `writeTimeout`;
- the loader retried 2.6 million times and confirmed only 351,154 rows, at 5,574 rows per second, before giving up on the other 648,846;
- then the process crashed inside the driver: `ScyllaConnectionHandler.swift:73: Fatal error: Received message without request`. That's bug 2: a connection had more than 65,536 requests outstanding, its id counter wrapped, and a reply arrived for an id the driver had lost.

Yet ScyllaDB had stored 992,601 rows. Most of the writes the loader counted as failed had in fact been applied; only their acknowledgements were lost. A timeout means "unknown", not "failed", and that's why the inserts being idempotent matters: running the file again completes the load safely.

### What limits it now

- ScyllaDB runs on 2 cores inside a 4-CPU VM, on the same laptop as the loader and its 8 event loops.
- Every request crosses from macOS into Docker's VM and back.
- The driver isn't shard-aware. ScyllaDB splits its data among CPU cores, and a request that arrives at the wrong core is forwarded to the right one. ScyllaDB's own drivers send each request straight to the core that owns the row.

## Not done yet

- **A connection handler of my own, to fix bug 5.** The driver's frame encoder and decoder are public. A request handler on top of them could assign request ids properly, complete every write, and fail a request with ScyllaDB's actual error instead of leaving it waiting. That would fix bugs 1, 2, 4 and 5 at once, and leave the timeouts as a safety net rather than the only way to notice an error.
- **Collections, tuples and user-defined types** (question 3). The table has only scalar columns. On the way in, a collection is not hard: in protocol v3 a `set<text>` is a 4-byte element count followed by each element as a 4-byte length and its bytes, so `CQLValue` would gain a `set` case, and `product_categories` could become a set.
- **Shard-aware routing**, as ScyllaDB's own drivers do it.
- **Decimal prices.** `product_price` is a CQL `float`, as in 2020. Money should be a `decimal`.
- **Swift 6 language mode.** The package builds in Swift 5 mode. Strict concurrency checking would need the shared state, now guarded by locks and event loops, to be declared `Sendable`.

## Layout

```
Sources/dynamic/
  main.swift               command line, exit codes
  CSVReader.swift          streaming RFC 4180 parser
  Product.swift            row validation and conversion
  CSVCreator.swift         test-file generator
  driver.swift             schema, connection setup, the write loop
  PreparedStatement.swift  PREPARE and EXECUTE on top of the driver
  Retries.swift            timeouts and retry delays
  ConnectionPool.swift     round-robin connections
  Tally.swift              counts, summary, peak memory
Tests/dynamicTests/        parser, validation, encoding, timeouts, tally
scripts/benchmark.sh       repeated loads from an empty keyspace
```
