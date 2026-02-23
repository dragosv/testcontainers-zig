# Implementation Guide — Testcontainers Zig

## Overview

A complete implementation of Testcontainers for Zig. It provides Docker container
management for integration testing, following the architecture and patterns of
testcontainers-go.

## What Is Implemented

A fully functional Zig library with:

### Core Components

1. **Docker Client** (`src/docker_client.zig`) — Unix-socket HTTP communication with the Docker Engine
2. **Container Handle** (`src/docker_container.zig`) — Container lifecycle, port mapping, exec, logs
3. **Container Configuration** (`src/container.zig`) — `ContainerRequest` and related types
4. **Wait Strategies** (`src/wait.zig`) — 7 built-in readiness checks
5. **Network Management** (`src/network.zig`) — Bridge network creation
6. **Public API** (`src/root.zig`) — `DockerProvider`, `run()`, `genericContainer()`, `modules` namespace
7. **10 Pre-configured Modules** (`src/modules/`) — Postgres, MySQL, Redis, MongoDB, RabbitMQ, MariaDB, MinIO, Elasticsearch, Kafka, LocalStack

### Documentation

- `README.md` — Features, installation, usage guide
- `QUICKSTART.md` — 5-minute getting-started guide
- `ARCHITECTURE.md` — System design and patterns
- `CONTRIBUTING.md` — How to contribute
- `PROJECT_SUMMARY.md` — Implementation overview
- `IMPLEMENTATION_GUIDE.md` — This document

### Quality

- `examples/basic.zig` — Runnable end-to-end example
- `src/integration_test.zig` — 24 integration tests
- `.github/workflows/ci.yml` — CI/CD pipeline

## Directory Structure

```
testcontainers-zig/
├── build.zig                     # Build system configuration
├── build.zig.zon                 # Package manifest & dependencies
│
├── src/
│   ├── root.zig                  # Public API (DockerProvider, run, modules)
│   ├── docker_client.zig         # DockerClient — HTTP over unix socket
│   ├── docker_container.zig      # DockerContainer — running container handle
│   ├── container.zig             # ContainerRequest, KV, Mount, ContainerFile
│   ├── wait.zig                  # Strategy tagged union + forXxx helpers
│   ├── network.zig               # Network creation / removal
│   ├── types.zig                 # Docker API JSON types
│   ├── integration_test.zig      # 24 Docker integration tests
│   └── modules/
│       ├── postgres.zig
│       ├── mysql.zig
│       ├── redis.zig
│       ├── mongodb.zig
│       ├── rabbitmq.zig
│       ├── mariadb.zig
│       ├── minio.zig
│       ├── elasticsearch.zig
│       ├── kafka.zig
│       └── localstack.zig
│
├── examples/
│   └── basic.zig                 # Nginx example with HTTP wait + exec
│
├── .github/
│   ├── ISSUE_TEMPLATE/
│   ├── pull_request_template.md
│   ├── dependabot.yml
│   └── workflows/
│       └── ci.yml
│
├── README.md
├── QUICKSTART.md
├── ARCHITECTURE.md
├── PROJECT_SUMMARY.md
├── CONTRIBUTING.md
├── LICENSE
└── .gitignore
```

## Key Features

### Container Lifecycle
- Create containers from any Docker image
- Start, stop, terminate (force remove) containers
- Port mapping — Docker allocates a free host port per `exposed_ports` entry
- Container state inspection via `/containers/{id}/json`
- `exec` commands inside a running container
- Fetch container logs (stdout + stderr)
- Copy files or in-memory content into a container (`copyToContainer`)

### Wait Strategies

| Name | Constructor | Trigger |
|------|-------------|---------|
| None | `.none` | Immediate |
| Log | `forLog("text")` | Substring in container stdout/stderr |
| HTTP | `forHttp("/path")` | HTTP 2xx on the first exposed port |
| Port | `forPort("5432/tcp")` | TCP connection succeeds |
| Health check | `forHealthCheck()` | Docker HEALTHCHECK == healthy |
| Exec | `forExec(&cmd)` | Command exit code 0 |
| All | `forAll(&strats)` | All sub-strategies pass |

