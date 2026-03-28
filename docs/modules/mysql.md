# MySQL

The MySQL module provides a pre-configured container for [MySQL](https://www.mysql.com/).

## Usage

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "mysql" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const mysql = try tc.modules.mysql.run(&provider, tc.modules.mysql.default_image, .{
        .username = "admin",
        .password = "secret",
        .database = "testdb",
    });
    defer mysql.terminate() catch {};
    defer mysql.deinit();

    const conn = try mysql.connectionString(allocator);
    defer allocator.free(conn);
    // "mysql://admin:secret@localhost:PORT/testdb"
}
```

## Default image

`mysql:8.0`

## Options

| Option          | Type          | Default    | Description             |
|-----------------|---------------|------------|-------------------------|
| `username`      | `[]const u8`  | `"test"`   | Database user.          |
| `password`      | `[]const u8`  | `"test"`   | User password.          |
| `root_password` | `[]const u8`  | `"root"`   | Root password.          |
| `database`      | `[]const u8`  | `"test"`   | Database name.          |

## Container methods

| Method               | Returns     | Description                                         |
|----------------------|-------------|-----------------------------------------------------|
| `connectionString()` | `[]const u8`| URL: `mysql://user:pass@host:port/db`               |
| `port()`             | `u16`       | Mapped host port for MySQL (3306/tcp).              |
| `terminate()`        | `!void`     | Stop and remove the container.                      |
| `deinit()`           | `void`      | Free Zig-side memory.                               |

## Wait strategy

The module uses `wait.forLog("port: 3306  MySQL Community Server")`.

## Shorthand

```zig
const mysql = try tc.modules.mysql.runDefault(&provider);
defer mysql.terminate() catch {};
defer mysql.deinit();
```
