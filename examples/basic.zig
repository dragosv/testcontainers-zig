/// Basic testcontainers-zig example.
///
/// Starts an nginx container, waits for it to become ready via an HTTP check,
/// fetches the root page, then terminates the container.
///
/// Run with:
///   zig build example
const std = @import("std");
const zio = @import("zio");
const tc = @import("testcontainers");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // IMPORTANT: initialise the zio runtime before making any network calls.
    // dusty (the HTTP library) is async-behind-the-scenes via zio.
    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

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

    // Fetch the nginx welcome page using a dusty client
    var client = tc.DockerClient.init(allocator, tc.docker_socket);
    defer client.deinit();

    // Use a plain dusty client to hit the mapped port over TCP
    const dusty = @import("dusty");
    var http_client = dusty.Client.init(allocator, .{});
    defer http_client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/", .{port});
    defer allocator.free(url);

    var resp = try http_client.fetch(url, .{});
    defer resp.deinit();

    std.log.info("HTTP status: {d}", .{@intFromEnum(resp.status())});

    if (try resp.body()) |body| {
        const preview_len = @min(body.len, 200);
        std.log.info("Body preview:\n{s}", .{body[0..preview_len]});
    }

    // Demonstrate exec
    const result = try ctr.exec(&.{ "echo", "hello from container" });
    defer allocator.free(result.output);
    std.log.info("Exec exit code: {d}", .{result.exit_code});
    std.log.info("Exec output: {s}", .{std.mem.trim(u8, result.output, "\n\r ")});

    std.log.info("Done — container will be terminated on defer.", .{});
}
