# Redis

The Redis module provides a pre-configured container for [Redis](https://redis.io/).

## Usage

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "redis" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const redis = try tc.modules.redis.runDefault(&provider);
    defer redis.terminate() catch {};
    defer redis.deinit();

    const conn = try redis.connectionString(allocator);
    defer allocator.free(conn);
    // "redis://localhost:PORT"

    const port = try redis.port(allocator);
    std.debug.print("Redis on port {d}\n", .{port});
}
```

## Default image

`redis:7-alpine`

## Options

| Option       | Type                   | Default  | Description                          |
|--------------|------------------------|----------|--------------------------------------|
| `password`   | `[]const u8`           | `""`     | Redis password (empty = no auth).    |
| `extra_args` | `[]const []const u8`   | `&.{}`   | Additional command-line arguments.   |

## Container methods

| Method               | Returns     | Description                                  |
|----------------------|-------------|----------------------------------------------|
| `connectionString()` | `[]const u8`| URL: `redis://localhost:PORT`                |
| `port()`             | `u16`       | Mapped host port for Redis (6379/tcp).       |
| `terminate()`        | `!void`     | Stop and remove the container.               |
| `deinit()`           | `void`      | Free Zig-side memory.                        |

## Wait strategy

The module uses `wait.forLog("Ready to accept connections")`.

## Shorthand

```zig
const redis = try tc.modules.redis.runDefault(&provider);
defer redis.terminate() catch {};
defer redis.deinit();
```
