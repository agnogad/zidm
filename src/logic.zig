//! Pure helpers for ZIDM. No UI, no process handling — easy to test.
const std = @import("std");

pub const Category = struct {
    id: []const u8,
    label: []const u8,
    extensions: []const u8,
    folder: []const u8,
};

pub const builtin_categories = [_]Category{
    .{ .id = "general", .label = "General", .extensions = "*", .folder = "" },
    .{ .id = "compressed", .label = "Compressed", .extensions = "zip rar 7z tar gz bz2 xz iso", .folder = "Compressed" },
    .{ .id = "documents", .label = "Documents", .extensions = "pdf doc docx xls xlsx ppt pptx txt md epub mobi", .folder = "Documents" },
    .{ .id = "music", .label = "Music", .extensions = "mp3 m4a flac wav ogg opus aac", .folder = "Music" },
    .{ .id = "programs", .label = "Programs", .extensions = "exe msi apk deb rpm dmg appimage", .folder = "Programs" },
    .{ .id = "video", .label = "Video", .extensions = "mp4 mkv avi mov webm flv wmv m4v", .folder = "Video" },
    .{ .id = "torrents", .label = "Torrents", .extensions = "torrent", .folder = "Torrents" },
};

pub fn isSupportedUrl(url: []const u8) bool {
    const schemes = [_][]const u8{ "http://", "https://", "ftp://", "ftps://", "ftpes://", "magnet:" };
    for (schemes) |s| if (std.ascii.startsWithIgnoreCase(url, s)) return true;
    return false;
}

pub fn isVideoPage(url: []const u8) bool {
    const hosts = [_][]const u8{
        "youtube.com",  "youtu.be",   "music.youtube.com", "vimeo.com",    "dailymotion.com",
        "twitch.tv",    "tiktok.com", "x.com",             "twitter.com",  "instagram.com",
        "facebook.com", "reddit.com", "soundcloud.com",    "bilibili.com",
    };
    for (hosts) |h| if (indexIgnoreCase(url, h) != null) return true;
    return false;
}

pub fn extOf(name: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (i == 0 or i + 1 == name.len) return "";
    return name[i + 1 ..];
}

fn lowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    _ = std.ascii.lowerString(out, text);
    return out;
}

fn indexIgnoreCase(text: []const u8, needle: []const u8) ?usize {
    const a = std.heap.page_allocator;
    const t = lowerAlloc(a, text) catch return null;
    defer a.free(t);
    const n = lowerAlloc(a, needle) catch return null;
    defer a.free(n);
    return std.mem.indexOf(u8, t, n);
}

pub fn categoryFor(name: []const u8, categories: []const Category) []const u8 {
    const e = lowerAlloc(std.heap.page_allocator, extOf(name)) catch return "general";
    defer std.heap.page_allocator.free(e);
    for (categories) |c| {
        if (std.mem.eql(u8, c.id, "general") or std.mem.eql(u8, c.id, "torrents")) continue;
        var it = std.mem.tokenizeAny(u8, c.extensions, " ");
        while (it.next()) |candidate| {
            if (std.mem.eql(u8, candidate, "*") or std.mem.eql(u8, candidate, e)) return c.id;
        }
    }
    return "general";
}

pub fn fileNameFromUrl(url: []const u8) []const u8 {
    var end = url.len;
    if (std.mem.indexOfAny(u8, url, "?#")) |i| end = @min(end, i);
    const path = url[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "download";
    if (slash + 1 >= path.len) return "download";
    return path[slash + 1 ..];
}

pub fn basename(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[i + 1 ..];
}

pub fn uniqueName(allocator: std.mem.Allocator, name: []const u8, exists: *const fn ([]const u8) bool) ![]u8 {
    if (!exists(name)) return allocator.dupe(u8, name);
    const e = extOf(name);
    const stem = if (e.len > 0) name[0 .. name.len - e.len - 1] else name;
    var n: usize = 1;
    while (true) : (n += 1) {
        const candidate = if (e.len > 0)
            try std.fmt.allocPrint(allocator, "{s} ({d}).{s}", .{ stem, n, e })
        else
            try std.fmt.allocPrint(allocator, "{s} ({d})", .{ stem, n });
        if (!exists(candidate)) return candidate;
        allocator.free(candidate);
    }
}

pub fn expandBatch(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    from: u64,
    to: u64,
    width: usize,
    letters: bool,
) !std.ArrayListUnmanaged([]u8) {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) return error.NoWildcard;
    var i = from;
    while (i <= to) : (i += 1) {
        var token_buf: [16]u8 = undefined;
        const token = if (letters) blk: {
            if (i < 1 or i > 26) return error.OutOfRange;
            token_buf[0] = @as(u8, 'a') + @as(u8, @intCast(i - 1));
            break :blk token_buf[0..1];
        } else std.fmt.bufPrint(&token_buf, "{d:0>[1]}", .{ i, width }) catch return error.OutOfRange;
        const item = try std.mem.replaceOwned(u8, allocator, pattern, "*", token);
        try out.append(allocator, item);
        if (i == std.math.maxInt(u64) or (letters and i >= 26)) break;
    }
    return out;
}

