//! ZIDM — a cross-platform download manager built on MyZig, aria2 and yt-dlp.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const logic = @import("logic.zig");
const engine_mod = @import("engine.zig");

const frontend = [_]myzig.FrontendFile{
    .{ .path = "index.html", .mime = "text/html; charset=utf-8", .data = @embedFile("index.html") },
    .{ .path = "styles.css", .mime = "text/css; charset=utf-8", .data = @embedFile("styles.css") },
    .{ .path = "app.js", .mime = "text/javascript; charset=utf-8", .data = @embedFile("app.js") },
};

const default_settings =
    "{\"theme\":\"auto\",\"dir\":\"\",\"connections\":8,\"speed\":0,\"global_speed\":0," ++
    "\"queues\":[\"Main\",\"Sync\"],\"records\":[],\"categories\":[],\"lang\":\"tr\"," ++
    "\"confirmDelete\":true,\"clipboard\":true,\"completeDialog\":true,\"notifications\":true}";

const State = struct {
    app: *myzig.App,
    gpa: std.mem.Allocator,
    io: std.Io,
    engine: engine_mod.Engine,
    settings_path: []const u8,
    data_dir: []const u8,
    downloads_dir: []const u8,
    quit: std.atomic.Value(bool) = .init(false),
    ready: bool = false,
    window: ?myzig.Window = null,
};

var reply: std.ArrayListUnmanaged(u8) = .empty;
var text_buf: std.ArrayListUnmanaged(u8) = .empty;
var str_buf: std.ArrayListUnmanaged(u8) = .empty;

/// Replies are encoded after the handler returns, so owned strings must live
/// in a module-level buffer rather than in a local that is freed on return.
fn replyString(gpa: std.mem.Allocator, text: []const u8) myzig.ipc.Result {
    str_buf.clearRetainingCapacity();
    str_buf.appendSlice(gpa, text) catch return failed(error.OutOfMemory);
    return myzig.ipc.Result.success(.{ .string = str_buf.items });
}

const J = struct {
    list: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    fn raw(self: J, s: []const u8) void {
        self.list.appendSlice(self.gpa, s) catch {};
    }
    fn str(self: J, s: []const u8) void {
        engine_mod.appendJsonString(self.list, self.gpa, s) catch {};
    }
};

fn begin(gpa: std.mem.Allocator) J {
    reply.clearRetainingCapacity();
    return .{ .list = &reply, .gpa = gpa };
}

fn failed(e: anyerror) myzig.ipc.Result {
    myzig.log.err("zidm: {s}", .{@errorName(e)});
    return myzig.ipc.Result.fail(.internal, @errorName(e));
}

fn stateOf(ctx: ?*anyopaque) *State {
    return @ptrCast(@alignCast(ctx.?));
}

fn dataDir(gpa: std.mem.Allocator) ![]const u8 {
    if (myzig.env.get("ZIDM_DATA_DIR")) |d| return gpa.dupe(u8, d);
    if (myzig.env.get("XDG_DATA_HOME")) |x| return std.fs.path.join(gpa, &.{ x, "zidm" });
    const home = myzig.env.get("HOME") orelse myzig.env.get("USERPROFILE") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "zidm" });
}

fn configPath(gpa: std.mem.Allocator) ![]const u8 {
    if (myzig.env.get("ZIDM_DATA_DIR")) |d| return std.fs.path.join(gpa, &.{ d, "settings.json" });
    if (myzig.env.get("XDG_CONFIG_HOME")) |x| return std.fs.path.join(gpa, &.{ x, "zidm", "settings.json" });
    if (myzig.env.get("APPDATA")) |x| return std.fs.path.join(gpa, &.{ x, "zidm", "settings.json" });
    const home = myzig.env.get("HOME") orelse myzig.env.get("USERPROFILE") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "zidm", "settings.json" });
}

fn downloadsDir(gpa: std.mem.Allocator) ![]const u8 {
    if (myzig.env.get("XDG_DOWNLOAD_DIR")) |d| return gpa.dupe(u8, d);
    const home = myzig.env.get("HOME") orelse myzig.env.get("USERPROFILE") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, "Downloads" });
}

