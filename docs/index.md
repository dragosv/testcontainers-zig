# Testcontainers for Zig

Testcontainers for Zig is a Zig library that makes it simple to create and clean up container-based dependencies for automated integration and end-to-end tests. The library uses Zig's built-in `test` blocks and integrates with `std.testing`.

Typical use cases include spinning up throwaway instances of databases, message brokers, or any Docker image as part of your test suite — containers start in seconds and are cleaned up automatically when the test finishes.

```zig title="Quickstart example"
const std = @import("std");
const tc  = @import("testcontainers");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctr = try tc.run(allocator, "nginx:latest", .{
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forHttp("/"),
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
        tc.deinitProvider();
    }

    const port = try ctr.mappedPort("80/tcp", allocator);
    std.debug.print("nginx at localhost:{d}\n", .{port});
}
```

<p style="text-align:center">
  <strong>Not using Zig? Here are other supported languages!</strong>
</p>
<div class="card-grid">
  <a class="card-grid-item" href="https://java.testcontainers.org">
    <img src="language-logos/java.svg" />Java
  </a>
  <a class="card-grid-item" href="https://golang.testcontainers.org">
    <img src="language-logos/go.svg" />Go
  </a>
  <a class="card-grid-item" href="https://dotnet.testcontainers.org">
    <img src="language-logos/dotnet.svg" />.NET
  </a>
  <a class="card-grid-item" href="https://node.testcontainers.org">
    <img src="language-logos/nodejs.svg" />Node.js
  </a>
  <a class="card-grid-item" href="https://testcontainers-python.readthedocs.io/en/latest/">
    <img src="language-logos/python.svg" />Python
  </a>
  <a class="card-grid-item" href="https://docs.rs/testcontainers/latest/testcontainers/">
    <img src="language-logos/rust.svg" />Rust
  </a>
  <a class="card-grid-item" href="https://github.com/testcontainers/testcontainers-hs/">
    <img src="language-logos/haskell.svg"/>Haskell
  </a>
  <a href="https://github.com/testcontainers/testcontainers-ruby/" class="card-grid-item"><img src="language-logos/ruby.svg"/>Ruby</a>
</div>

## About

Testcontainers for Zig is a library to support tests with throwaway instances of Docker containers. Built with Zig 0.15.2, it communicates with Docker via the Docker Remote API over Unix domain sockets using a built-in HTTP/1.1 client — no external dependencies required.

Choose from existing pre-configured [modules](modules/index.md) — PostgreSQL, MySQL, Redis, MongoDB, RabbitMQ, MariaDB, MinIO, Elasticsearch, Kafka, and LocalStack — and start containers within seconds. Or use the generic `ContainerRequest` struct to run any Docker image with full control over configuration.

Read the [Quickstart](quickstart/index.md) to get up and running in minutes.

## System requirements

Please read the [System Requirements](system_requirements/index.md) page before you start.

| Requirement     | Minimum version      |
|-----------------|----------------------|
| Zig             | 0.15.2               |
| macOS           | 13.0 (Ventura)       |
| Linux           | Ubuntu 22.04+        |
| Docker          | 20.10+               |

Testcontainers automatically detects the Docker socket. It checks the `DOCKER_HOST` environment variable first, then falls back to `/var/run/docker.sock`.

## License

See [LICENSE](https://github.com/dragosv/testcontainers-zig/blob/main/LICENSE).

## Copyright

Copyright (c) 2024 - 2026 The Testcontainers for Zig Authors.

----

Join our [Slack workspace](https://slack.testcontainers.org/) | [Testcontainers OSS](https://www.testcontainers.org/) | [Testcontainers Cloud](https://testcontainers.com/cloud/)
[testcontainers-cloud]: https://www.testcontainers.cloud/
