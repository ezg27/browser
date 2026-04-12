// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");

const log = @import("../../log.zig");

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const URL = @import("../../browser/URL.zig");
const HttpClient = @import("../../browser/HttpClient.zig");
const Transfer = HttpClient.Transfer;
const Notification = @import("../../Notification.zig");
const Mime = @import("../../browser/Mime.zig");

const CdpStorage = @import("storage.zig");
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        setCacheDisabled,
        setExtraHTTPHeaders,
        setUserAgentOverride,
        deleteCookies,
        clearBrowserCookies,
        setCookie,
        setCookies,
        getCookies,
        getRequestPostData,
        getResponseBody,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .setCacheDisabled => return cmd.sendResult(null, .{}),
        .setUserAgentOverride => return cmd.sendResult(null, .{}),
        .setExtraHTTPHeaders => return setExtraHTTPHeaders(cmd),
        .deleteCookies => return deleteCookies(cmd),
        .clearBrowserCookies => return clearBrowserCookies(cmd),
        .setCookie => return setCookie(cmd),
        .setCookies => return setCookies(cmd),
        .getCookies => return getCookies(cmd),
        .getRequestPostData => return getRequestPostData(cmd),
        .getResponseBody => return getResponseBody(cmd),
    }
}

const EnableParams = struct {
    maxTotalBufferSize: ?usize = null,
    maxResourceBufferSize: ?usize = null,
    maxPostDataSize: ?usize = null,
    reportDirectSocketTraffic: ?bool = null,
    enableDurableMessages: ?bool = null,
};

fn enable(cmd: *CDP.Command) !void {
    const params = (try cmd.params(EnableParams)) orelse EnableParams{};
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.network_max_post_data_size = params.maxPostDataSize;
    try bc.networkEnable();
    return cmd.sendResult(null, .{});
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.networkDisable();
    return cmd.sendResult(null, .{});
}

fn setExtraHTTPHeaders(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        headers: std.json.ArrayHashMap([]const u8),
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // Copy the headers onto the browser context arena
    const arena = bc.arena;
    const extra_headers = &bc.extra_headers;

    extra_headers.clearRetainingCapacity();
    try extra_headers.ensureTotalCapacity(arena, params.headers.map.count());
    var it = params.headers.map.iterator();
    while (it.next()) |header| {
        const header_string = try std.fmt.allocPrintSentinel(arena, "{s}: {s}", .{ header.key_ptr.*, header.value_ptr.* }, 0);
        extra_headers.appendAssumeCapacity(header_string);
    }

    return cmd.sendResult(null, .{});
}

const Cookie = @import("../../browser/webapi/storage/storage.zig").Cookie;

// Only matches the cookie on provided parameters
fn cookieMatches(cookie: *const Cookie, name: []const u8, domain: ?[]const u8, path: ?[]const u8) bool {
    if (!std.mem.eql(u8, cookie.name, name)) return false;

    if (domain) |domain_| {
        const c_no_dot = if (std.mem.startsWith(u8, cookie.domain, ".")) cookie.domain[1..] else cookie.domain;
        const d_no_dot = if (std.mem.startsWith(u8, domain_, ".")) domain_[1..] else domain_;
        if (!std.mem.eql(u8, c_no_dot, d_no_dot)) return false;
    }
    if (path) |path_| {
        if (!std.mem.eql(u8, cookie.path, path_)) return false;
    }
    return true;
}

fn deleteCookies(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        name: []const u8,
        url: ?[:0]const u8 = null,
        domain: ?[]const u8 = null,
        path: ?[]const u8 = null,
        partitionKey: ?CdpStorage.CookiePartitionKey = null,
    })) orelse return error.InvalidParams;
    // Silently ignore partitionKey since we don't support partitioned cookies (CHIPS).
    // This allows Puppeteer's page.setCookie() to work, which sends deleteCookies
    // with partitionKey as part of its cookie-setting workflow.
    if (params.partitionKey != null) {
        log.warn(.not_implemented, "partition key", .{ .src = "deleteCookies" });
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const cookies = &bc.session.cookie_jar.cookies;

    var index = cookies.items.len;
    while (index > 0) {
        index -= 1;
        const cookie = &cookies.items[index];
        const domain = try Cookie.parseDomain(cmd.arena, params.url, params.domain);
        const path = try Cookie.parsePath(cmd.arena, params.url, params.path);

        // We do not want to use Cookie.appliesTo here. As a Cookie with a shorter path would match.
        // Similar to deduplicating with areCookiesEqual, except domain and path are optional.
        if (cookieMatches(cookie, params.name, domain, path)) {
            cookies.swapRemove(index).deinit();
        }
    }
    return cmd.sendResult(null, .{});
}

