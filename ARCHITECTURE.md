# Testcontainers Zig — Architecture

This document describes the internal design and architectural decisions of the library.
For a feature inventory and implementation stats see [PROJECT_SUMMARY.md](PROJECT_SUMMARY.md).
For usage examples and getting-started instructions see [QUICKSTART.md](QUICKSTART.md).

## Design Goals

| Goal | Approach |
|------|----------|
| Zig-first | Tagged unions, comptime, `errdefer`, manual allocation — no hidden allocations |
| Type safety | Comptime-checked configuration; all errors are explicit in return types |
| Developer experience | Simple struct-literal configuration, namespace-based wait strategy DSL |
| Minimal coupling | Single library; no external dependencies — built-in HTTP/1.1 client over Unix domain socket |
| Testability | `DockerClient` is injected via value; containers clean up deterministically |

## Component Overview

The library is a single Zig module (`testcontainers`) with a clear layering:

```
testcontainers (src/root.zig)
  │
  ├── DockerProvider          — allocates & owns DockerClient, drives container lifecycle
  ├── DockerContainer         — running container handle (mappedPort, exec, logs, …)
  ├── ContainerRequest        — pure configuration struct (image, ports, env, wait strategy)
  ├── wait  (wait.zig)        — Strategy tagged union + constructor helpers
  ├── network (network.zig)   — Network creation / management
  └── modules/                — 10 pre-configured module wrappers
        postgres, mysql, redis, mongodb, rabbitmq,
        mariadb, minio, elasticsearch, kafka, localstack
```

The HTTP transport layer is a built-in HTTP/1.1 client that communicates directly with the Docker Unix socket via `std.net.connectUnixSocket`. There are no external dependencies. For the HTTP wait strategy, `std.http.Client` from the standard library is used.

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  testcontainers library (src/)                                  │
│                                                                 │
│  ┌──────────────┐  calls  ┌──────────────────────────────────┐ │
│  │  modules/    │────────►│  DockerProvider                  │ │
│  │  (postgres,  │         │  .runContainer(ContainerRequest) │ │
│  │   mysql, …)  │         └────────────────┬─────────────────┘ │
│  └──────────────┘                          │ creates            │
│                                            ▼                   │
│  ┌──────────────────────┐  ┌────────────────────────────────┐  │
│  │  wait.Strategy       │  │  DockerContainer               │  │
│  │  (tagged union)      │  │  .mappedPort() .exec()         │  │
│  │  .none               │  │  .logs()  .terminate()         │  │
│  │  .log  .http  .port  │  └──────────────┬─────────────────┘  │
│  │  .health_check .exec │                 │ owned by            │
│  │  .all                │                 ▼                    │
│  └──────────────────────┘  ┌────────────────────────────────┐  │
│                             │  DockerClient                  │  │
│  ┌──────────────────────┐   │  HTTP over unix socket         │  │
│  │  network.zig         │   │  /var/run/docker.sock          │  │
│  │  (Network creation)  │   └──────────────┬─────────────────┘  │
│  └──────────────────────┘                  │ via                │
└────────────────────────────────────────────┼────────────────────┘
                                             ▼
                              ┌──────────────────────────────┐
                              │  Built-in HTTP/1.1 client    │
                              │  (std.net.connectUnixSocket) │
                              └──────────────────────────────┘
                                             │
                                             ▼
                              ┌──────────────────────────────┐
                              │  Docker Engine REST API       │
                              └──────────────────────────────┘