fn toolExists(state: *State, name: []const u8) bool {
    const path = myzig.env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
    while (it.next()) |dir| {
        const candidate = std.fs.path.join(state.gpa, &.{ dir, name }) catch continue;
        defer state.gpa.free(candidate);
        std.Io.Dir.cwd().access(state.io, candidate, .{}) catch continue;
        return true;
    }
    return false;
}

fn toolVersion(state: *State, name: []const u8) []const u8 {
    if (!toolExists(state, name)) return "";
    const result = std.process.run(state.gpa, state.io, .{
        .argv = &.{ name, "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(8192),
    }) catch return "";
    defer state.gpa.free(result.stdout);
    defer state.gpa.free(result.stderr);
    if (!result.term.success()) return "";
    const clean = std.mem.trim(u8, result.stdout, " \t\r\n");
    const owned = state.gpa.dupe(u8, clean) catch "";
    return owned;
}

// ------------------------------------------------------------------- services

fn appStatus(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state = stateOf(ctx);
    const j = begin(state.gpa);
    const yt_name = if (builtin.os.tag == .windows) "yt-dlp.exe" else "yt-dlp";
    const gd_name = if (builtin.os.tag == .windows) "gallery-dl.exe" else "gallery-dl";
    const ff_name = if (builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";
    const ytv = toolVersion(state, yt_name);
    const gdv = toolVersion(state, gd_name);
    const ffv = toolVersion(state, ff_name);
    const ariav = toolVersion(state, if (builtin.os.tag == .windows) "aria2c.exe" else "aria2c");
    j.raw("{\"engine\":");
    j.raw(if (state.engine.child != null) "true" else "false");
    j.raw(",\"aria2\":");
    j.str(ariav);
    j.raw(",\"yt_dlp\":");
    j.str(yTvOrEmpty(ytv));
    j.raw(",\"ffmpeg\":");
    j.str(yTvOrEmpty(ffv));
    j.raw(",\"gallery_dl\":");
    j.str(yTvOrEmpty(gdv));
    j.raw(",\"downloads\":");
    j.str(state.downloads_dir);
    j.raw(",\"data\":");
    j.str(state.data_dir);
    j.raw("}");
    return myzig.ipc.Result.successRaw(reply.items);
}

fn yTvOrEmpty(s: []const u8) []const u8 {
    return s;
}

fn settingsLoad(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state = stateOf(ctx);
    const content = std.Io.Dir.cwd().readFileAlloc(state.io, state.settings_path, state.gpa, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => {
            text_buf.clearRetainingCapacity();
            text_buf.appendSlice(state.gpa, default_settings) catch {};
            return myzig.ipc.Result.successRaw(text_buf.items);
        },
        else => return failed(e),
    };
    defer state.gpa.free(content);
    text_buf.clearRetainingCapacity();
    text_buf.appendSlice(state.gpa, content) catch return failed(error.OutOfMemory);
    return myzig.ipc.Result.successRaw(text_buf.items);
}

fn settingsSave(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const content = a.stringBounded(4 * 1024 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    if (std.fs.path.dirname(state.settings_path)) |parent|
        std.Io.Dir.cwd().createDirPath(state.io, parent) catch |e| return failed(e);
    std.Io.Dir.cwd().writeFile(state.io, .{ .sub_path = state.settings_path, .data = content }) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn fsRead(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const path = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const text = std.Io.Dir.cwd().readFileAlloc(state.io, path, state.gpa, .limited(32 * 1024 * 1024)) catch |e| return failed(e);
    defer state.gpa.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) return myzig.ipc.Result.fail(.invalid_argument, "not utf8");
    text_buf.clearRetainingCapacity();
    text_buf.appendSlice(state.gpa, text) catch return failed(error.OutOfMemory);
    return myzig.ipc.Result.success(.{ .string = text_buf.items });
}

fn fsWrite(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const path = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const data = a.stringBounded(32 * 1024 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    std.Io.Dir.cwd().writeFile(state.io, .{ .sub_path = path, .data = data }) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn fsList(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const path = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    var dir = std.Io.Dir.cwd().openDir(state.io, path, .{ .iterate = true }) catch |e| return failed(e);
    defer dir.close(state.io);
    var it = dir.iterate();
    const j = begin(state.gpa);
    j.raw("[");
    var first = true;
    while (it.next(state.io) catch null) |entry| {
        if (!first) j.raw(",");
        first = false;
        j.raw("{\"name\":");
        j.str(entry.name);
        j.raw(",\"kind\":");
        j.str(switch (entry.kind) {
            .directory => "dir",
            else => "file",
        });
        j.raw("}");
    }
    j.raw("]");
    return myzig.ipc.Result.successRaw(reply.items);
}

fn fsCreateDir(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const path = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    std.Io.Dir.cwd().createDirPath(state.io, path) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn fsDelete(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const path = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const st = std.Io.Dir.cwd().statFile(state.io, path, .{ .follow_symlinks = false }) catch |e| return failed(e);
    if (st.kind == .directory)
        std.Io.Dir.cwd().deleteTree(state.io, path) catch |e| return failed(e)
    else
        std.Io.Dir.cwd().deleteFile(state.io, path) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn fsRename(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const from = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const to = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const cwd = std.Io.Dir.cwd();
    cwd.rename(from, cwd, to, state.io) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn checksum(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const path = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const algo = a.stringBounded(16) catch |e| return myzig.ipc.Args.toResult(e);
    const value = logic.checksum(state.gpa, state.io, path, algo) catch |e| return failed(e);
    defer state.gpa.free(value);
    return replyString(state.gpa, value);
}

fn fieldString(v: myzig.json.Value, key: []const u8) []const u8 {
    const f = v.get(key) orelse return "";
    return switch (f) {
        .string => |s| s,
        else => "",
    };
}
fn fieldBool(v: myzig.json.Value, key: []const u8) bool {
    const f = v.get(key) orelse return false;
    return switch (f) {
        .bool => |b| b,
        else => false,
    };
}
fn fieldInt(v: myzig.json.Value, key: []const u8, fallback: i64) i64 {
    const f = v.get(key) orelse return fallback;
    return switch (f) {
        .number => |n| std.fmt.parseInt(i64, n, 10) catch fallback,
        else => fallback,
    };
}

fn buildOptions(state: *State, options_json: []const u8, dir: []const u8) ![]u8 {
    var parser = myzig.json.Parser.init(state.gpa, options_json);
    defer parser.deinit();
    const parsed = parser.parse() catch return error.BadOptions;
    if (parsed != .object) return error.BadOptions;
    const name = fieldString(parsed, "name");
    const queue = fieldString(parsed, "queue");
    const paused = fieldBool(parsed, "paused");
    const connections = fieldInt(parsed, "connections", 8);
    const user = fieldString(parsed, "user");
    const pass = fieldString(parsed, "pass");
    const referer = fieldString(parsed, "referer");
    const ua = fieldString(parsed, "userAgent");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(state.gpa);
    try out.appendSlice(state.gpa, "{\"dir\":");
    try engine_mod.appendJsonString(&out, state.gpa, dir);
    if (name.len > 0) {
        try out.appendSlice(state.gpa, ",\"out\":");
        try engine_mod.appendJsonString(&out, state.gpa, name);
    }
    if (paused) try out.appendSlice(state.gpa, ",\"pause\":\"true\"");
    try out.appendSlice(state.gpa, ",\"max-connection-per-server\":\"");
    var nb: [16]u8 = undefined;
    try out.appendSlice(state.gpa, std.fmt.bufPrint(&nb, "{d}", .{connections}) catch "8");
    try out.appendSlice(state.gpa, "\",\"split\":\"");
    try out.appendSlice(state.gpa, std.fmt.bufPrint(&nb, "{d}", .{connections}) catch "8");
    try out.append(state.gpa, '"');
    if (user.len > 0) {
        try out.appendSlice(state.gpa, ",\"http-user\":");
        try engine_mod.appendJsonString(&out, state.gpa, user);
        try out.appendSlice(state.gpa, ",\"http-passwd\":");
        try engine_mod.appendJsonString(&out, state.gpa, pass);
    }
    if (referer.len > 0) {
        try out.appendSlice(state.gpa, ",\"referer\":");
        try engine_mod.appendJsonString(&out, state.gpa, referer);
    }
    if (ua.len > 0) {
        try out.appendSlice(state.gpa, ",\"user-agent\":");
        try engine_mod.appendJsonString(&out, state.gpa, ua);
    }
    if (queue.len > 0) {
        try out.appendSlice(state.gpa, ",\"comment\":");
        try engine_mod.appendJsonString(&out, state.gpa, queue);
    }
    try out.append(state.gpa, '}');
    return out.toOwnedSlice(state.gpa);
}

fn dlAdd(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const url = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    if (!logic.isSupportedUrl(url)) return myzig.ipc.Result.fail(.invalid_argument, "invalid address");
    const dir = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    const options_json = a.stringBounded(64 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const options = buildOptions(state, options_json, dir) catch |e| return failed(e);
    defer state.gpa.free(options);
    const response = state.engine.addUri(url, options) catch |e| return failed(e);
    defer state.gpa.free(response);
    const gid = engine_mod.resultString(state.gpa, response) catch |e| return failed(e);
    defer state.gpa.free(gid);
    return replyString(state.gpa, gid);
}

fn dlAddTorrent(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const payload = a.stringBounded(64 * 1024 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const is_magnet = std.mem.startsWith(u8, payload, "magnet:");
    const dir = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    const options_json = a.stringBounded(64 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const options = buildOptions(state, options_json, dir) catch |e| return failed(e);
    defer state.gpa.free(options);
    const response = if (is_magnet)
        state.engine.addUri(payload, options) catch |e| return failed(e)
    else
        state.engine.addTorrent(payload, options) catch |e| return failed(e);
    defer state.gpa.free(response);
    const gid = engine_mod.resultString(state.gpa, response) catch |e| return failed(e);
    defer state.gpa.free(gid);
    return replyString(state.gpa, gid);
}

fn dlAddTorrentFile(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const path = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const dir = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    const options_json = a.stringBounded(64 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const data = std.Io.Dir.cwd().readFileAlloc(state.io, path, state.gpa, .limited(64 * 1024 * 1024)) catch |e| return failed(e);
    defer state.gpa.free(data);
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = state.gpa.alloc(u8, encoded_len) catch |e| return failed(e);
    defer state.gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    const options = buildOptions(state, options_json, dir) catch |e| return failed(e);
    defer state.gpa.free(options);
    const response = state.engine.addTorrent(encoded, options) catch |e| return failed(e);
    defer state.gpa.free(response);
    const gid = engine_mod.resultString(state.gpa, response) catch |e| return failed(e);
    defer state.gpa.free(gid);
    return replyString(state.gpa, gid);
}

fn dlBatch(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const urls_json = a.stringBounded(4 * 1024 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const dir = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    var parser = myzig.json.Parser.init(state.gpa, urls_json);
    defer parser.deinit();
    const parsed = parser.parse() catch return myzig.ipc.Result.fail(.invalid_argument, "bad url list");
    if (parsed != .array) return myzig.ipc.Result.fail(.invalid_argument, "bad url list");
    const j = begin(state.gpa);
    j.raw("[");
    var first = true;
    for (parsed.array) |v| {
        if (v != .string or !logic.isSupportedUrl(v.string)) continue;
        const opts = std.fmt.allocPrint(state.gpa, "{{\"dir\":{s}}}", .{blinkJsonString(state.gpa, dir) catch continue}) catch continue;
        defer state.gpa.free(opts);
        const response = state.engine.addUri(v.string, opts) catch continue;
        defer state.gpa.free(response);
        const gid = engine_mod.resultString(state.gpa, response) catch continue;
        if (!first) j.raw(",");
        first = false;
        j.str(gid);
        state.gpa.free(gid);
    }
    j.raw("]");
    return myzig.ipc.Result.successRaw(reply.items);
}

fn blinkJsonString(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    try engine_mod.appendJsonString(&list, gpa, s);
    return list.toOwnedSlice(gpa);
}

fn dlList(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state = stateOf(ctx);
    const response = state.engine.tellAll() catch |e| return failed(e);
    defer state.gpa.free(response);
    text_buf.clearRetainingCapacity();
    text_buf.appendSlice(state.gpa, response) catch return failed(error.OutOfMemory);
    return myzig.ipc.Result.successRaw(text_buf.items);
}

fn dlControl(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const method = a.stringBounded(32) catch |e| return myzig.ipc.Args.toResult(e);
    const gid = a.stringBounded(128) catch |e| return myzig.ipc.Args.toResult(e);
    const allowed = [_][]const u8{ "aria2.pause", "aria2.unpause", "aria2.remove", "aria2.removeDownloadResult", "aria2.forcePause", "aria2.forceRemove" };
    var ok = false;
    for (allowed) |m| if (std.mem.eql(u8, m, method)) {
        ok = true;
        break;
    };
    if (!ok) return myzig.ipc.Result.fail(.invalid_argument, "method not allowed");
    const response = state.engine.control(method, gid) catch |e| return failed(e);
    state.gpa.free(response);
    return myzig.ipc.Result.success(.null);
}

fn dlOption(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const gid = a.stringBounded(128) catch |e| return myzig.ipc.Args.toResult(e);
    const options = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const response = state.engine.setOption(gid, options) catch |e| return failed(e);
    state.gpa.free(response);
    return myzig.ipc.Result.success(.null);
}

fn dlGlobal(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const options = a.stringBounded(16 * 1024) catch |e| return myzig.ipc.Args.toResult(e);
    const response = state.engine.setGlobal(options) catch |e| return failed(e);
    state.gpa.free(response);
    return myzig.ipc.Result.success(.null);
}

fn videoLookup(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const url = a.stringBounded(8192) catch |e| return myzig.ipc.Args.toResult(e);
    const name = if (builtin.os.tag == .windows) "yt-dlp.exe" else "yt-dlp";
    const argv = [_][]const u8{ name, "--no-playlist", "--skip-download", "--no-warnings", "--dump-single-json", url };
    const result = std.process.run(state.gpa, state.io, .{
        .argv = &argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |e| return failed(e);
    defer state.gpa.free(result.stdout);
    defer state.gpa.free(result.stderr);
    if (!result.term.success()) {
        const detail = std.mem.trim(u8, result.stderr, " \t\r\n");
        return myzig.ipc.Result.fail(.internal, if (detail.len > 0) detail else "yt-dlp failed");
    }
    text_buf.clearRetainingCapacity();
    text_buf.appendSlice(state.gpa, std.mem.trim(u8, result.stdout, " \t\r\n")) catch return failed(error.OutOfMemory);
    return myzig.ipc.Result.successRaw(text_buf.items);
}

// ----------------------------------------------------------- background tools

const ToolKind = enum { video, gallery };

const ToolJob = struct {
    kind: ToolKind,
    state: *State,
    argv: []const []const u8,
    store: []u8,
};

fn emitText(state: *State, name: []const u8, text: []const u8) void {
    _ = state.app.emit(name, .{ .string = text });
}

fn toolWorker(job: *ToolJob) void {
    const state = job.state;
    defer {
        for (job.argv) |s| state.gpa.free(s);
        state.gpa.free(job.argv);
        state.gpa.free(job.store);
        state.gpa.destroy(job);
    }
    const progress_event = if (job.kind == .video) "video:progress" else "gallery:progress";
    const done_event = if (job.kind == .video) "video:done" else "gallery:done";
    const error_event = if (job.kind == .video) "video:error" else "gallery:error";
    var child = std.process.spawn(state.io, .{
        .argv = job.argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |e| {
        emitText(state, error_event, @errorName(e));
        return;
    };
    defer child.kill(state.io);
    var buf: [8192]u8 = undefined;
    var reader = child.stdout.?.reader(state.io, &buf);
    while (reader.interface.takeDelimiterExclusive('\n')) |line| {
        const clean = std.mem.trim(u8, line, " \t\r");
        if (clean.len > 0) emitText(state, progress_event, clean);
    } else |_| {}
    const term = child.wait(state.io) catch |e| {
        emitText(state, error_event, @errorName(e));
        return;
    };
    if (term.success()) emitText(state, done_event, "done") else emitText(state, error_event, "tool failed");
}

fn startTool(state: *State, kind: ToolKind, argv: []const []const u8, store: []u8) !void {
    const job = try state.gpa.create(ToolJob);
    errdefer state.gpa.destroy(job);
    job.* = .{ .kind = kind, .state = state, .argv = argv, .store = store };
    const thread = try std.Thread.spawn(.{}, toolWorker, .{job});
    thread.detach();
}

fn videoDownload(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const url = tryString(&a, 8192) catch |e| return myzig.ipc.Args.toResult(e);
    const selector = tryString(&a, 256) catch |e| return myzig.ipc.Args.toResult(e);
    const dir = tryString(&a, 8192) catch |e| return myzig.ipc.Args.toResult(e);
    const name = if (builtin.os.tag == .windows) "yt-dlp.exe" else "yt-dlp";
    const out_tmpl = std.fmt.allocPrint(state.gpa, "{s}/%(title)s.%(ext)s", .{dir}) catch |e| return failed(e);
    const argv = state.gpa.alloc([]const u8, 8) catch |e| return failed(e);
    argv[0] = state.gpa.dupe(u8, name) catch |e| return failed(e);
    argv[1] = state.gpa.dupe(u8, "--no-playlist") catch |e| return failed(e);
    argv[2] = state.gpa.dupe(u8, "--newline") catch |e| return failed(e);
    argv[3] = state.gpa.dupe(u8, "-f") catch |e| return failed(e);
    argv[4] = state.gpa.dupe(u8, selector) catch |e| return failed(e);
    argv[5] = state.gpa.dupe(u8, "-o") catch |e| return failed(e);
    argv[6] = out_tmpl;
    argv[7] = state.gpa.dupe(u8, url) catch |e| return failed(e);
    startTool(state, .video, argv, out_tmpl) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn galleryDownload(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state = stateOf(ctx);
    var a = args;
    const url = tryString(&a, 8192) catch |e| return myzig.ipc.Args.toResult(e);
    const dir = tryString(&a, 8192) catch |e| return myzig.ipc.Args.toResult(e);
    const name = if (builtin.os.tag == .windows) "gallery-dl.exe" else "gallery-dl";
    const argv = state.gpa.alloc([]const u8, 5) catch |e| return failed(e);
    argv[0] = state.gpa.dupe(u8, name) catch |e| return failed(e);
    argv[1] = state.gpa.dupe(u8, "--destination") catch |e| return failed(e);
    argv[2] = state.gpa.dupe(u8, dir) catch |e| return failed(e);
    argv[3] = state.gpa.dupe(u8, "--range") catch |e| return failed(e);
    argv[4] = state.gpa.dupe(u8, url) catch |e| return failed(e);
    startTool(state, .gallery, argv, state.gpa.dupe(u8, dir) catch |e| return failed(e)) catch |e| return failed(e);
    return myzig.ipc.Result.success(.null);
}

fn tryString(a: *myzig.ipc.Args, max: usize) ![]const u8 {
    return a.stringBounded(max);
}

// ---------------------------------------------------------------------- loops

fn pollLoop(state: *State) void {
    while (!state.quit.load(.acquire)) {
        if (state.ready) {
            if (state.engine.tellAll()) |response| {
                _ = state.app.emit("dl:update", .{ .string = response });
                state.gpa.free(response);
            } else |_| {}
        }
        std.Io.sleep(state.io, .{ .nanoseconds = 400_000_000 }, .awake) catch return;
    }
}

fn onBeforeQuit(ev: *myzig.App.QuitEvent, ctx: ?*anyopaque) void {
    _ = ev;
    const state = stateOf(ctx);
    state.quit.store(true, .release);
    state.engine.stop();
}

fn onPageReady(state: *State, window: u32, payload: myzig.json.Value) void {
    _ = window;
    _ = payload;
    if (state.window) |w| state.app.showWindow(w, true);
}

// ------------------------------------------------------------------------ run

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const io = init.io;

    const data = try dataDir(gpa);
    defer gpa.free(data);
    const settings = try configPath(gpa);
    defer gpa.free(settings);
    const downloads = try downloadsDir(gpa);
    defer gpa.free(downloads);
    const session = try std.fs.path.join(gpa, &.{ data, "aria2.session" });
    defer gpa.free(session);

    var app = try myzig.App.init(gpa, .{
        .name = "ZIDM",
        .app_id = "dev.myzig.zidm",
        .frontend = &frontend,
        .io = io,
        .single_instance = true,
    });
    defer app.deinit();

    var state = State{
        .app = &app,
        .gpa = gpa,
        .io = io,
        .engine = engine_mod.Engine.init(gpa, io, session, data),
        .settings_path = settings,
        .data_dir = data,
        .downloads_dir = downloads,
    };

    if (state.engine.available()) state.engine.start() catch |e| {
        myzig.log.warn("zidm: engine did not start: {s}", .{@errorName(e)});
    };

    try app.bind(.{ .name = "App.status", .invoke = appStatus, .ctx = &state, .arity = 0 });
    try app.bind(.{ .name = "Settings.load", .invoke = settingsLoad, .ctx = &state, .arity = 0 });
    try app.bind(.{ .name = "Settings.save", .invoke = settingsSave, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Fs.read", .invoke = fsRead, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Fs.write", .invoke = fsWrite, .ctx = &state, .arity = 2 });
    try app.bind(.{ .name = "Fs.list", .invoke = fsList, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Fs.createDir", .invoke = fsCreateDir, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Fs.delete", .invoke = fsDelete, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Fs.rename", .invoke = fsRename, .ctx = &state, .arity = 2 });
    try app.bind(.{ .name = "Tools.checksum", .invoke = checksum, .ctx = &state, .arity = 2 });
    try app.bind(.{ .name = "Dl.add", .invoke = dlAdd, .ctx = &state, .arity = 3 });
    try app.bind(.{ .name = "Dl.addTorrent", .invoke = dlAddTorrent, .ctx = &state, .arity = 3 });
    try app.bind(.{ .name = "Dl.addTorrentFile", .invoke = dlAddTorrentFile, .ctx = &state, .arity = 3 });
    try app.bind(.{ .name = "Dl.batch", .invoke = dlBatch, .ctx = &state, .arity = 2 });
    try app.bind(.{ .name = "Dl.list", .invoke = dlList, .ctx = &state, .arity = 0 });
    try app.bind(.{ .name = "Dl.control", .invoke = dlControl, .ctx = &state, .arity = 2 });
    try app.bind(.{ .name = "Dl.option", .invoke = dlOption, .ctx = &state, .arity = 2 });
    try app.bind(.{ .name = "Dl.global", .invoke = dlGlobal, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Video.lookup", .invoke = videoLookup, .ctx = &state, .arity = 1 });
    try app.bind(.{ .name = "Video.download", .invoke = videoDownload, .ctx = &state, .arity = 3 });
    try app.bind(.{ .name = "Gallery.download", .invoke = galleryDownload, .ctx = &state, .arity = 2 });

    try app.onBeforeQuit(onBeforeQuit, &state);
    try app.onPageEvent(State, "zidm:ready", &state, onPageReady);

    const thread = try std.Thread.spawn(.{}, pollLoop, .{&state});
    thread.detach();

    const url: []const u8 = if (myzig.env.get("ZIDM_SELFTEST") != null)
        "myzig://app/index.html?selftest=1"
    else
        "";

    state.window = try app.createWindow(.{
        .title = "ZIDM — Download Manager",
        .width = 1280,
        .height = 800,
        .state_key = "zidm-main",
        .url = url,
        .hidden = false,
        .background = 0x141415ff,
    });
    state.ready = true;

    try app.run();
}

test "frontend is embedded" {
    try std.testing.expectEqual(@as(usize, 3), frontend.len);
    for (frontend) |f| try std.testing.expect(f.data.len > 0);
}
