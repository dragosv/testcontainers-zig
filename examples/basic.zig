/// Basic testcontainers-zig example.
///
/// Starts an nginx container, waits for it to become ready via an HTTP check,
/// fetches the root page, then terminates the container.
///
/// Run with:
///   zig build example
const std = @import("std");
const tc = @import("testcontainers");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting nginx container...", .{});

    const ctr = try tc.run(allocator, "nginx:latest", .{
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forHttp("/"),
    });
    defer {
        ctr.terminate() catch |err| {
            std.log.err("Failed to terminate container: {}", .{err});
        };
        ctr.deinit();
        tc.deinitProvider();
    }

    const port = try ctr.mappedPort("80/tcp", allocator);
    std.log.info("nginx is ready on localhost:{d}", .{port});

    // Verify the nginx page is reachable using std.http.Client
    const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/", .{port});
    defer allocator.free(url);

    var http_client: std.http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    const fetch_result = try http_client.fetch(.{
        .location = .{ .url = url },
    });

    std.log.info("HTTP status: {d}", .{@intFromEnum(fetch_result.status)});

    // Demonstrate exec
    const result = try ctr.exec(&.{ "echo", "hello from container" });
    defer allocator.free(result.output);
    std.log.info("Exec exit code: {d}", .{result.exit_code});
    std.log.info("Exec output: {s}", .{std.mem.trim(u8, result.output, "\n\r ")});

    std.log.info("Done — container will be terminated on defer.", .{});
}
