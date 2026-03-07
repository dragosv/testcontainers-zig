# Quick Start Guide

Get started with Testcontainers for Zig in 5 minutes.

## Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) installed
- Docker or Docker Desktop installed and running

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .testcontainers = .{
        .url = "git+https://github.com/dragosv/testcontainers-zig?ref=main#<commit>",
        .hash = "<hash>",
    },
},
```

Wire it up in `build.zig`:

```zig
const tc_dep = b.dependency("testcontainers", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("testcontainers", tc_dep.module("testcontainers"));
```

## Basic Example

```zig
const std = @import("std");
const tc  = @import("testcontainers");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Start a PostgreSQL container using the built-in module.
    var provider = try tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
        .username = "user",
        .password = "password",
        .database = "mydb",
    });
    defer pg.terminate() catch {};
    defer pg.deinit();

    const url = try pg.connectionString(alloc);
    defer alloc.free(url);

    std.debug.print("Connected to: {s}\n", .{url});
}
```

## Starting a Generic Container

```zig
const ctr = try tc.run(alloc, "nginx:latest", .{
    .exposed_ports  = &.{"80/tcp"},
    .wait_strategy  = tc.wait.forHttp("/"),
});
defer ctr.terminate() catch {};
defer ctr.deinit();

const port = try ctr.mappedPort("80/tcp", alloc);
std.debug.print("nginx running on port {d}\n", .{port});
```

## Using in Zig Tests

```zig
const std     = @import("std");
const testing = std.testing;
const tc      = @import("testcontainers");

test "postgres: connection string is non-empty" {
    const alloc = testing.allocator;

    var provider = tc.DockerProvider.init(alloc) catch return error.SkipZigTest;
    defer provider.deinit();

    const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{});
    defer pg.terminate() catch {};
    defer pg.deinit();

    const url = try pg.connectionString(alloc);
    defer alloc.free(url);

    try testing.expect(url.len > 0);
}
```

## Available Modules

### PostgreSQL

```zig
const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
    .username = "user",
    .password = "pass",
    .database = "testdb",
});
const url = try pg.connectionString(alloc);
// postgres://user:pass@localhost:PORT/testdb
```

### MySQL

```zig
const db = try tc.modules.mysql.run(&provider, tc.modules.mysql.default_image, .{
    .username = "user",
    .password = "pass",
    .database = "testdb",
});
const url = try db.connectionString(alloc);
// user:pass@tcp(localhost:PORT)/testdb
```

### Redis

```zig
const redis = try tc.modules.redis.run(&provider, tc.modules.redis.default_image, .{});
const url = try redis.connectionString(alloc);
// redis://localhost:PORT
```

### MongoDB

```zig
const mongo = try tc.modules.mongodb.run(&provider, tc.modules.mongodb.default_image, .{});
const url = try mongo.connectionString(alloc);
// mongodb://localhost:PORT/
```

### RabbitMQ

```zig
const mq = try tc.modules.rabbitmq.run(&provider, tc.modules.rabbitmq.default_image, .{});
const amqp = try mq.amqpURL(alloc);   // amqp://guest:guest@localhost:PORT
const http = try mq.httpURL(alloc);   // http://localhost:MGMT_PORT
```

### MinIO

```zig
const minio = try tc.modules.minio.run(&provider, tc.modules.minio.default_image, .{});
const url = try minio.connectionString(alloc);  // http://localhost:PORT
```

### Elasticsearch

```zig
const es = try tc.modules.elasticsearch.run(&provider, tc.modules.elasticsearch.default_image, .{});
const url = try es.httpURL(alloc);  // http://localhost:PORT
```

### Kafka

```zig
const kafka = try tc.modules.kafka.run(&provider, tc.modules.kafka.default_image, .{});
const brokers = try kafka.brokers(alloc);  // localhost:PORT
```

### LocalStack

```zig
const ls = try tc.modules.localstack.run(&provider, tc.modules.localstack.default_image, .{});
const endpoint = try ls.endpointURL(alloc);  // http://localhost:PORT
```

## Common Patterns

### Using `defer` for automatic cleanup

```zig
const ctr = try provider.runContainer(alloc, req);
defer ctr.terminate() catch |err| std.log.err("terminate: {}", .{err});
defer ctr.deinit();
// ctr is automatically stopped and removed when the scope exits
```

### Custom wait strategies

```zig
const ctr = try tc.run(alloc, "postgres:15", .{
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = tc.wait.forAll(&.{
        tc.wait.forPort("5432/tcp"),
        tc.wait.forLog("database system is ready"),
    }),
});
```

### Environment variables

```zig
const ctr = try tc.run(alloc, "postgres:15", .{
    .exposed_ports = &.{"5432/tcp"},
    .env = &.{
        "POSTGRES_DB=testdb",
        "POSTGRES_USER=testuser",
        "POSTGRES_PASSWORD=testpass",
    },
    .wait_strategy = tc.wait.forPort("5432/tcp"),
});
```

### Network communication between containers

```zig
const net = try tc.network.Network.create(&client, "app-network", alloc);
defer net.remove(&client, alloc) catch {};

const db = try tc.run(alloc, "postgres:15", .{
    .networks        = &.{"app-network"},
    .network_aliases = &.{.{ .network = "app-network", .alias = "database" }},
    .wait_strategy   = tc.wait.forPort("5432/tcp"),
});
defer db.terminate() catch {};
defer db.deinit();

// Other containers on "app-network" can reach Postgres at hostname "database".
```

## Troubleshooting

### Docker not reachable

**Symptom**: Connection refused or `error.FileNotFound` on socket path.

**Solution**: Ensure Docker is running:
```bash
docker ps
```
Override the socket path via environment variable if needed:
```bash
export DOCKER_HOST=/path/to/docker.sock
```

### Container logs

Fetch stdout/stderr to diagnose startup failures:
```zig
const logs = try ctr.logs(alloc);
defer alloc.free(logs);
std.debug.print("{s}\n", .{logs});
```

### Wait strategy timeout

Increase the timeout on the container request:
```zig
const ctr = try tc.run(alloc, "myimage:latest", .{
    .wait_strategy       = tc.wait.forPort("8080/tcp"),
    .startup_timeout_ns  = 120 * std.time.ns_per_s,
});
```

## Next Steps

- Read [ARCHITECTURE.md](ARCHITECTURE.md) for design details
- See [examples/basic.zig](examples/basic.zig) for a runnable example
- Read [CONTRIBUTING.md](CONTRIBUTING.md) to contribute

## Getting Help

- Open an issue on [GitHub](https://github.com/dragosv/testcontainers-zig/issues)
- Ask on Stack Overflow with the `testcontainers` tag
- Join the [Testcontainers Slack](https://slack.testcontainers.org/)
