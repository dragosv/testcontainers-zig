# Best practices

This page provides guidelines for writing reliable, maintainable tests with Testcontainers for Zig.

## Use random host ports

Avoid binding fixed host ports. Testcontainers maps container ports to random available host ports by default, preventing port conflicts — especially in CI environments where tests may run in parallel.

```zig
// ✅ Good — random host port (default behaviour)
const ctr = try tc.run(allocator, "postgres:16", .{
    .exposed_ports = &.{"5432/tcp"},
    .env = &.{"POSTGRES_PASSWORD=password"},
    .wait_strategy = tc.wait.forLog("database system is ready to accept connections"),
});

const port = try ctr.mappedPort("5432/tcp", allocator);
```

## Pin image versions

Always use a specific image tag. Never rely on `latest`, which can change unexpectedly and break your tests.

```zig
// ✅ Good
const ctr = try tc.run(allocator, "postgres:16.4", .{ ... });

// ❌ Avoid
const ctr = try tc.run(allocator, "postgres:latest", .{ ... });
```

## Use wait strategies

Configure a wait strategy so your test only proceeds after the service is fully ready. Without one, tests may fail intermittently due to race conditions.

```zig
const strategies = [_]tc.wait.Strategy{
    tc.wait.forPort("5432/tcp"),
    tc.wait.forLog("database system is ready to accept connections"),
};

const ctr = try tc.run(allocator, "postgres:16", .{
    .env = &.{"POSTGRES_PASSWORD=password"},
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = tc.wait.forAll(&strategies),
});
```

See [Wait Strategies](wait/introduction.md) for all available strategies.

## Use pre-configured modules

When a pre-configured module exists, prefer it over raw `ContainerRequest`. Modules provide sensible defaults, correct wait strategies, and convenience methods like `connectionString()`.

```zig
// ✅ Good — uses the pre-configured module
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
```

See [Modules](../modules/index.md) for all available modules.

## Clean up containers

Always clean up containers when tests complete. Use `defer` for deterministic cleanup:

```zig
test "something" {
    const allocator = std.testing.allocator;

    const ctr = try tc.run(allocator, "postgres:16", .{
        .env = &.{"POSTGRES_PASSWORD=password"},
        .exposed_ports = &.{"5432/tcp"},
        .wait_strategy = tc.wait.forLog("database system is ready to accept connections"),
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
        tc.deinitProvider();
    }

    // test logic...
}
```

See [Garbage Collector](garbage_collector.md) for detailed cleanup patterns.

## Use `defer` for deterministic cleanup

Zig's `defer` guarantees cleanup runs when the scope exits, whether the test passes or fails. Always pair `terminate()` and `deinit()` with `defer`:

```zig
// ✅ Good — deterministic cleanup with defer
const ctr = try tc.run(allocator, "nginx:latest", .{
    .exposed_ports = &.{"80/tcp"},
    .wait_strategy = tc.wait.forHttp("/"),
});
defer {
    ctr.terminate() catch {};
    ctr.deinit();
    tc.deinitProvider();
}
```

## Use network aliases for inter-container communication

When containers need to communicate, use custom networks with aliases instead of `localhost`:

```zig
const ctr = try tc.run(allocator, "postgres:16", .{
    .exposed_ports = &.{"5432/tcp"},
    .env = &.{"POSTGRES_PASSWORD=password"},
    .networks = &.{"test-net"},
    .network_aliases = &.{.{ .network = "test-net", .aliases = &.{"db"} }},
    .wait_strategy = tc.wait.forLog("database system is ready to accept connections"),
});
```

See [Networking](networking.md) for detailed networking patterns.

## Use `std.log` for debugging

Use Zig's `std.log` to diagnose container issues:

```zig
const std = @import("std");
std.log.info("Container started on port {d}", .{port});
```
