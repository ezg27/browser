// Copyright (C) 2023-2025    Lightpanda (Selecy SAS)
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

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");
const log = @import("../../log.zig");

const HttpClient = @import("../../browser/HttpClient.zig");
const Page = @import("../../browser/Page.zig");
const http = @import("../../network/http.zig");
const Notification = @import("../../Notification.zig");

const network = @import("network.zig");
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        disable,
        enable,
        continueRequest,
        failRequest,
        fulfillRequest,
        continueWithAuth,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .disable => return disable(cmd),
        .enable => return enable(cmd),
        .continueRequest => return continueRequest(cmd),
        .continueWithAuth => return continueWithAuth(cmd),
        .failRequest => return failRequest(cmd),
        .fulfillRequest => return fulfillRequest(cmd),
    }
}

// Stored in CDP
pub const InterceptState = struct {
    allocator: Allocator,
    waiting: std.AutoArrayHashMapUnmanaged(u32, *HttpClient.Transfer),

    pub fn init(allocator: Allocator) !InterceptState {
        return .{
            .waiting = .empty,
            .allocator = allocator,
        };
    }

    pub fn empty(self: *const InterceptState) bool {
        return self.waiting.count() == 0;
    }

    pub fn put(self: *InterceptState, fetch_request_id: u32, transfer: *HttpClient.Transfer) !void {
        return self.waiting.put(self.allocator, fetch_request_id, transfer);
    }

    pub fn remove(self: *InterceptState, request_id: u32) ?*HttpClient.Transfer {
        const entry = self.waiting.fetchSwapRemove(request_id) orelse return null;
        return entry.value;
    }

    pub fn deinit(self: *InterceptState) void {
        self.waiting.deinit(self.allocator);
    }

    pub fn pendingTransfers(self: *const InterceptState) []*HttpClient.Transfer {
        return self.waiting.values();
    }
};

const RequestPattern = struct {
    // Wildcards ('*' -> zero or more, '?' -> exactly one) are allowed.
    // Escape character is backslash. Omitting is equivalent to "*".
    urlPattern: []const u8 = "*",
    resourceType: ?ResourceType = null,
    requestStage: RequestStage = .Request,
};
const ResourceType = enum {
    Document,
    Stylesheet,
    Image,
    Media,
    Font,
    Script,
    TextTrack,
    XHR,
    Fetch,
    Prefetch,
    EventSource,
    WebSocket,
    Manifest,
    SignedExchange,
    Ping,
    CSPViolationReport,
    Preflight,
    FedCM,
    Other,
};
const RequestStage = enum {
    Request,
    Response,
};

const EnableParam = struct {
    patterns: []RequestPattern = &.{},
    handleAuthRequests: bool = false,
};
const ErrorReason = enum {
    Failed,
    Aborted,
    TimedOut,
    AccessDenied,
    ConnectionClosed,
    ConnectionReset,
    ConnectionRefused,
    ConnectionAborted,
    ConnectionFailed,
    NameNotResolved,
    InternetDisconnected,
    AddressUnreachable,
    BlockedByClient,
    BlockedByResponse,
};

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.fetchDisable();
    return cmd.sendResult(null, .{});
}

fn enable(cmd: *CDP.Command) !void {
    const params = (try cmd.params(EnableParam)) orelse EnableParam{};
    if (!arePatternsSupported(params.patterns)) {
        log.warn(.not_implemented, "Fetch.enable", .{ .params = "pattern" });
        return cmd.sendResult(null, .{});
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.fetchEnable(params.handleAuthRequests);

    return cmd.sendResult(null, .{});
}

fn arePatternsSupported(patterns: []RequestPattern) bool {
    if (patterns.len == 0) {
        return true;
    }
    if (patterns.len > 1) {
        return false;
    }

    // While we don't support patterns, yet, both Playwright and Puppeteer send
    // a default pattern which happens to be what we support:
    // [{"urlPattern":"*","requestStage":"Request"}]
    // So, rather than erroring on this case because we don't support patterns,
    // we'll allow it, because this pattern is how it works as-is.
    const pattern = patterns[0];
    if (!std.mem.eql(u8, pattern.urlPattern, "*")) {
        return false;
    }
    if (pattern.resourceType != null) {
        return false;
    }
    if (pattern.requestStage != .Request) {
        return false;
    }
    return true;
}

pub fn requestIntercept(bc: *CDP.BrowserContext, intercept: *const Notification.RequestIntercept) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous page's requests?

    const transfer = intercept.transfer;
    try bc.intercept_state.put(intercept.fetch_request_id, transfer);
    var redirected_request_id: [14]u8 = undefined;
    const redirected_request_id_ptr = if (intercept.redirected_from_fetch_request_id) |request_id| blk: {
        redirected_request_id = id.toInterceptId(request_id);
        break :blk &redirected_request_id;
    } else null;

    try bc.cdp.sendEvent("Fetch.requestPaused", .{
        .requestId = &id.toInterceptId(intercept.fetch_request_id),
        .frameId = &id.toFrameId(transfer.req.frame_id),
        .request = network.TransferAsRequestWriter.init(transfer),
        .resourceType = switch (transfer.req.resource_type) {
            .script => "Script",
            .xhr => "XHR",
            .document => "Document",
            .fetch => "Fetch",
        },
        .networkId = &id.toRequestId(transfer.id), // matches the Network REQ-ID
        .redirectedRequestId = redirected_request_id_ptr,
    }, .{ .session_id = session_id });

    log.debug(.cdp, "request intercept", .{
        .state = "paused",
        .id = transfer.id,
        .url = transfer.url,
    });
    // Await either continueRequest, failRequest or fulfillRequest

    intercept.wait_for_interception.* = true;
}