fn clearBrowserCookies(cmd: *CDP.Command) !void {
    if (try cmd.params(struct {}) != null) return error.InvalidParams;
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.session.cookie_jar.clearRetainingCapacity();
    return cmd.sendResult(null, .{});
}

fn setCookie(cmd: *CDP.Command) !void {
    const params = (try cmd.params(
        CdpStorage.CdpCookie,
    )) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try CdpStorage.setCdpCookie(&bc.session.cookie_jar, params);

    try cmd.sendResult(.{ .success = true }, .{});
}

fn setCookies(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        cookies: []const CdpStorage.CdpCookie,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    for (params.cookies) |param| {
        try CdpStorage.setCdpCookie(&bc.session.cookie_jar, param);
    }

    try cmd.sendResult(null, .{});
}

const GetCookiesParam = struct {
    urls: ?[]const [:0]const u8 = null,
};
fn getCookies(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(GetCookiesParam)) orelse GetCookiesParam{};

    // If not specified, use the URLs of the page and all of its subframes. TODO subframes
    const page_url = if (bc.session.page) |page| page.url else null;
    const param_urls = params.urls orelse &[_][:0]const u8{page_url orelse return error.InvalidParams};

    var urls = try std.ArrayList(CdpStorage.PreparedUri).initCapacity(cmd.arena, param_urls.len);
    for (param_urls) |url| {
        urls.appendAssumeCapacity(.{
            .host = try Cookie.parseDomain(cmd.arena, url, null),
            .path = try Cookie.parsePath(cmd.arena, url, null),
            .secure = URL.isHTTPS(url),
        });
    }

    var jar = &bc.session.cookie_jar;
    jar.removeExpired(null);
    const writer = CdpStorage.CookieWriter{ .cookies = jar.cookies.items, .urls = urls.items };
    try cmd.sendResult(.{ .cookies = writer }, .{});
}

fn getResponseBody(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        requestId: []const u8, // "REQ-{d}"
    })) orelse return error.InvalidParams;

    const request_id = try idFromRequestId(params.requestId);
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const resp = bc.captured_responses.getPtr(request_id) orelse return error.RequestNotFound;

    if (!resp.must_encode) {
        return cmd.sendResult(.{
            .body = resp.data.items,
            .base64Encoded = false,
        }, .{});
    }

    const encoded_len = std.base64.standard.Encoder.calcSize(resp.data.items.len);
    const encoded = try cmd.arena.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, resp.data.items);

    return cmd.sendResult(.{
        .body = encoded,
        .base64Encoded = true,
    }, .{});
}

fn getRequestPostData(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        requestId: []const u8, // "REQ-{d}"
    })) orelse return error.InvalidParams;

    const request_id = try idFromRequestId(params.requestId);
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const req = bc.captured_requests.getPtr(request_id) orelse {
        return cmd.sendError(-32000, "No resource with given id was found", .{});
    };

    const body = req.body orelse {
        return cmd.sendError(-32000, "No post data available for the request", .{});
    };

    if (std.unicode.utf8ValidateSlice(body)) {
        return cmd.sendResult(.{
            .postData = body,
            .base64Encoded = false,
        }, .{});
    }

    const encoded_len = std.base64.standard.Encoder.calcSize(body.len);
    const encoded = try cmd.arena.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, body);

    return cmd.sendResult(.{
        .postData = encoded,
        .base64Encoded = true,
    }, .{});
}

