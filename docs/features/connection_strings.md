# Connection strings

Pre-configured modules provide convenience methods that return connection strings or URLs. These methods query the container's mapped port and return a caller-owned string that must be freed with the allocator.

## PostgreSQL

```zig
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
```

## MySQL

```zig
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
```

## MariaDB

```zig
const maria = try tc.modules.mariadb.run(&provider, tc.modules.mariadb.default_image, .{
    .username = "admin",
    .password = "secret",
    .database = "testdb",
});
defer maria.terminate() catch {};
defer maria.deinit();

const conn = try maria.connectionString(allocator);
defer allocator.free(conn);
// "mariadb://admin:secret@localhost:PORT/testdb"
```

## Redis

```zig
const redis = try tc.modules.redis.runDefault(&provider);
defer redis.terminate() catch {};
defer redis.deinit();

const conn = try redis.connectionString(allocator);
defer allocator.free(conn);
// "redis://localhost:PORT"
```

## MongoDB

```zig
const mongo = try tc.modules.mongodb.runDefault(&provider);
defer mongo.terminate() catch {};
defer mongo.deinit();

const conn = try mongo.connectionString(allocator);
defer allocator.free(conn);
// "mongodb://localhost:PORT"
```

## RabbitMQ

```zig
const rmq = try tc.modules.rabbitmq.runDefault(&provider);
defer rmq.terminate() catch {};
defer rmq.deinit();

const amqp = try rmq.amqpURL(allocator);
defer allocator.free(amqp);
// "amqp://guest:guest@localhost:PORT"

const http = try rmq.httpURL(allocator);
defer allocator.free(http);
// "http://localhost:MGMT_PORT"
```

## MinIO

```zig
const minio = try tc.modules.minio.runDefault(&provider);
defer minio.terminate() catch {};
defer minio.deinit();

const conn = try minio.connectionString(allocator);
defer allocator.free(conn);
// "http://localhost:PORT"
```

## Elasticsearch

```zig
const es = try tc.modules.elasticsearch.runDefault(&provider);
defer es.terminate() catch {};
defer es.deinit();

const url = try es.httpURL(allocator);
defer allocator.free(url);
// "http://localhost:PORT"
```

## Kafka

```zig
const kafka = try tc.modules.kafka.runDefault(&provider);
defer kafka.terminate() catch {};
defer kafka.deinit();

const brokers = try kafka.brokers(allocator);
defer allocator.free(brokers);
// "localhost:PORT"
```

## LocalStack

```zig
const ls = try tc.modules.localstack.runDefault(&provider);
defer ls.terminate() catch {};
defer ls.deinit();

const endpoint = try ls.endpointURL(allocator);
defer allocator.free(endpoint);
// "http://localhost:PORT"
```

!!! note

    All connection string methods return caller-owned slices. Always `defer allocator.free(...)` immediately after receiving the result.