fn continueRequest(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // INT-{d}"
        url: ?[]const u8 = null,
        method: ?[]const u8 = null,
        postData: ?[]const u8 = null,
        headers: ?[]const http.Header = null,
        interceptResponse: bool = false,
    })) orelse return error.InvalidParams;

    if (params.interceptResponse) {
        return error.NotImplemented;
    }

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);
    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;

    log.debug(.cdp, "request intercept", .{
        .state = "continue",
        .id = transfer.id,
        .url = transfer.url,
        .new_url = params.url,
    });

    const arena = transfer.arena.allocator();
    // Update the request with the new parameters
    if (params.url) |url| {
        try transfer.updateURL(try arena.dupeZ(u8, url));
    }
    if (params.method) |method| {
        transfer.req.method = std.meta.stringToEnum(http.Method, method) orelse return error.InvalidParams;
    }

    if (params.headers) |headers| {
        // Not obvious, but cmd.arena is safe here, since the headers will get
        // duped by libcurl. transfer.arena is more obvious/safe, but cmd.arena
        // is more efficient (it's re-used)
        try transfer.replaceRequestHeaders(cmd.arena, headers);
    }

    if (params.postData) |b| {
        const decoder = std.base64.standard.Decoder;
        const body = try arena.alloc(u8, try decoder.calcSizeForSlice(b));
        try decoder.decode(body, b);
        transfer.req.body = body;
    }

    try bc.cdp.browser.http_client.continueTransfer(transfer);
    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Fetch/#type-AuthChallengeResponse
const AuthChallengeResponse = enum {
    Default,
    CancelAuth,
    ProvideCredentials,
};

fn continueWithAuth(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
        authChallengeResponse: struct {
            response: AuthChallengeResponse,
            username: []const u8 = "",
            password: []const u8 = "",
        },
    })) orelse return error.InvalidParams;

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);
    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;

    log.debug(.cdp, "request intercept", .{
        .state = "continue with auth",
        .id = transfer.id,
        .response = params.authChallengeResponse.response,
    });

    if (params.authChallengeResponse.response != .ProvideCredentials) {
        transfer.abortAuthChallenge();
        return cmd.sendResult(null, .{});
    }

    // cancel the request, deinit the transfer on error.
    errdefer transfer.abortAuthChallenge();

    // restart the request with the provided credentials.
    const arena = transfer.arena.allocator();
    transfer.updateCredentials(
        try std.fmt.allocPrintSentinel(arena, "{s}:{s}", .{
            params.authChallengeResponse.username,
            params.authChallengeResponse.password,
        }, 0),
    );

    transfer.reset();
    try bc.cdp.browser.http_client.continueTransfer(transfer);
    return cmd.sendResult(null, .{});
}

