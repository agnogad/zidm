//! aria2 JSON-RPC engine. One daemon per app; all control goes through RPC.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");

const aria2 = if (builtin.os.tag == .windows) "aria2c.exe" else "aria2c";

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    port: u16 = 16816,
    secret: []const u8 = "zidm-secret",
    child: ?std.process.Child = null,
    session_path: []const u8,
    data_dir: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, session_path: []const u8, data_dir: []const u8) Engine {
        return .{ .gpa = gpa, .io = io, .session_path = session_path, .data_dir = data_dir };
    }

    pub fn available(self: *Engine) bool {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ aria2, "--version" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.term.success();
    }

    pub fn start(self: *Engine) !void {
        if (self.child != null) return;
        try std.Io.Dir.cwd().createDirPath(self.io, self.data_dir);
        // aria2 refuses to start when --input-file does not exist yet.
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.session_path, .data = "" }) catch {};
        const rpc_port = try std.fmt.allocPrint(self.gpa, "--rpc-listen-port={d}", .{self.port});
        defer self.gpa.free(rpc_port);
        const secret = try std.fmt.allocPrint(self.gpa, "--rpc-secret={s}", .{self.secret});
        defer self.gpa.free(secret);
        const session = try std.fmt.allocPrint(self.gpa, "--save-session={s}", .{self.session_path});
        defer self.gpa.free(session);
        const input = try std.fmt.allocPrint(self.gpa, "--input-file={s}", .{self.session_path});
        defer self.gpa.free(input);
        const dir = try std.fmt.allocPrint(self.gpa, "--dir={s}", .{self.data_dir});
        defer self.gpa.free(dir);

        const argv = [_][]const u8{
            aria2,
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            rpc_port,
            secret,
            "--continue=true",
            "--max-connection-per-server=8",
            "--split=8",
            "--min-split-size=1M",
            "--allow-overwrite=false",
            "--auto-file-renaming=true",
            "--bt-save-metadata=true",
            "--save-session-interval=5",
            session,
            input,
            dir,
            "--quiet=true",
        };
        self.child = try std.process.spawn(self.io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        });

        // Wait until the RPC endpoint answers.
        var tries: usize = 0;
        while (tries < 200) : (tries += 1) {
            if (self.call("aria2.getVersion", "[]")) |response| {
                defer self.gpa.free(response);
                if (std.mem.indexOf(u8, response, "\"result\"") != null and
                    std.mem.indexOf(u8, response, "\"error\"") == null) return;
            } else |_| std.Io.sleep(self.io, .{ .nanoseconds = 100_000_000 }, .awake) catch {};
        }
        return error.EngineNotReady;
    }

    pub fn stop(self: *Engine) void {
        if (self.child) |*child| {
            child.kill(self.io);
            self.child = null;
        }
    }

    pub fn rpcUrl(_: *const Engine) []const u8 {
        return std.fmt.comptimePrint("http://127.0.0.1:16816/jsonrpc", .{});
    }

    fn request(self: *Engine, method: []const u8, params: []const u8, id: u32) ![]u8 {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(self.gpa);
        try body.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        var idbuf: [16]u8 = undefined;
        try body.appendSlice(self.gpa, std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch return error.OutOfMemory);
        try body.appendSlice(self.gpa, ",\"method\":");
        try appendJsonString(&body, self.gpa, method);
        try body.appendSlice(self.gpa, ",\"params\":");
        try body.appendSlice(self.gpa, params);
        try body.appendSlice(self.gpa, "}");

        const address = try std.Io.net.IpAddress.parse("127.0.0.1", self.port);
        const stream = try std.Io.net.IpAddress.connect(&address, self.io, .{ .mode = .stream });
        defer stream.close(self.io);

        var send_buf: [2048]u8 = undefined;
        var w = stream.writer(self.io, &send_buf);
        var header: [256]u8 = undefined;
        const req_head = try std.fmt.bufPrint(&header, "POST /jsonrpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.items.len});
        try w.interface.writeAll(req_head);
        try w.interface.writeAll(body.items);
        try w.interface.flush();

        var collected: std.ArrayListUnmanaged(u8) = .empty;
        errdefer collected.deinit(self.gpa);
        var recv_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &recv_buf);
        while (true) {
            const n = reader.interface.readSliceShort(&recv_buf) catch break;
            if (n == 0) break;
            try collected.appendSlice(self.gpa, recv_buf[0..n]);
        }
        const marker = std.mem.indexOf(u8, collected.items, "\r\n\r\n") orelse return error.BadRpcResponse;
        const payload = collected.items[marker + 4 ..];
        const owned = try self.gpa.dupe(u8, payload);
        collected.deinit(self.gpa);
        return owned;
    }

    pub fn rpc(self: *Engine, method: []const u8, params: []const u8) ![]u8 {
        return self.request(method, params, 1);
    }
    /// Calls an aria2 method with the secret token prepended to its params.
    pub fn call(self: *Engine, method: []const u8, params: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.gpa);
        const token = try std.fmt.allocPrint(self.gpa, "token:{s}", .{self.secret});
        defer self.gpa.free(token);
        try out.append(self.gpa, '[');
        try appendJsonString(&out, self.gpa, token);
        const trimmed = std.mem.trim(u8, params, " \t\r\n");
        if (trimmed.len > 1 and trimmed[0] == '[') {
            if (trimmed.len > 2) {
                try out.append(self.gpa, ',');
                try out.appendSlice(self.gpa, trimmed[1 .. trimmed.len - 1]);
            }
        } else if (trimmed.len > 2 and trimmed[0] == '{') {
            try out.append(self.gpa, ',');
            try out.appendSlice(self.gpa, trimmed);
        }
        try out.append(self.gpa, ']');
        return self.rpc(method, out.items);
    }

    pub fn addUri(self: *Engine, target_url: []const u8, options_json: []const u8) ![]u8 {
        var params: std.ArrayListUnmanaged(u8) = .empty;
        defer params.deinit(self.gpa);
        try params.appendSlice(self.gpa, "[[");
        try appendJsonString(&params, self.gpa, target_url);
        try params.appendSlice(self.gpa, "],");
        try params.appendSlice(self.gpa, options_json);
        try params.append(self.gpa, ']');
        return self.call("aria2.addUri", params.items);
    }

    pub fn addTorrent(self: *Engine, base64: []const u8, options_json: []const u8) ![]u8 {
        var params: std.ArrayListUnmanaged(u8) = .empty;
        defer params.deinit(self.gpa);
        try params.append(self.gpa, '[');
        try appendJsonString(&params, self.gpa, base64);
        try params.appendSlice(self.gpa, ",[],");
        try params.appendSlice(self.gpa, options_json);
        try params.append(self.gpa, ']');
        return self.call("aria2.addTorrent", params.items);
    }

    fn resultArray(self: *Engine, method: []const u8, params: []const u8) ![]u8 {
        const response = try self.call(method, params);
        defer self.gpa.free(response);
        const key = "\"result\":";
        const at = std.mem.indexOf(u8, response, key) orelse return error.NoResult;
        const rest = response[at + key.len ..];
        const begin_at = std.mem.indexOfScalar(u8, rest, '[') orelse return error.NoResult;
        var depth: usize = 0;
        var quoted = false;
        var escaped = false;
        var i = begin_at;
        while (i < rest.len) : (i += 1) {
            const c = rest[i];
            if (quoted) {
                if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
                continue;
            }
            if (c == '"') quoted = true else if (c == '[') depth += 1 else if (c == ']') {
                depth -= 1;
                if (depth == 0) return self.gpa.dupe(u8, rest[begin_at .. i + 1]);
            }
        }
        return error.NoResult;
    }

    pub fn tellAll(self: *Engine) ![]u8 {
        const active = try self.resultArray("aria2.tellActive", "[]");
        defer self.gpa.free(active);
        const waiting = try self.resultArray("aria2.tellWaiting", "[0,1000]");
        defer self.gpa.free(waiting);
        const stopped = try self.resultArray("aria2.tellStopped", "[0,1000]");
        defer self.gpa.free(stopped);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.append(self.gpa, '[');
        var first = true;
        for ([_][]const u8{ active, waiting, stopped }) |part| {
            const inner = std.mem.trim(u8, part, " \t\r\n");
            if (inner.len < 2) continue;
            const items = inner[1 .. inner.len - 1];
            if (items.len == 0) continue;
            if (!first) try out.append(self.gpa, ',');
            first = false;
            try out.appendSlice(self.gpa, items);
        }
        try out.append(self.gpa, ']');
        return out.toOwnedSlice(self.gpa);
    }

    pub fn control(self: *Engine, method: []const u8, gid: []const u8) ![]u8 {
        var params: std.ArrayListUnmanaged(u8) = .empty;
        defer params.deinit(self.gpa);
        try params.append(self.gpa, '[');
        try appendJsonString(&params, self.gpa, gid);
        try params.append(self.gpa, ']');
        return self.call(method, params.items);
    }

    pub fn setOption(self: *Engine, gid: []const u8, options_json: []const u8) ![]u8 {
        var params: std.ArrayListUnmanaged(u8) = .empty;
        defer params.deinit(self.gpa);
        try params.append(self.gpa, '[');
        try appendJsonString(&params, self.gpa, gid);
        try params.append(self.gpa, ',');
        try params.appendSlice(self.gpa, options_json);
        try params.append(self.gpa, ']');
        return self.call("aria2.changeOption", params.items);
    }

    pub fn setGlobal(self: *Engine, options_json: []const u8) ![]u8 {
        return self.call("aria2.changeGlobalOption", options_json);
    }

    pub fn getGlobal(self: *Engine) ![]u8 {
        return self.call("aria2.getGlobalOption", "[]");
    }
};

pub fn appendJsonString(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try list.append(gpa, '"');
    for (text) |c| switch (c) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var esc: [6]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch continue);
        } else try list.append(gpa, c),
    };
    try list.append(gpa, '"');
}

pub fn resultString(allocator: std.mem.Allocator, rpc_response: []const u8) ![]u8 {
    var parser = myzig.json.Parser.init(allocator, rpc_response);
    defer parser.deinit();
    const root = try parser.parse();
    const result = root.get("result") orelse return error.NoResult;
    return switch (result) {
        .string => |s| allocator.dupe(u8, s),
        else => error.NotAString,
    };
}
