# Examples

This page demonstrates common usage patterns for Testcontainers for Zig, from basic container management through to multi-container setups.

## Basic HTTP container

Start an NGINX container, wait for it to be ready, and make an HTTP request:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "nginx container" {
    const allocator = std.testing.allocator;

    const ctr = try tc.run(allocator, "nginx:1.26-alpine", .{
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forHttp("/"),
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
        tc.deinitProvider();
    }

    const port = try ctr.mappedPort("80/tcp", allocator);
    const host = try ctr.daemonHost(allocator);
    defer allocator.free(host);

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/", .{ host, port });
    defer allocator.free(url);

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    const fetch_result = try http_client.fetch(.{
        .location = .{ .url = url },
    });
    std.debug.print("Status: {d}\n", .{@intFromEnum(fetch_result.status)});
}
```

## Database module

Use the pre-configured [PostgreSQL module](../modules/postgres.md) for zero-config database testing:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "postgres module" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
        .database = "myapp_test",
        .username = "admin",
        .password = "secret",
    });
    defer pg.terminate() catch {};
    defer pg.deinit();

    const conn = try pg.connectionString(allocator);
    defer allocator.free(conn);
    // "postgres://admin:secret@localhost:PORT/myapp_test"
}
```

## Combined wait strategies

Wait for multiple conditions before considering a container ready:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "combined wait strategies" {
    const allocator = std.testing.allocator;

    const strategies = [_]tc.wait.Strategy{
        tc.wait.forPort("5432/tcp"),
        tc.wait.forLog("database system is ready to accept connections"),
    };

    const ctr = try tc.run(allocator, "postgres:16", .{
        .env = &.{"POSTGRES_PASSWORD=password"},
        .exposed_ports = &.{"5432/tcp"},
        .wait_strategy = tc.wait.forAll(&strategies),
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
        tc.deinitProvider();
    }

    // Container is guaranteed to have port 5432 listening
    // AND the log message present
}
```

## Multi-container network

Connect multiple containers through a custom Docker network:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "multi-container network" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    // Create a shared network
    const net = try tc.network.newNetwork(allocator, &provider.client, .{
        .name = "app-network",
    });
    defer {
        net.remove() catch {};
        net.deinit();
    }

    // Start PostgreSQL
    const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
        .database = "mydb",
        .username = "admin",
        .password = "secret",
    });
    defer pg.terminate() catch {};
    defer pg.deinit();

    // Start Redis
    const redis = try tc.modules.redis.runDefault(&provider);
    defer redis.terminate() catch {};
    defer redis.deinit();

    const pg_conn = try pg.connectionString(allocator);
    defer allocator.free(pg_conn);
    const redis_conn = try redis.connectionString(allocator);
    defer allocator.free(redis_conn);

    std.debug.print("PostgreSQL: {s}\n", .{pg_conn});
    std.debug.print("Redis: {s}\n", .{redis_conn});
}
```

## Executing commands in a container

Run commands inside a running container:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "exec in container" {
    const allocator = std.testing.allocator;

    const ctr = try tc.run(allocator, "alpine:latest", .{
        .cmd = &.{ "sleep", "30" },
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
        tc.deinitProvider();
    }

    const result = try ctr.exec(&.{ "echo", "Hello from Alpine" });
    defer allocator.free(result.output);
    std.debug.print("{s}\n", .{std.mem.trim(u8, result.output, "\n\r ")});
}
```

## Reading container logs

Access stdout/stderr from a running container:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "container logs" {
    const allocator = std.testing.allocator;

    const ctr = try tc.run(allocator, "alpine:latest", .{
        .cmd = &.{ "sh", "-c", "echo 'Application started' && sleep 30" },
        .wait_strategy = tc.wait.forLog("Application started"),
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
        tc.deinitProvider();
    }

    const logs = try ctr.logs(allocator);
    defer allocator.free(logs);
    std.debug.print("{s}\n", .{logs});
}
```

## Zig test integration

Testcontainers integrates naturally with Zig's built-in test framework. Use `test` blocks and `defer` for automatic cleanup:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "database reachable" {
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

    // Verify the connection string contains our database name
    try std.testing.expect(std.mem.indexOf(u8, conn, "testdb") != null);
}

test "redis reachable" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const redis = try tc.modules.redis.runDefault(&provider);
    defer redis.terminate() catch {};
    defer redis.deinit();

    const port = try redis.port(allocator);
    try std.testing.expect(port > 0);
}
```