fn fulfillRequest(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
        responseCode: u16,
        responseHeaders: ?[]const http.Header = null,
        binaryResponseHeaders: ?[]const u8 = null,
        body: ?[]const u8 = null,
        responsePhrase: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.binaryResponseHeaders != null) {
        log.warn(.not_implemented, "Fetch.fulfillRequest", .{ .param = "binaryResponseHeaders" });
        return error.NotImplemented;
    }

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);
    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;

    log.debug(.cdp, "request intercept", .{
        .state = "fulfilled",
        .id = transfer.id,
        .url = transfer.url,
        .status = params.responseCode,
        .body = params.body != null,
    });

    var body: ?[]const u8 = null;
    if (params.body) |b| {
        const decoder = std.base64.standard.Decoder;
        const buf = try transfer.arena.allocator().alloc(u8, try decoder.calcSizeForSlice(b));
        try decoder.decode(buf, b);
        body = buf;
    }

    try bc.cdp.browser.http_client.fulfillTransfer(transfer, params.responseCode, params.responseHeaders orelse &.{}, body);

    return cmd.sendResult(null, .{});
}

fn failRequest(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const params = (try cmd.params(struct {
        requestId: []const u8, // "INT-{d}"
        errorReason: ErrorReason,
    })) orelse return error.InvalidParams;

    var intercept_state = &bc.intercept_state;
    const request_id = try idFromRequestId(params.requestId);

    const transfer = intercept_state.remove(request_id) orelse return error.RequestNotFound;
    defer bc.cdp.browser.http_client.abortTransfer(transfer);

    log.info(.cdp, "request intercept", .{
        .state = "fail",
        .id = request_id,
        .url = transfer.url,
        .reason = params.errorReason,
    });
    return cmd.sendResult(null, .{});
}

pub fn requestAuthRequired(bc: *CDP.BrowserContext, intercept: *const Notification.RequestAuthRequired) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    // We keep it around to wait for modifications to the request.
    // NOTE: we assume whomever created the request created it with a lifetime of the Page.
    // TODO: What to do when receiving replies for a previous page's requests?

    const transfer = intercept.transfer;
    try bc.intercept_state.put(transfer.fetch_request_id, transfer);

    const challenge = transfer._auth_challenge orelse return error.NullAuthChallenge;

    try bc.cdp.sendEvent("Fetch.authRequired", .{
        .requestId = &id.toInterceptId(transfer.fetch_request_id),
        .frameId = &id.toFrameId(transfer.req.frame_id),
        .request = network.TransferAsRequestWriter.init(transfer),
        .resourceType = switch (transfer.req.resource_type) {
            .script => "Script",
            .xhr => "XHR",
            .document => "Document",
            .fetch => "Fetch",
        },
        .authChallenge = .{
            .origin = "", // TODO get origin, could be the proxy address for example.
            .source = if (challenge.source) |s| (if (s == .server) "Server" else "Proxy") else "",
            .scheme = if (challenge.scheme) |s| (if (s == .digest) "digest" else "basic") else "",
            .realm = challenge.realm orelse "",
        },
        .networkId = &id.toRequestId(transfer.id),
    }, .{ .session_id = session_id });

    log.debug(.cdp, "request auth required", .{
        .state = "paused",
        .id = transfer.id,
        .url = transfer.url,
    });
    // Await continueWithAuth

    intercept.wait_for_interception.* = true;
}

// Get u32 from requestId which is formatted as: "INT-{d}"
fn idFromRequestId(request_id: []const u8) !u32 {
    if (!std.mem.startsWith(u8, request_id, "INT-")) {
        return error.InvalidParams;
    }
    return std.fmt.parseInt(u32, request_id[4..], 10) catch return error.InvalidParams;
}

const testing = @import("../testing.zig");

const RequestState = struct {
    done: bool = false,
    err: ?anyerror = null,
};

fn testHeaderCallback(_: HttpClient.Response) !bool {
    return true;
}

fn testDataCallback(_: HttpClient.Response, _: []const u8) !void {}

fn testDoneCallback(ctx: *anyopaque) !void {
    const state: *RequestState = @ptrCast(@alignCast(ctx));
    state.done = true;
}

fn testErrorCallback(ctx: *anyopaque, err: anyerror) void {
    const state: *RequestState = @ptrCast(@alignCast(ctx));
    state.err = err;
}

fn issueRequest(
    page: *Page,
    state: *RequestState,
    url: [:0]const u8,
    method: HttpClient.Method,
    body: ?[]const u8,
    blocking: bool,
) !void {
    const http_client = page._session.browser.http_client;
    var headers = try http_client.newHeaders();
    try headers.add("X-Base: original");

    try http_client.request(.{
        .ctx = state,
        .url = url,
        .method = method,
        .body = body,
        .headers = headers,
        .frame_id = page._frame_id,
        .resource_type = .fetch,
        .cookie_jar = &page._session.cookie_jar,
        .cookie_origin = page.url,
        .notification = page._session.notification,
        .blocking = blocking,
        .header_callback = testHeaderCallback,
        .data_callback = testDataCallback,
        .done_callback = testDoneCallback,
        .error_callback = testErrorCallback,
    });
}

