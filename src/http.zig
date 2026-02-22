/// Minimal HTTP/1.1 client over a Unix domain socket.
///
/// Used exclusively for communicating with the Docker Engine API, which
/// is exposed at /var/run/docker.sock.  No TLS is needed since the socket
/// is already access-controlled by the OS.
///
/// This module does NOT depend on dusty; it uses only std.posix and std.net
/// so that a zio.Runtime is not required for Docker API calls.
const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const HttpResponse = struct {
    /// HTTP status code (e.g. 200, 404).
    status: u16,
    /// Full response body, allocated with the provided allocator.
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
    }
};

/// A live streaming response: the caller reads bytes directly from the socket
/// via `read()` until it returns 0, then calls `close()`.
pub const StreamingResponse = struct {
    status: u16,
    stream: std.net.Stream,

    pub fn close(self: *StreamingResponse) void {
        self.stream.close();
    }

    /// Read raw bytes from the socket.  Returns 0 at EOF.
    pub fn read(self: *StreamingResponse, buf: []u8) !usize {
        return self.stream.read(buf);
    }
};

// ---------------------------------------------------------------------------
// DockerHttp
// ---------------------------------------------------------------------------

pub const DockerHttp = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) DockerHttp {
        return .{ .allocator = allocator, .socket_path = socket_path };
    }

    // -----------------------------------------------------------------------
    // Connection
    // -----------------------------------------------------------------------

    fn connect(self: *DockerHttp) !std.net.Stream {
        const addr = try std.net.Address.initUnix(self.socket_path);
        const handle = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM,
            0,
        );
        errdefer std.posix.close(handle);
        try std.posix.connect(handle, &addr.any, addr.getOsSockLen());
        return std.net.Stream{ .handle = handle };
    }

    // -----------------------------------------------------------------------
    // Request helpers
    // -----------------------------------------------------------------------

    /// Perform a complete request and return the response.
    /// The returned `HttpResponse.body` is owned by the caller.
    pub fn request(
        self: *DockerHttp,
        method: []const u8,
        path: []const u8,
        content_type: ?[]const u8,
        body: ?[]const u8,
    ) !HttpResponse {
        var stream = try self.connect();
        defer stream.close();

        // Write request
        var write_buf: [4096]u8 = undefined;
        var bw = std.io.fixedBufferStream(&write_buf);
        const w = bw.writer();

        try w.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
        try w.writeAll("Host: localhost\r\n");
        try w.writeAll("Connection: close\r\n");
        if (content_type) |ct| try w.print("Content-Type: {s}\r\n", .{ct});
        if (body) |b| try w.print("Content-Length: {d}\r\n", .{b.len});
        try w.writeAll("\r\n");

        try stream.writeAll(bw.getWritten());
        if (body) |b| try stream.writeAll(b);

        // Read response
        var rdr = StreamReader.init(stream);
        return readResponse(self.allocator, &rdr);
    }

    /// Perform a request and return a streaming handle.
    /// The caller MUST call `resp.close()` when done.
    pub fn requestStream(
        self: *DockerHttp,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
    ) !StreamingResponse {
        var stream = try self.connect();
        errdefer stream.close();

        var write_buf: [4096]u8 = undefined;
        var bw = std.io.fixedBufferStream(&write_buf);
        const w = bw.writer();

        try w.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
        try w.writeAll("Host: localhost\r\n");
        try w.writeAll("Connection: close\r\n");
        if (body) |b| {
            try w.writeAll("Content-Type: application/json\r\n");
            try w.print("Content-Length: {d}\r\n", .{b.len});
        }
        try w.writeAll("\r\n");

        try stream.writeAll(bw.getWritten());
        if (body) |b| try stream.writeAll(b);

        // Parse just the status line and drain headers
        var rdr = StreamReader.init(stream);
        var line_buf: [512]u8 = undefined;
        const status = try readStatusLine(&rdr, &line_buf);
        try drainHeaders(&rdr, &line_buf);

        return StreamingResponse{ .status = status, .stream = stream };
    }
};

// ---------------------------------------------------------------------------
// Byte-level stream reader (avoids the 0.15 buffered-reader API change)
// ---------------------------------------------------------------------------