pub fn extractUrls(allocator: std.mem.Allocator, text: []const u8) !std.ArrayListUnmanaged([]u8) {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var i: usize = 0;
    while (i < text.len) {
        const start = findScheme(text, i) orelse break;
        var end = start;
        while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '<' and
            text[end] != '>' and text[end] != '"' and text[end] != '\'' and text[end] != ')') : (end += 1)
        {}
        var url = text[start..end];
        while (url.len > 0 and std.mem.indexOfScalar(u8, ".,;:!?", url[url.len - 1]) != null)
            url = url[0 .. url.len - 1];
        if (isSupportedUrl(url)) {
            const dup = try allocator.dupe(u8, url);
            var duplicate = false;
            for (out.items) |old| if (std.mem.eql(u8, old, dup)) {
                duplicate = true;
                break;
            };
            if (duplicate) allocator.free(dup) else try out.append(allocator, dup);
        }
        i = if (end > start) end else start + 1;
    }
    return out;
}

fn findScheme(text: []const u8, from: usize) ?usize {
    var best: ?usize = null;
    const schemes = [_][]const u8{ "http://", "https://", "ftp://", "ftps://", "ftpes://", "magnet:" };
    for (schemes) |s| {
        const rel = indexIgnoreCase(text[from..], s) orelse continue;
        const pos = from + rel;
        if (best == null or pos < best.?) best = pos;
    }
    return best;
}

pub fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) {
        v /= 1024;
        u += 1;
    }
    if (u == 0) return std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[u] });
    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ v, units[u] });
}

pub fn parseRate(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " \t");
    const space = std.mem.indexOfAny(u8, t, " ") orelse return null;
    const value = std.fmt.parseFloat(f64, t[0..space]) catch return null;
    const unit = lowerAlloc(std.heap.page_allocator, t[space + 1 ..]) catch return null;
    defer std.heap.page_allocator.free(unit);
    var factor: f64 = 1;
    if (std.mem.startsWith(u8, unit, "k")) factor = 1024 else if (std.mem.startsWith(u8, unit, "m")) factor = 1024 * 1024 else if (std.mem.startsWith(u8, unit, "g")) factor = 1024 * 1024 * 1024;
    if (value < 0) return null;
    return @intFromFloat(value * factor);
}

pub fn checksum(allocator: std.mem.Allocator, io: std.Io, path: []const u8, algo: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(data);
    if (std.ascii.eqlIgnoreCase(algo, "crc32")) {
        return std.fmt.allocPrint(allocator, "{x:0>8}", .{std.hash.Crc32.hash(data)});
    }
    if (std.ascii.eqlIgnoreCase(algo, "md5")) {
        var out: [16]u8 = undefined;
        var h = std.crypto.hash.Md5.init(.{});
        h.update(data);
        h.final(&out);
        const hex = std.fmt.bytesToHex(out, .lower);
        return allocator.dupe(u8, &hex);
    } else if (std.ascii.eqlIgnoreCase(algo, "sha1")) {
        var out: [20]u8 = undefined;
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(data);
        h.final(&out);
        const hex = std.fmt.bytesToHex(out, .lower);
        return allocator.dupe(u8, &hex);
    } else if (std.ascii.eqlIgnoreCase(algo, "sha256")) {
        var out: [32]u8 = undefined;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(data);
        h.final(&out);
        const hex = std.fmt.bytesToHex(out, .lower);
        return allocator.dupe(u8, &hex);
    } else if (std.ascii.eqlIgnoreCase(algo, "sha512")) {
        var out: [64]u8 = undefined;
        var h = std.crypto.hash.sha2.Sha512.init(.{});
        h.update(data);
        h.final(&out);
        const hex = std.fmt.bytesToHex(out, .lower);
        return allocator.dupe(u8, &hex);
    }
    return error.UnsupportedAlgorithm;
}

test "supported URL schemes" {
    try std.testing.expect(isSupportedUrl("https://example.com/a.zip"));
    try std.testing.expect(isSupportedUrl("ftpes://example.com/a"));
    try std.testing.expect(isSupportedUrl("magnet:?xt=urn:btih:abc"));
    try std.testing.expect(!isSupportedUrl("javascript:alert(1)"));
}

test "category mapping" {
    try std.testing.expectEqualStrings("compressed", categoryFor("a.ZIP", &builtin_categories));
    try std.testing.expectEqualStrings("video", categoryFor("movie.mp4", &builtin_categories));
    try std.testing.expectEqualStrings("general", categoryFor("data.bin", &builtin_categories));
}

test "batch expansion" {
    const a = std.testing.allocator;
    var urls = try expandBatch(a, "https://x/ep*.mp4", 1, 3, 2, false);
    defer {
        for (urls.items) |s| a.free(s);
        urls.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), urls.items.len);
    try std.testing.expectEqualStrings("https://x/ep01.mp4", urls.items[0]);
    try std.testing.expectEqualStrings("https://x/ep03.mp4", urls.items[2]);
}

test "URL extraction is unique" {
    const a = std.testing.allocator;
    var urls = try extractUrls(a, "see https://a.test/x.zip and <https://a.test/x.zip> plus ftp://b.test/y");
    defer {
        for (urls.items) |s| a.free(s);
        urls.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), urls.items.len);
}

test "rate parsing" {
    try std.testing.expectEqual(@as(u64, 1024), parseRate("1 KB/s"));
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), parseRate("2 MiB/s"));
}