fn waitForRequest(bc: *CDP.BrowserContext, state: *RequestState) !void {
    var runner = try bc.session.runner(.{});
    var attempts: usize = 0;
    while (!state.done and state.err == null and attempts < 20) : (attempts += 1) {
        _ = try runner.tick(.{ .ms = 100 });
    }

    if (state.err) |err| return err;
    if (!state.done) return error.Timeout;
}

fn jsonField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn findFetchPausedEvent(ctx: anytype, request_id: []const u8) ?std.json.Value {
    for (ctx.received.items) |event| {
        const method = jsonField(event, "method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "Fetch.requestPaused")) continue;

        const params = jsonField(event, "params") orelse continue;
        const paused_id = jsonField(params, "requestId") orelse continue;
        if (paused_id != .string or !std.mem.eql(u8, paused_id.string, request_id)) continue;
        return event;
    }
    return null;
}

test "cdp.Fetch: emits requestPaused for each redirect hop" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-FRED",
        .session_id = "SID-FRED",
        .target_id = "TID-0000000101".*,
    });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{ .id = 30, .method = "Fetch.enable", .sessionId = "SID-FRED" });
    try ctx.expectSentResult(null, .{ .id = 30, .session_id = "SID-FRED" });

    var state = RequestState{};
    try issueRequest(page, &state, "http://127.0.0.1:9582/xhr/redirect", .GET, null, false);

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .networkId = "REQ-0000000001",
        .request = .{ .url = "http://127.0.0.1:9582/xhr/redirect" },
    }, .{ .session_id = "SID-FRED" });

    try ctx.processMessage(.{
        .id = 31,
        .method = "Fetch.continueRequest",
        .sessionId = "SID-FRED",
        .params = .{ .requestId = "INT-0000000001" },
    });
    try ctx.expectSentResult(null, .{ .id = 31, .session_id = "SID-FRED" });

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .redirectedRequestId = "INT-0000000001",
        .networkId = "REQ-0000000001",
        .request = .{ .url = "http://127.0.0.1:9582/xhr" },
    }, .{ .session_id = "SID-FRED" });

    try ctx.processMessage(.{
        .id = 32,
        .method = "Fetch.continueRequest",
        .sessionId = "SID-FRED",
        .params = .{ .requestId = "INT-0000000002" },
    });
    try ctx.expectSentResult(null, .{ .id = 32, .session_id = "SID-FRED" });

    try waitForRequest(bc, &state);
}

test "cdp.Fetch: emits requestPaused for multi-hop redirects" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-FRED2",
        .session_id = "SID-FRED2",
        .target_id = "TID-0000000102".*,
    });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 33,
        .method = "Fetch.enable",
        .sessionId = "SID-FRED2",
    });
    try ctx.expectSentResult(null, .{ .id = 33, .session_id = "SID-FRED2" });

    var state = RequestState{};
    try issueRequest(page, &state, "http://127.0.0.1:9582/xhr/redirect-twice", .GET, null, false);

    try ctx.expectSentEvent("Fetch.requestPaused", .{ .requestId = "INT-0000000001", .networkId = "REQ-0000000001" }, .{ .session_id = "SID-FRED2" });
    try ctx.processMessage(.{ .id = 34, .method = "Fetch.continueRequest", .sessionId = "SID-FRED2", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 34, .session_id = "SID-FRED2" });

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .redirectedRequestId = "INT-0000000001",
        .networkId = "REQ-0000000001",
    }, .{ .session_id = "SID-FRED2" });
    try ctx.processMessage(.{ .id = 35, .method = "Fetch.continueRequest", .sessionId = "SID-FRED2", .params = .{ .requestId = "INT-0000000002" } });
    try ctx.expectSentResult(null, .{ .id = 35, .session_id = "SID-FRED2" });

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000003",
        .redirectedRequestId = "INT-0000000002",
        .networkId = "REQ-0000000001",
    }, .{ .session_id = "SID-FRED2" });
    try ctx.processMessage(.{ .id = 36, .method = "Fetch.continueRequest", .sessionId = "SID-FRED2", .params = .{ .requestId = "INT-0000000003" } });
    try ctx.expectSentResult(null, .{ .id = 36, .session_id = "SID-FRED2" });

    try waitForRequest(bc, &state);
}

