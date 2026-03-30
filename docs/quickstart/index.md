# Quickstart

Testcontainers for Zig integrates with Zig's built-in `test` blocks and `std.testing` framework.

It is designed for integration and end-to-end tests, helping you spin up and manage the lifecycle of container-based dependencies via Docker.

## 1. System requirements

Please read the [System Requirements](../system_requirements/index.md) page before you start.

## 2. Install Testcontainers for Zig

Add testcontainers-zig as a dependency in your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .dependencies = .{
        .testcontainers = .{
            .url = "https://github.com/dragosv/testcontainers-zig/archive/refs/heads/main.tar.gz",
            // Replace with the actual hash after first fetch
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

Then add it to your `build.zig`:

```zig
const tc_dep = b.dependency("testcontainers", .{
    .target = target,
    .optimize = optimize,
});

// Add to your test step
const tests = b.addTest(.{
    .root_source_file = b.path("src/main_test.zig"),
    .target = target,
    .optimize = optimize,
});
tests.root_module.addImport("testcontainers", tc_dep.module("testcontainers"));
```

## 3. Spin up Redis

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "redis container" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const redis = try tc.modules.redis.runDefault(&provider);
    defer redis.terminate() catch {};
    defer redis.deinit();

    const conn = try redis.connectionString(allocator);
    defer allocator.free(conn);

    // conn = "redis://localhost:PORT"
    std.debug.print("Redis available at {s}\n", .{conn});
}
```

The `ContainerRequest` struct configures the container using struct-literal syntax with named fields and sensible defaults.

- `exposed_ports` specifies which ports to publish from the container. Docker maps each to a random available host port.
- `wait_strategy` validates when a container is ready to receive traffic. For Redis, the module uses a log-based wait strategy.

Docker maps each container port to a random available host port. This is crucial for parallelization — if you add multiple tests, each starts its own Redis container on a different random port.

All containers must be removed at some point, otherwise they will run until the host is overloaded. Using `defer` ensures cleanup happens even if the test fails.

!!! tip

    Look at [Garbage Collector](../features/garbage_collector.md) to learn more about resource cleanup patterns.

## 4. Connect your code to the container

In a real project, you would pass this endpoint to your Redis client library. This snippet retrieves the endpoint from the container we just started:

```zig
const conn = try redis.connectionString(allocator);
defer allocator.free(conn);
// Use conn with your Redis client library
// Returns: "redis://localhost:PORT"
```

The connection string includes the randomly mapped host port.

!!! tip

    If you expose more than one port, use `container.mappedPort("PORT/tcp", allocator)` with the specific container port you need.