pub fn httpRequestFail(bc: *CDP.BrowserContext, msg: *const Notification.RequestFail) !void {
    // It's possible that the request failed because we aborted when the client
    // sent Target.closeTarget. In that case, bc.session_id will be cleared
    // already, and we can skip sending these messages to the client.
    const session_id = bc.session_id orelse return;

    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    lp.assert(bc.session.page != null, "CDP.network.httpRequestFail null page", .{});

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.loadingFailed", .{
        .requestId = &id.toRequestId(msg.transfer.id),
        // Seems to be what chrome answers with. I assume it depends on the type of error?
        .type = "Ping",
        .errorText = msg.err,
        .canceled = false,
    }, .{ .session_id = session_id });
}

pub fn httpRequestStart(bc: *CDP.BrowserContext, msg: *const Notification.RequestStart) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const transfer = msg.transfer;
    const req = &transfer.req;
    const frame_id = req.frame_id;
    const page = bc.session.findPageByFrameId(frame_id) orelse return;
    const arena = bc.notification_arena;

    // Modify request with extra CDP headers
    for (bc.extra_headers.items) |extra| {
        try req.headers.add(extra);
    }

    const captured_request = try captureRequest(bc, transfer);

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.requestWillBeSent", .{
        .loaderId = &id.toLoaderId(transfer.id),
        .requestId = &id.toRequestId(transfer.id),
        .frameId = &id.toFrameId(frame_id),
        .type = req.resource_type.string(),
        .documentURL = page.url,
        .request = TransferAsRequestWriter.init(arena, transfer, captured_request),
        .initiator = .{ .type = "other" },
        .redirectHasExtraInfo = false, // TODO change after adding Network.requestWillBeSentExtraInfo
        .hasUserGesture = false,
    }, .{ .session_id = session_id });
}

pub fn httpResponseHeaderDone(arena: Allocator, bc: *CDP.BrowserContext, msg: *const Notification.ResponseHeaderDone) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const transfer = msg.transfer;

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.responseReceived", .{
        .loaderId = &id.toLoaderId(transfer.id),
        .requestId = &id.toRequestId(transfer.id),
        .frameId = &id.toFrameId(transfer.req.frame_id),
        .response = TransferAsResponseWriter.init(arena, msg.transfer),
        .hasExtraInfo = false, // TODO change after adding Network.responseReceivedExtraInfo
    }, .{ .session_id = session_id });
}

pub fn httpRequestDone(bc: *CDP.BrowserContext, msg: *const Notification.RequestDone) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;
    const transfer = msg.transfer;
    try bc.cdp.sendEvent("Network.loadingFinished", .{
        .requestId = &id.toRequestId(transfer.id),
        .encodedDataLength = transfer.bytes_received,
    }, .{ .session_id = session_id });
}

fn captureRequest(bc: *CDP.BrowserContext, transfer: *Transfer) !?*const CDP.BrowserContext.CapturedRequest {
    const body = if (transfer.req.body) |request_body|
        try bc.page_arena.dupe(u8, request_body)
    else
        null;

    const has_post_data = body != null;
    const inline_in_events = if (!has_post_data)
        false
    else if (bc.network_max_post_data_size) |max_post_data_size|
        body.?.len <= max_post_data_size
    else
        true;

    const gop = try bc.captured_requests.getOrPut(bc.page_arena, transfer.id);
    gop.value_ptr.* = .{
        .has_post_data = has_post_data,
        .body = body,
        .inline_in_events = inline_in_events,
    };
    return gop.value_ptr;
}

fn encodeBytesAsLatin1Utf8(allocator: Allocator, input: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, input.len * 2);
    defer out.deinit(allocator);

    for (input) |byte| {
        if (byte <= 0x7F) {
            out.appendAssumeCapacity(byte);
            continue;
        }

        try out.append(allocator, 0xC0 | (byte >> 6));
        try out.append(allocator, 0x80 | (byte & 0x3F));
    }

    return out.toOwnedSlice(allocator);
}

fn encodeBase64(allocator: Allocator, input: []const u8) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(input.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, input);
    return encoded;
}