test "cdp.Fetch: redirect 302 rewrites POST to GET on redirected hop" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-FPOST",
        .session_id = "SID-FPOST",
        .target_id = "TID-0000000103".*,
    });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{ .id = 37, .method = "Fetch.enable", .sessionId = "SID-FPOST" });
    try ctx.expectSentResult(null, .{ .id = 37, .session_id = "SID-FPOST" });

    var state = RequestState{};
    try issueRequest(page, &state, "http://127.0.0.1:9582/xhr/redirect", .POST, "hello", false);

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .request = .{ .method = "POST" },
    }, .{ .session_id = "SID-FPOST" });
    try ctx.processMessage(.{ .id = 38, .method = "Fetch.continueRequest", .sessionId = "SID-FPOST", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 38, .session_id = "SID-FPOST" });

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .redirectedRequestId = "INT-0000000001",
        .request = .{ .method = "GET" },
    }, .{ .session_id = "SID-FPOST" });
    try ctx.processMessage(.{ .id = 39, .method = "Fetch.continueRequest", .sessionId = "SID-FPOST", .params = .{ .requestId = "INT-0000000002" } });
    try ctx.expectSentResult(null, .{ .id = 39, .session_id = "SID-FPOST" });

    try waitForRequest(bc, &state);
}

test "cdp.Fetch: continueRequest header overrides stay on one hop" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-FHDR",
        .session_id = "SID-FHDR",
        .target_id = "TID-0000000104".*,
    });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{ .id = 40, .method = "Fetch.enable", .sessionId = "SID-FHDR" });
    try ctx.expectSentResult(null, .{ .id = 40, .session_id = "SID-FHDR" });

    var state = RequestState{};
    try issueRequest(page, &state, "http://127.0.0.1:9582/xhr/redirect", .GET, null, false);

    try ctx.expectSentEvent("Fetch.requestPaused", .{ .requestId = "INT-0000000001" }, .{ .session_id = "SID-FHDR" });
    try ctx.processMessage(.{
        .id = 41,
        .method = "Fetch.continueRequest",
        .sessionId = "SID-FHDR",
        .params = .{
            .requestId = "INT-0000000001",
            .headers = &[_]http.Header{.{ .name = "X-Test", .value = "hop1" }},
        },
    });
    try ctx.expectSentResult(null, .{ .id = 41, .session_id = "SID-FHDR" });

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000002",
        .redirectedRequestId = "INT-0000000001",
    }, .{ .session_id = "SID-FHDR" });

    const second_pause = findFetchPausedEvent(&ctx, "INT-0000000002") orelse return error.ErrorNotFound;
    const params = jsonField(second_pause, "params") orelse return error.MissingKey;
    const request = jsonField(params, "request") orelse return error.MissingKey;
    const headers = jsonField(request, "headers") orelse return error.MissingKey;
    try testing.expect(headers == .object);
    try testing.expect(headers.object.get("X-Test") == null);
    try testing.expectEqualSlices(u8, "original", headers.object.get("X-Base").?.string);

    try ctx.processMessage(.{ .id = 42, .method = "Fetch.continueRequest", .sessionId = "SID-FHDR", .params = .{ .requestId = "INT-0000000002" } });
    try ctx.expectSentResult(null, .{ .id = 42, .session_id = "SID-FHDR" });

    try waitForRequest(bc, &state);
}

test "cdp.Fetch: non-redirect requests still emit one pause event" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-FONE",
        .session_id = "SID-FONE",
        .target_id = "TID-0000000105".*,
    });
    const page = try bc.session.createPage();

    try ctx.processMessage(.{ .id = 43, .method = "Fetch.enable", .sessionId = "SID-FONE" });
    try ctx.expectSentResult(null, .{ .id = 43, .session_id = "SID-FONE" });

    var state = RequestState{};
    try issueRequest(page, &state, "http://127.0.0.1:9582/xhr", .GET, null, false);

    try ctx.expectSentEvent("Fetch.requestPaused", .{
        .requestId = "INT-0000000001",
        .networkId = "REQ-0000000001",
        .request = .{ .url = "http://127.0.0.1:9582/xhr" },
    }, .{ .session_id = "SID-FONE" });

    try ctx.processMessage(.{ .id = 44, .method = "Fetch.continueRequest", .sessionId = "SID-FONE", .params = .{ .requestId = "INT-0000000001" } });
    try ctx.expectSentResult(null, .{ .id = 44, .session_id = "SID-FONE" });

    try waitForRequest(bc, &state);
    try testing.expect(findFetchPausedEvent(&ctx, "INT-0000000002") == null);
}
