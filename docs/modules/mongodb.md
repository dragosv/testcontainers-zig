# MongoDB

The MongoDB module provides a pre-configured container for [MongoDB](https://www.mongodb.com/).

## Usage

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "mongodb" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const mongo = try tc.modules.mongodb.runDefault(&provider);
    defer mongo.terminate() catch {};
    defer mongo.deinit();

    const conn = try mongo.connectionString(allocator);
    defer allocator.free(conn);
    // "mongodb://localhost:PORT"
}
```

## Default image

`mongo:7`

## Options

| Option     | Type          | Default  | Description                              |
|------------|---------------|----------|------------------------------------------|
| `username` | `[]const u8`  | `""`     | Admin username (empty = no auth).        |
| `password` | `[]const u8`  | `""`     | Admin password (empty = no auth).        |

## Container methods

| Method               | Returns     | Description                                  |
|----------------------|-------------|----------------------------------------------|
| `connectionString()` | `[]const u8`| URL: `mongodb://localhost:PORT`              |
| `port()`             | `u16`       | Mapped host port for MongoDB (27017/tcp).    |
| `terminate()`        | `!void`     | Stop and remove the container.               |
| `deinit()`           | `void`      | Free Zig-side memory.                        |

## Wait strategy

The module uses `wait.forLog("Waiting for connections")`.

## Shorthand

```zig
const mongo = try tc.modules.mongodb.runDefault(&provider);
defer mongo.terminate() catch {};
defer mongo.deinit();
```
