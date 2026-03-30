# Zig Test Integration

Testcontainers for Zig integrates with Zig's built-in test framework. Tests are written as `test` blocks using `std.testing` assertions.

## Basic test pattern

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "container in test" {
    const allocator = std.testing.allocator;

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
    try std.testing.expect(port > 0);
}
```

## Using modules in tests

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "postgres in test" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
        .database = "testdb",
        .username = "admin",
        .password = "secret",
    });
    defer pg.terminate() catch {};
    defer pg.deinit();

    const conn = try pg.connectionString(allocator);
    defer allocator.free(conn);

    try std.testing.expect(std.mem.indexOf(u8, conn, "testdb") != null);
}
```

## Skipping tests when Docker is unavailable

Integration tests that require Docker should check for availability and skip gracefully:

```zig
test "requires docker" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    // Try to connect to Docker — skip if unavailable
    _ = provider.client.imageExists("alpine:latest") catch {
        return error.SkipZigTest;
    };

    // ... rest of test
}
```

## Multiple containers in one test

```zig
test "multi-container test" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const pg = try tc.modules.postgres.runDefault(&provider);
    defer pg.terminate() catch {};
    defer pg.deinit();

    const redis = try tc.modules.redis.runDefault(&provider);
    defer redis.terminate() catch {};
    defer redis.deinit();

    const pg_conn = try pg.connectionString(allocator);
    defer allocator.free(pg_conn);

    const redis_conn = try redis.connectionString(allocator);
    defer allocator.free(redis_conn);

    try std.testing.expect(std.mem.indexOf(u8, pg_conn, "postgres") != null);
    try std.testing.expect(std.mem.indexOf(u8, redis_conn, "redis") != null);
}
```

## Running tests

```bash
# Run unit tests only (no Docker required)
zig build test --summary all

# Run integration tests (requires Docker)
zig build integration-test --summary all
```

## Best practices

- Create a fresh `DockerProvider` per test function — do not share providers across tests.
- Always use `defer` for cleanup: `defer ctr.terminate() catch {};` and `defer ctr.deinit();`.
- Use `std.testing.allocator` which detects memory leaks.
- Use `error.SkipZigTest` when Docker is not available to allow graceful test skipping.
- Pin image versions (e.g. `postgres:16-alpine`) to ensure reproducible tests.