### Networking
- Create named bridge networks
- Attach containers via `ContainerRequest.networks`
- DNS aliases via `ContainerRequest.network_aliases`
- Inter-container communication using aliased hostnames

### Pre-configured Modules

All 10 modules follow the same pattern:

```zig
// Configuration
pub const default_image: []const u8;
pub const Options = struct { /* fields with defaults */ };

// Lifecycle
pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*XxxContainer
pub fn runDefault(provider: *tc.DockerProvider) !*XxxContainer
pub fn terminate(self: *XxxContainer) !void
pub fn deinit(self: *XxxContainer) void

// Connection helpers (caller owns returned slice)
pub fn connectionString(self, alloc) ![]u8   // or httpURL / brokers / endpointURL
pub fn port(self, alloc) !u16
```

## Source File Descriptions

### `src/root.zig`

Public API entry point. Exports:

- `DockerProvider` — owns a `DockerClient`; drives `runContainer` / `createContainer`
- `run(alloc, image, req)` — global-provider shortcut
- `genericContainer(alloc, req)` — named-container shortcut
- All public types: `ContainerRequest`, `GenericContainerRequest`, `ContainerFile`, `Mount`, `KV`, `NetworkAlias`, `DockerContainer`, `DockerClient`, `docker_socket`
- `modules` namespace re-exporting all 10 module files
- `wait` and `network` namespaces

### `src/docker_client.zig`

`DockerClient` communicates with the Docker Engine via a Unix socket using a built-in
HTTP/1.1 client (`std.net.connectUnixSocket`). Endpoints used:

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/containers/create` | Create container |
| POST | `/containers/{id}/start` | Start |
| POST | `/containers/{id}/stop` | Stop |
| DELETE | `/containers/{id}` | Remove |
| GET | `/containers/{id}/json` | Inspect |
| POST | `/containers/{id}/exec` | Create exec instance |
| POST | `/exec/{id}/start` | Run exec |
| GET | `/containers/{id}/logs` | Fetch logs |
| POST | `/images/create` | Pull image |
| POST | `/networks/create` | Create network |
| POST | `/networks/{id}/connect` | Connect container |
| DELETE | `/networks/{id}` | Remove network |

### `src/docker_container.zig`

`DockerContainer` wraps a container ID and a reference to `DockerClient`. All methods
take an `alloc` parameter for returned slices.

Key methods:

```zig
pub fn mappedPort(self, port_spec: []const u8, alloc) !u16
pub fn daemonHost(self, alloc) ![]const u8
pub fn containerIP(self, alloc) ![]const u8
pub fn inspect(self) !std.json.Parsed(types.ContainerInspect)
pub fn logs(self, alloc) ![]const u8
pub fn exec(self, cmd: []const []const u8, alloc) !ExecResult
pub fn copyToContainer(self, content: []const u8, dest_path: []const u8, mode: u32) !void
pub fn networks(self, alloc) ![][]const u8
pub fn networkAliases(self, network: []const u8, alloc) ![][]const u8
pub fn networkIP(self, network: []const u8, alloc) ![]const u8
pub fn start(self) !void
pub fn stop(self, timeout_s: u32) !void
pub fn terminate(self) !void
pub fn deinit(self) void
```

### `src/container.zig`

Plain data types — no methods, no allocations:

```zig
pub const ContainerRequest = struct {
    image:               []const u8 = "",
    cmd:                 []const []const u8 = &.{},
    entrypoint:          []const []const u8 = &.{},
    env:                 []const []const u8 = &.{},   // "KEY=VALUE"
    exposed_ports:       []const []const u8 = &.{},
    labels:              []const KV = &.{},
    name:                ?[]const u8 = null,
    wait_strategy:       wait.Strategy = .none,
    networks:            []const []const u8 = &.{},
    network_aliases:     []const NetworkAlias = &.{},
    mounts:              []const Mount = &.{},
    files:               []const ContainerFile = &.{},
    always_pull_image:   bool = false,
    image_platform:      []const u8 = "",
    startup_timeout_ns:  u64 = 0,
};
```

### `src/wait.zig`

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

// Constructor helpers
pub fn forLog(message: []const u8) Strategy
pub fn forHttp(path: []const u8) Strategy
pub fn forPort(port_spec: []const u8) Strategy
pub fn forHealthCheck() Strategy
pub fn forExec(cmd: []const []const u8) Strategy
pub fn forAll(strategies: []const Strategy) Strategy
```