pub const TransferAsRequestWriter = struct {
    arena: Allocator,
    transfer: *Transfer,
    captured_request: ?*const CDP.BrowserContext.CapturedRequest,

    pub fn init(arena: Allocator, transfer: *Transfer, captured_request: ?*const CDP.BrowserContext.CapturedRequest) TransferAsRequestWriter {
        return .{
            .arena = arena,
            .transfer = transfer,
            .captured_request = captured_request,
        };
    }

    pub fn jsonStringify(self: *const TransferAsRequestWriter, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }
    fn _jsonStringify(self: *const TransferAsRequestWriter, jws: anytype) !void {
        const transfer = self.transfer;
        const captured_request = self.captured_request;

        try jws.beginObject();
        {
            try jws.objectField("url");
            try jws.write(transfer.url);
        }

        {
            const frag = URL.getHash(transfer.url);
            if (frag.len > 0) {
                try jws.objectField("urlFragment");
                try jws.write(frag);
            }
        }

        {
            try jws.objectField("method");
            try jws.write(@tagName(transfer.req.method));
        }

        {
            try jws.objectField("hasPostData");
            try jws.write(if (captured_request) |request| request.has_post_data else transfer.req.body != null);
        }

        if (captured_request) |request| {
            if (request.inline_in_events) {
                if (request.body) |body| {
                    try jws.objectField("postData");
                    if (std.unicode.utf8ValidateSlice(body)) {
                        try jws.write(body);
                    } else {
                        try jws.write(try encodeBytesAsLatin1Utf8(self.arena, body));
                    }

                    try jws.objectField("postDataEntries");
                    try jws.beginArray();
                    try jws.beginObject();
                    try jws.objectField("bytes");
                    try jws.write(try encodeBase64(self.arena, body));
                    try jws.endObject();
                    try jws.endArray();
                }
            }
        }

        {
            try jws.objectField("headers");
            try jws.beginObject();
            var it = transfer.req.headers.iterator();
            while (it.next()) |hdr| {
                try jws.objectField(hdr.name);
                try jws.write(hdr.value);
            }
            if (try transfer.getCookieString()) |cookies| {
                try jws.objectField("Cookie");
                try jws.write(cookies[0 .. cookies.len - 1]);
            }
            try jws.endObject();
        }
        try jws.endObject();
    }
};

const TransferAsResponseWriter = struct {
    arena: Allocator,
    transfer: *Transfer,

    fn init(arena: Allocator, transfer: *Transfer) TransferAsResponseWriter {
        return .{
            .arena = arena,
            .transfer = transfer,
        };
    }

    pub fn jsonStringify(self: *const TransferAsResponseWriter, jws: anytype) !void {
        self._jsonStringify(jws) catch return error.WriteFailed;
    }

    fn _jsonStringify(self: *const TransferAsResponseWriter, jws: anytype) !void {
        const transfer = self.transfer;

        try jws.beginObject();
        {
            try jws.objectField("url");
            try jws.write(transfer.url);
        }

        if (transfer.response_header) |*rh| {
            // it should not be possible for this to be false, but I'm not
            // feeling brave today.
            const status = rh.status;
            try jws.objectField("status");
            try jws.write(status);

            try jws.objectField("statusText");
            try jws.write(@as(std.http.Status, @enumFromInt(status)).phrase() orelse "Unknown");
        }

        {
            const mime: Mime = blk: {
                if (transfer.response_header.?.contentType()) |ct| {
                    break :blk try Mime.parse(ct);
                }
                break :blk .unknown;
            };

            try jws.objectField("mimeType");
            try jws.write(mime.contentTypeString());
            try jws.objectField("charset");
            try jws.write(mime.charsetString());
        }

        {
            // chromedp doesn't like having duplicate header names. It's pretty
            // common to get these from a server (e.g. for Cache-Control), but
            // Chrome joins these. So we have to too.
            const arena = self.arena;
            var it = transfer.responseHeaderIterator();
            var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            while (it.next()) |hdr| {
                const gop = try map.getOrPut(arena, hdr.name);
                if (gop.found_existing) {
                    // yes, chrome joins multi-value headers with a \n
                    gop.value_ptr.* = try std.mem.join(arena, "\n", &.{ gop.value_ptr.*, hdr.value });
                } else {
                    gop.value_ptr.* = hdr.value;
                }
            }

            try jws.objectField("headers");
            try jws.write(std.json.ArrayHashMap([]const u8){ .map = map });
        }
        try jws.endObject();
    }
};

