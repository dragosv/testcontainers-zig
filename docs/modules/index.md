# Modules

Testcontainers for Zig modules are pre-configured container wrappers that provide sensible defaults, correct wait strategies, and convenience methods for the most popular Docker images.

Each module exposes:

- `default_image` — the recommended image tag
- `Options` — configuration struct with sensible defaults
- `run(provider, image, opts)` — start and return a typed container
- `runDefault(provider)` — shorthand with default image and options

## Available modules

| Module          | Default Image                                                 | Connection Helper       |
|-----------------|---------------------------------------------------------------|-------------------------|
| PostgreSQL      | `postgres:16-alpine`                                          | `connectionString()`    |
| MySQL           | `mysql:8.0`                                                   | `connectionString()`    |
| MariaDB         | `mariadb:11`                                                  | `connectionString()`    |
| Redis           | `redis:7-alpine`                                              | `connectionString()`    |
| MongoDB         | `mongo:7`                                                     | `connectionString()`    |
| RabbitMQ        | `rabbitmq:3-management-alpine`                                | `amqpURL()`, `httpURL()`|
| MinIO           | `minio/minio:RELEASE.2024-01-16T16-07-38Z`                   | `connectionString()`    |
| Elasticsearch   | `docker.elastic.co/elasticsearch/elasticsearch:8.12.0`        | `httpURL()`             |
| Kafka           | `bitnami/kafka:3.7`                                           | `brokers()`             |
| LocalStack      | `localstack/localstack:3`                                     | `endpointURL()`         |

## Usage pattern

All modules follow the same pattern:

```zig
const std = @import("std");
const tc = @import("testcontainers");

test "module usage" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    // Using runDefault (default image + default options)
    const pg = try tc.modules.postgres.runDefault(&provider);
    defer pg.terminate() catch {};
    defer pg.deinit();

    const conn = try pg.connectionString(allocator);
    defer allocator.free(conn);
}
```

### With custom options

```zig
const pg = try tc.modules.postgres.run(&provider, tc.modules.postgres.default_image, .{
    .username = "admin",
    .password = "secret",
    .database = "mydb",
});
defer pg.terminate() catch {};
defer pg.deinit();
```

### With a custom image

```zig
const pg = try tc.modules.postgres.run(&provider, "postgres:15-alpine", .{});
defer pg.terminate() catch {};
defer pg.deinit();
```

## Creating a new module

See [AGENTS.md](https://github.com/dragosv/testcontainers-zig/blob/main/AGENTS.md) for the step-by-step guide on adding a new module. Each module should:

1. Create `src/modules/<name>.zig` following the existing pattern.
2. Export it in `src/root.zig`.
3. Pre-configure: `default_image`, `Options` struct with defaults, and a wait strategy.
4. Expose a connection helper returning a caller-owned `[]u8`.
5. Add tests and documentation.
