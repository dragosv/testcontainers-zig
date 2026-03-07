[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://github.com/codespaces/new?hide_repo_select=true&ref=develop&repo=1163891557&machine=standardLinux32gb&devcontainer_path=.devcontainer%2Fdevcontainer.json&location=EastUs)

[![CI/CD](https://github.com/dragosv/testcontainers-zig/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/dragosv/testcontainers-zig/actions/workflows/ci.yml)
[![Language](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org)
[![Docker](https://img.shields.io/badge/Docker%20Engine%20API-%20%201.44-blue)](https://docs.docker.com/engine/api/v1.44/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=shields)](http://makeapullrequest.com)

# Testcontainers for Zig

A lightweight Zig library for writing tests with throwaway Docker containers, inspired by [testcontainers-go](https://github.com/testcontainers/testcontainers-go).

## Requirements

- Zig 0.15.2+
- Docker or Docker Desktop running

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

Then in `build.zig`:

```zig
const tc_dep = b.dependency("testcontainers", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("testcontainers", tc_dep.module("testcontainers"));
```

## Quick Start

See [QUICKSTART.md](QUICKSTART.md) for a step-by-step guide.

```zig
const std = @import("std");
const tc  = @import("testcontainers");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const ctr = try tc.run(alloc, "nginx:latest", .{
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forHttp("/"),
    });
    defer ctr.terminate() catch {};
    defer ctr.deinit();

    const port = try ctr.mappedPort("80/tcp", alloc);
    std.debug.print("nginx ready on port {d}\n", .{port});
}
```

## Modules

Pre-configured containers for common services:

| Module | Default Image | Key Method |
|--------|--------------|------------|
| `modules.postgres` | `postgres:16-alpine` | `connectionString(alloc)` |
| `modules.mysql` | `mysql:8.0` | `connectionString(alloc)` |
| `modules.redis` | `redis:7-alpine` | `connectionString(alloc)` |
| `modules.mongodb` | `mongo:7` | `connectionString(alloc)` |
| `modules.rabbitmq` | `rabbitmq:3-management-alpine` | `amqpURL(alloc)`, `httpURL(alloc)` |
| `modules.mariadb` | `mariadb:11` | `connectionString(alloc)` |
| `modules.minio` | `minio/minio:latest` | `connectionString(alloc)` |
| `modules.elasticsearch` | `elasticsearch:8.12.0` | `httpURL(alloc)` |
| `modules.kafka` | `bitnami/kafka:3.7` | `brokers(alloc)` |
| `modules.localstack` | `localstack/localstack:3` | `endpointURL(alloc)` |

```zig
var provider = try tc.DockerProvider.init(alloc);
defer provider.deinit();

const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
    .username = "myuser",
    .password = "mypass",
    .database = "mydb",
});
defer pg.terminate() catch {};
defer pg.deinit();

const url = try pg.connectionString(alloc);
defer alloc.free(url);
```

## Wait Strategies

```zig
tc.wait.forHttp("/health")           // HTTP 200 response on the first exposed port
tc.wait.forPort("5432/tcp")          // TCP port open
tc.wait.forLog("database system is ready")  // substring in container stdout/stderr
tc.wait.forHealthCheck()             // Docker HEALTHCHECK status == healthy
tc.wait.forExec(&.{"pg_isready"})    // command exits with code 0
tc.wait.forAll(&.{                   // all sub-strategies must pass
    tc.wait.forPort("5432/tcp"),
    tc.wait.forLog("ready"),
})
```

## Test Integration

```zig
const std = @import("std");
const testing = std.testing;
const tc = @import("testcontainers");

test "postgres connection" {
    const alloc = testing.allocator;

    var provider = try tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{});
    defer pg.terminate() catch {};
    defer pg.deinit();

    const url = try pg.connectionString(alloc);
    defer alloc.free(url);

    try testing.expect(url.len > 0);
}
```

## Documentation

| Document | Description |
|----------|-------------|
| [QUICKSTART.md](QUICKSTART.md) | 5-minute getting-started guide |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design decisions and component overview |
| [PROJECT_SUMMARY.md](PROJECT_SUMMARY.md) | Full feature inventory and implementation stats |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |
| [examples/basic.zig](examples/basic.zig) | Runnable usage example |

## Contributing

Contributions are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

MIT — see [LICENSE](LICENSE).

## Support

[Slack](https://slack.testcontainers.org/) · [Stack Overflow](https://stackoverflow.com/questions/tagged/testcontainers) · [GitHub Issues](https://github.com/dragosv/testcontainers-zig/issues/)

---

Copyright © 2026 Dragos Varovici and contributors.