fn idFromRequestId(request_id: []const u8) !u64 {
    if (!std.mem.startsWith(u8, request_id, "REQ-")) {
        return error.InvalidParams;
    }
    return std.fmt.parseInt(u64, request_id[4..], 10) catch return error.InvalidParams;
}

const testing = @import("../testing.zig");

const TestRequestContext = struct {
    allocator: Allocator,
    response_body: std.ArrayList(u8),
    done: bool = false,
    err: ?anyerror = null,

    fn init(allocator: Allocator) TestRequestContext {
        return .{
            .allocator = allocator,
            .response_body = .empty,
        };
    }

    fn deinit(self: *TestRequestContext) void {
        self.response_body.deinit(self.allocator);
    }

    fn headerCallback(_: HttpClient.Response) !bool {
        return true;
    }

    fn dataCallback(response: HttpClient.Response, data: []const u8) !void {
        const self: *TestRequestContext = @ptrCast(@alignCast(response.ctx));
        try self.response_body.appendSlice(self.allocator, data);
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *TestRequestContext = @ptrCast(@alignCast(ctx));
        self.done = true;
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *TestRequestContext = @ptrCast(@alignCast(ctx));
        self.err = err;
        self.done = true;
    }
};

fn sendTestRequest(
    bc: *CDP.BrowserContext,
    method: HttpClient.Method,
    path: []const u8,
    body: ?[]const u8,
    ctx: *TestRequestContext,
) !void {
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    const http_client = bc.session.browser.http_client;
    const headers = try http_client.newHeaders();
    const url = try std.fmt.allocPrintSentinel(bc.page_arena, "http://127.0.0.1:9582{s}", .{path}, 0);

    try http_client.request(.{
        .ctx = ctx,
        .url = url,
        .method = method,
        .headers = headers,
        .frame_id = page._frame_id,
        .body = body,
        .cookie_jar = &page._session.cookie_jar,
        .cookie_origin = page.url,
        .resource_type = .fetch,
        .notification = page._session.notification,
        .header_callback = TestRequestContext.headerCallback,
        .data_callback = TestRequestContext.dataCallback,
        .done_callback = TestRequestContext.doneCallback,
        .error_callback = TestRequestContext.errorCallback,
    });
}

fn waitForRequest(bc: *CDP.BrowserContext, ctx: *TestRequestContext) !void {
    var runner = try bc.session.runner(.{});
    var timer = try std.time.Timer.start();

    while (!ctx.done) {
        if (timer.read() >= 5 * std.time.ns_per_s) {
            return error.Timeout;
        }

        switch (try runner.tick(.{ .ms = 100 })) {
            .done => {},
            .ok => |recommended_sleep_ms| {
                if (recommended_sleep_ms > 0) {
                    std.Thread.sleep(recommended_sleep_ms * std.time.ns_per_ms);
                }
            },
        }
    }

    if (ctx.err) |err| {
        return err;
    }
}

fn findEventByMethodAndUrl(ctx: anytype, method: []const u8, url: []const u8) !std.json.Value {
    for (ctx.received.items) |message| {
        const message_method = message.object.get("method") orelse continue;
        if (!std.mem.eql(u8, message_method.string, method)) continue;

        const params = message.object.get("params") orelse continue;
        const request = params.object.get("request") orelse continue;
        const request_url = request.object.get("url") orelse continue;
        if (std.mem.eql(u8, request_url.string, url)) {
            return message;
        }
    }
    return error.ErrorNotFound;
}

fn eventRequestId(message: std.json.Value) []const u8 {
    return message.object.get("params").?.object.get("requestId").?.string;
}

test "cdp.network setExtraHTTPHeaders" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "NID-A", .session_id = "NESI-A" });
    // try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about/blank" } });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .foo = "bar" } },
    });

    try ctx.processMessage(.{
        .id = 4,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .food = "bars" } },
    });

    const bc = ctx.cdp().browser_context.?;
    try testing.expectEqual(bc.extra_headers.items.len, 1);
}