```

## Key Design Patterns

### 1. Tagged Union for Wait Strategies

Rather than a protocol/interface hierarchy, readiness conditions are represented as a single
tagged union. This is zero-overhead (no vtable, no heap allocation) and completely exhaustive
at compile time:

```zig
pub const Strategy = union(enum) {
    none,
    log:          LogStrategy,
    http:         HttpStrategy,
    port:         PortStrategy,
    health_check: HealthCheckStrategy,
    exec:         ExecStrategy,
    all:          AllStrategy,
};
```

The `wait` namespace exposes constructor helpers so callers never construct the union literally:

```zig
tc.wait.forLog("database system is ready")
tc.wait.forPort("5432/tcp")
tc.wait.forAll(&.{ tc.wait.forPort("5432/tcp"), tc.wait.forLog("ready") })
```

### 2. Struct-Literal Configuration

`ContainerRequest` is a plain struct with default values. Callers provide only what they need
via named-field syntax — no builder methods, no chaining:

```zig
const req = tc.ContainerRequest{
    .image        = "postgres:16-alpine",
    .exposed_ports = &.{"5432/tcp"},
    .env          = &.{"POSTGRES_PASSWORD=test"},
    .wait_strategy = tc.wait.forPort("5432/tcp"),
};
```

### 3. Two-Level API

**Level 1 — convenience helpers** in `src/root.zig`:

```zig
// Global singleton provider (one per process)
pub fn run(alloc, image, req) !*DockerContainer
pub fn genericContainer(alloc, req) !*DockerContainer
```

**Level 2 — explicit provider**:

```zig
var provider = try tc.DockerProvider.init(alloc);
defer provider.deinit();
const ctr = try provider.runContainer(alloc, req);
```

The global helpers use an internal process-level `DockerProvider` that is initialised lazily.

### 4. Module Pattern

Each module (`src/modules/<name>.zig`) follows the same convention:

```
const opts = Options{ .username = "u", .password = "p", .database = "d" };
const ctr  = try tc.modules.postgres.run(&provider, image, opts);
// ctr is *PostgresContainer

const url = try ctr.connectionString(alloc);
defer alloc.free(url);
```

Modules are thin wrappers: they build a `ContainerRequest` with sensible defaults (image,
ports, environment variables, wait strategy) and delegate to `DockerProvider.runContainer`.
The returned container wrapper owns a `*DockerContainer` and exposes domain-specific helpers.

### 5. Deterministic Cleanup

Every resource is cleaned up in reverse allocation order using `defer` and `errdefer`:

```zig
const ctr = try provider.runContainer(alloc, req);
defer ctr.terminate() catch {};   // stop + remove the container
defer ctr.deinit();               // free memory
```

There are no finalizers, no reference counting, and no garbage collector.

## Concurrency Model

The library uses a built-in HTTP/1.1 client that communicates directly with the Docker Unix
socket via `std.net.connectUnixSocket`. No external runtime or async framework is needed.

All public API functions block the calling thread until completion. There is no callback or
Future-based API surface.

## Docker Endpoint Detection

1. `TESTCONTAINERS_HOST_OVERRIDE` environment variable (host name override)
2. `DOCKER_HOST` environment variable (full socket path)
3. `/var/run/docker.sock` — standard default

The socket path is resolved once during `DockerProvider.init` or `DockerClient.init`.

## Port Mapping

Docker allocates a random host port when `"<port>/tcp"` is listed in `exposed_ports`. After
the container starts, the library calls `GET /containers/{id}/json` (inspect) and caches the
`HostPort` values. `mappedPort("5432/tcp", alloc)` reads this cache — no extra network call.

## Network Isolation

`network.zig` exposes:

- `Network.create(client, name, alloc)` — creates a named bridge network
- `Network.remove(client, alloc)` — tears it down

Containers join networks via `ContainerRequest.networks` (slice of network names) and get DNS
aliases from `ContainerRequest.network_aliases`.

## Dependencies

| Dependency | Role | Source |
|-----------|------|--------|
| Zig stdlib | JSON, I/O, HTTP, networking, testing | built-in |

No external dependencies. The library communicates with the Docker Engine using a built-in
HTTP/1.1 client over `std.net.connectUnixSocket`.

## References

- [Docker Engine API v1.44](https://docs.docker.com/engine/api/v1.44/)
- [Zig Language Reference](https://ziglang.org/documentation/0.15.2/)
- [testcontainers-go](https://github.com/testcontainers/testcontainers-go) — reference architecture
- [Zig Standard Library](https://ziglang.org/documentation/0.15.2/std/) — HTTP, networking, JSON