### `src/types.zig`

Docker API JSON types parsed with `std.json`:
`ContainerInspect`, `ContainerInspectNetworks`, `NetworkSettings`, `PortBinding`,
`HealthState`, `ExecCreate`, `ExecStart`, `ExecInspect`, `ImageCreate`, `NetworkCreate`,
`NetworkConnect`, `CreateContainer`, `CreateContainerResponse`.

### `src/network.zig`

```zig
pub const Network = struct {
    id:   []const u8,
    name: []const u8,

    pub fn create(client: *DockerClient, name: []const u8, alloc) !Network
    pub fn remove(self: *Network, client: *DockerClient, alloc) !void
};
```

### `src/integration_test.zig`

24 tests exercising the full stack end-to-end. Each test:
1. Attempts to connect to Docker; returns `error.SkipZigTest` if unavailable.
2. Starts a real container.
3. Asserts postconditions (mapped port > 0, connection string non-empty, etc.).
4. Cleans up via `defer`.

### `examples/basic.zig`

Full nginx example:
1. `tc.run(alloc, "nginx:latest", .{ .wait_strategy = tc.wait.forHttp("/") })`
2. `ctr.mappedPort("80/tcp", alloc)`
3. Fetch `/` using `std.http.Client`
4. `ctr.exec(&.{"echo", "hello"})`
5. Print output

## Adding a New Module

1. Create `src/modules/<name>.zig` following the conventions in `src/modules/postgres.zig`.
2. Add `pub const <name> = @import("modules/<name>.zig");` inside `pub const modules` in `src/root.zig`.
3. Add a test block in the new file.
4. Add an integration test in `src/integration_test.zig`.
5. Update `PROJECT_SUMMARY.md`, `README.md` module table, and this guide.

## Adding a New Wait Strategy

1. Add a new field and payload struct to the `Strategy` union in `src/wait.zig`.
2. Add a `pub fn forXxx(...)` constructor in the `wait` namespace.
3. Handle the new tag in the strategy dispatch `switch` in `docker_container.zig`.
4. Add a test in `src/integration_test.zig`.

## Building and Testing

```bash
zig build                           # compile all targets
zig build test --summary all        # unit tests (no Docker required)
zig build integration-test --summary all  # Docker integration tests
zig build example                   # run examples/basic.zig
```

## Dependencies

| Package | Version | Role |
|---------|---------|------|
| Zig stdlib | built-in | JSON, I/O, HTTP, networking, testing |

No external dependencies. The library uses a built-in HTTP/1.1 client over Unix domain socket.

## Project Statistics

| Metric | Value |
|--------|-------|
| Source files | 8 core + 10 modules + 1 example |
| Modules | 10 |
| Wait strategies | 7 |
| Integration tests | 24 |
| External dependencies | 0 |
| Zig version | 0.15.2 |

## Getting Help

- Open an issue on [GitHub](https://github.com/dragosv/testcontainers-zig/issues)
- Ask on Stack Overflow with the `testcontainers` tag
- Join the [Testcontainers Slack](https://slack.testcontainers.org/)