test "cdp.Network: cookies" {
    const ResCookie = CdpStorage.ResCookie;
    const CdpCookie = CdpStorage.CdpCookie;

    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-S" });

    // Initially empty
    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.getCookies",
        .params = .{ .urls = &[_][]const u8{"https://example.com/pancakes"} },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 3 });

    // Has cookies after setting them
    try ctx.processMessage(.{
        .id = 4,
        .method = "Network.setCookie",
        .params = CdpCookie{ .name = "test3", .value = "valuenot3", .url = "https://car.example.com/defnotpancakes" },
    });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try ctx.processMessage(.{
        .id = 5,
        .method = "Network.setCookies",
        .params = .{
            .cookies = &[_]CdpCookie{
                .{ .name = "test3", .value = "value3", .url = "https://car.example.com/pan/cakes" },
                .{ .name = "test4", .value = "value4", .domain = "example.com", .path = "/mango" },
            },
        },
    });
    try ctx.expectSentResult(null, .{ .id = 5 });
    try ctx.processMessage(.{
        .id = 6,
        .method = "Network.getCookies",
        .params = .{ .urls = &[_][]const u8{"https://car.example.com/pan/cakes"} },
    });
    try ctx.expectSentResult(.{
        .cookies = &[_]ResCookie{
            .{ .name = "test3", .value = "value3", .domain = "car.example.com", .path = "/", .size = 11, .secure = true }, // No Pancakes!
        },
    }, .{ .id = 6 });

    // deleteCookies
    try ctx.processMessage(.{
        .id = 7,
        .method = "Network.deleteCookies",
        .params = .{ .name = "test3", .domain = "car.example.com" },
    });
    try ctx.expectSentResult(null, .{ .id = 7 });
    try ctx.processMessage(.{
        .id = 8,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    // Just the untouched test4 should be in the result
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{.{ .name = "test4", .value = "value4", .domain = ".example.com", .path = "/mango", .size = 11 }} }, .{ .id = 8 });

    // Empty after clearBrowserCookies
    try ctx.processMessage(.{
        .id = 9,
        .method = "Network.clearBrowserCookies",
    });
    try ctx.expectSentResult(null, .{ .id = 9 });
    try ctx.processMessage(.{
        .id = 10,
        .method = "Storage.getCookies",
        .params = .{ .browserContextId = "BID-S" },
    });
    try ctx.expectSentResult(.{ .cookies = &[_]ResCookie{} }, .{ .id = 10 });
}

test "cdp.Network: request post data utf8 and size limit" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-N", .session_id = "SID-N", .url = "cdp/dom1.html" });
    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
        .params = .{ .maxPostDataSize = 4 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var request_ctx = TestRequestContext.init(testing.allocator);
    defer request_ctx.deinit();

    const url = "http://127.0.0.1:9582/xhr";
    const body = try testing.allocator.dupe(u8, "abcdef");
    defer testing.allocator.free(body);
    const encoded_body = try encodeBase64(testing.allocator, body);
    defer testing.allocator.free(encoded_body);

    try sendTestRequest(bc, .POST, "/xhr", body, &request_ctx);

    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .request = .{
            .url = url,
            .hasPostData = true,
        },
    }, .{});

    try waitForRequest(bc, &request_ctx);

    const request_event = try findEventByMethodAndUrl(&ctx, "Network.requestWillBeSent", url);
    const request_id = eventRequestId(request_event);
    try ctx.expectSentEvent("Network.loadingFinished", .{
        .requestId = request_id,
    }, .{});

    const request = request_event.object.get("params").?.object.get("request").?;
    try testing.expect(request.object.get("postData") == null);
    try testing.expect(request.object.get("postDataEntries") == null);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = request_id },
    });
    try ctx.expectSentResult(.{
        .postData = body,
        .base64Encoded = false,
    }, .{ .id = 2 });

    try testing.expect(!std.mem.eql(u8, encoded_body, body));
}