/// Thin wrapper so we can call readByte() / read() without going through the
/// buffered-reader API that changed signature in Zig 0.15.
const StreamReader = struct {
    stream: std.net.Stream,

    fn init(s: std.net.Stream) StreamReader {
        return .{ .stream = s };
    }

    fn readByte(self: *StreamReader) !u8 {
        var b: [1]u8 = undefined;
        const n = try self.stream.read(&b);
        if (n == 0) return error.EndOfStream;
        return b[0];
    }

    fn read(self: *StreamReader, buf: []u8) !usize {
        return self.stream.read(buf);
    }
};

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

/// Read a complete HTTP/1.1 response from `rdr` and return it.
fn readResponse(allocator: std.mem.Allocator, rdr: *StreamReader) !HttpResponse {
    var line_buf: [2048]u8 = undefined;

    // Status line
    const status = try readStatusLine(rdr, &line_buf);

    // Headers — look for Content-Length and Transfer-Encoding
    var content_length: ?usize = null;
    var chunked = false;

    while (true) {
        const line = readLine(rdr, &line_buf) catch break;
        if (line.len == 0) break; // empty line = end of headers

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseUnsigned(usize, val, 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
            const val = std.mem.trim(u8, line["transfer-encoding:".len..], " \t");
            chunked = std.ascii.indexOfIgnoreCase(val, "chunked") != null;
        }
    }

    // Body
    const body = if (content_length) |cl| blk: {
        const b = try allocator.alloc(u8, cl);
        errdefer allocator.free(b);
        var n: usize = 0;
        while (n < cl) {
            const got = try rdr.read(b[n..]);
            if (got == 0) break;
            n += got;
        }
        break :blk b;
    } else if (chunked) blk: {
        break :blk try readChunked(allocator, rdr, &line_buf);
    } else blk: {
        // Read until connection close
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = rdr.read(&tmp) catch break;
            if (n == 0) break;
            try buf.appendSlice(allocator, tmp[0..n]);
        }
        break :blk try buf.toOwnedSlice(allocator);
    };

    return HttpResponse{ .status = status, .body = body, .allocator = allocator };
}

/// Parse `HTTP/1.1 200 OK\r\n` and return the status code.
fn readStatusLine(rdr: *StreamReader, buf: []u8) !u16 {
    const line = try readLine(rdr, buf);
    // "HTTP/1.1 200 OK"
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next() orelse return error.InvalidResponse; // HTTP/1.1
    const code_str = it.next() orelse return error.InvalidResponse;
    return std.fmt.parseUnsigned(u16, code_str, 10) catch error.InvalidResponse;
}

/// Drain all header lines until the blank line.
fn drainHeaders(rdr: *StreamReader, buf: []u8) !void {
    while (true) {
        const line = readLine(rdr, buf) catch break;
        if (line.len == 0) break;
    }
}

/// Read a single CRLF-terminated line into `buf`, strip the \r\n.
/// Returns an empty slice for blank lines.
fn readLine(rdr: *StreamReader, buf: []u8) ![]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const b = rdr.readByte() catch return error.EndOfStream;
        if (b == '\n') {
            // Strip trailing \r
            const end = if (i > 0 and buf[i - 1] == '\r') i - 1 else i;
            return buf[0..end];
        }
        buf[i] = b;
        i += 1;
    }
    return error.LineTooLong;
}

/// Decode a chunked transfer-encoding body.
fn readChunked(allocator: std.mem.Allocator, rdr: *StreamReader, line_buf: []u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    while (true) {
        // Chunk size line (hex)
        const size_line = readLine(rdr, line_buf) catch break;
        if (size_line.len == 0) continue;

        // Strip optional chunk extensions
        const semi = std.mem.indexOfScalar(u8, size_line, ';');
        const hex = if (semi) |s| size_line[0..s] else size_line;
        const chunk_size = std.fmt.parseUnsigned(usize, hex, 16) catch break;
        if (chunk_size == 0) break;

        const start = result.items.len;
        try result.resize(allocator, start + chunk_size);
        var n: usize = 0;
        while (n < chunk_size) {
            const got = try rdr.read(result.items[start + n ..]);
            if (got == 0) break;
            n += got;
        }
        // Trailing CRLF after each chunk
        _ = readLine(rdr, line_buf) catch {};
    }

    return result.toOwnedSlice(allocator);
}
