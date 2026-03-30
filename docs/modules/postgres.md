# PostgreSQL

The PostgreSQL module provides a pre-configured container for [PostgreSQL](https://www.postgresql.org/).

## Usage

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "postgres" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
        .username = "admin",
        .password = "secret",
        .database = "testdb",
    });
    defer pg.terminate() catch {};
    defer pg.deinit();

    const conn = try pg.connectionString(allocator);
    defer allocator.free(conn);
    // "postgres://admin:secret@localhost:PORT/testdb"

    const port = try pg.port(allocator);
    std.debug.print("PostgreSQL on port {d}\n", .{port});
}
```

## Default image

`postgres:16-alpine`

## Options

| Option     | Type          | Default      | Description             |
|------------|---------------|--------------|-------------------------|
| `username` | `[]const u8`  | `"postgres"` | Database user.          |
| `password` | `[]const u8`  | `"postgres"` | User password.          |
| `database` | `[]const u8`  | `"postgres"` | Database name.          |

## Container methods

| Method               | Returns     | Description                                              |
|----------------------|-------------|----------------------------------------------------------|
| `connectionString()` | `[]const u8`| libpq-compatible URL: `postgres://user:pass@host:port/db`|
| `port()`             | `u16`       | Mapped host port for PostgreSQL (5432/tcp).               |
| `terminate()`        | `!void`     | Stop and remove the container.                           |
| `deinit()`           | `void`      | Free Zig-side memory.                                    |

## Wait strategy

The module uses `wait.forLog("database system is ready to accept connections")`.

## Shorthand

```zig
// Default image + default options
const pg = try tc.modules.postgres.runDefault(&provider);
defer pg.terminate() catch {};
defer pg.deinit();
```