test "cdp.Network: request post data binary" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-B", .session_id = "SID-B", .url = "cdp/dom1.html" });
    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
        .params = .{ .maxPostDataSize = 64 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var request_ctx = TestRequestContext.init(testing.allocator);
    defer request_ctx.deinit();

    const body = try testing.allocator.dupe(u8, &[_]u8{ 0, 0xFF, 1 });
    defer testing.allocator.free(body);
    const latin1_utf8 = try testing.allocator.dupe(u8, &[_]u8{ 0, 0xC3, 0xBF, 1 });
    defer testing.allocator.free(latin1_utf8);
    const encoded_body = try encodeBase64(testing.allocator, body);
    defer testing.allocator.free(encoded_body);

    try sendTestRequest(bc, .POST, "/xhr", body, &request_ctx);

    const url = "http://127.0.0.1:9582/xhr";
    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .request = .{
            .url = url,
            .hasPostData = true,
            .postData = latin1_utf8,
            .postDataEntries = &[_]struct { bytes: []const u8 }{
                .{ .bytes = encoded_body },
            },
        },
    }, .{});

    try waitForRequest(bc, &request_ctx);

    const request_event = try findEventByMethodAndUrl(&ctx, "Network.requestWillBeSent", url);
    const request_id = eventRequestId(request_event);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = request_id },
    });
    try ctx.expectSentResult(.{
        .postData = encoded_body,
        .base64Encoded = true,
    }, .{ .id = 2 });
}

test "cdp.Network: getRequestPostData missing and no body" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-G", .session_id = "SID-G", .url = "cdp/dom1.html" });
    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var request_ctx = TestRequestContext.init(testing.allocator);
    defer request_ctx.deinit();

    const url = "http://127.0.0.1:9582/xhr";
    try sendTestRequest(bc, .GET, "/xhr", null, &request_ctx);

    try ctx.expectSentEvent("Network.requestWillBeSent", .{
        .request = .{
            .url = url,
            .hasPostData = false,
        },
    }, .{});

    try waitForRequest(bc, &request_ctx);

    const request_event = try findEventByMethodAndUrl(&ctx, "Network.requestWillBeSent", url);
    const request_id = eventRequestId(request_event);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = request_id },
    });
    try ctx.expectSentError(-32000, "No post data available for the request", .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = "REQ-9999999999" },
    });
    try ctx.expectSentError(-32000, "No resource with given id was found", .{ .id = 3 });
}

test "cdp.Network: captured request snapshot survives body mutation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-I", .session_id = "SID-I", .url = "cdp/dom1.html" });
    try ctx.processMessage(.{
        .id = 1,
        .method = "Network.enable",
        .params = .{ .maxPostDataSize = 64 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    var transfer_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer transfer_arena.deinit();

    const page = bc.session.currentPage() orelse unreachable;
    const original_body = "orig-body";
    const modified_body = "changed-body";
    const encoded_original = try encodeBase64(testing.allocator, original_body);
    defer testing.allocator.free(encoded_original);

    var transfer = Transfer{
        .arena = transfer_arena,
        .id = 42,
        .req = .{
            .frame_id = page._frame_id,
            .method = .POST,
            .url = "http://127.0.0.1:9582/xhr/echo",
            .headers = try bc.session.browser.http_client.newHeaders(),
            .body = original_body,
            .cookie_jar = &page._session.cookie_jar,
            .cookie_origin = page.url,
            .resource_type = .fetch,
            .notification = page._session.notification,
            .ctx = undefined,
            .header_callback = TestRequestContext.headerCallback,
            .data_callback = TestRequestContext.dataCallback,
            .done_callback = TestRequestContext.doneCallback,
            .error_callback = TestRequestContext.errorCallback,
        },
        .url = "http://127.0.0.1:9582/xhr/echo",
        .client = bc.session.browser.http_client,
    };
    defer transfer.req.headers.deinit();

    const captured_request = (try captureRequest(bc, &transfer)).?;
    transfer.req.body = modified_body;

    var writer_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer writer_arena.deinit();
    const writer_json = try std.json.Stringify.valueAlloc(writer_arena.allocator(), TransferAsRequestWriter.init(writer_arena.allocator(), &transfer, captured_request), .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const writer_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), writer_json, .{});
    const post_data = writer_value.object.get("postData").?.string;
    const post_data_entries = writer_value.object.get("postDataEntries").?.array.items;
    try testing.expectEqual(original_body, post_data);
    try testing.expectEqual(1, post_data_entries.len);
    try testing.expectEqual(encoded_original, post_data_entries[0].object.get("bytes").?.string);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Network.getRequestPostData",
        .params = .{ .requestId = "REQ-42" },
    });
    try ctx.expectSentResult(.{
        .postData = original_body,
        .base64Encoded = false,
    }, .{ .id = 2 });
}
