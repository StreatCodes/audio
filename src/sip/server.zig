const std = @import("std");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const net = std.net;
const testing = std.testing;
const Response = @import("./Response.zig");
const Request = @import("./Request.zig");
const headers = @import("./headers.zig");

const Sessions = std.StringHashMap(Session);
const UDP_MAX_PAYLOAD = 65507;

pub fn startServer(allocator: mem.Allocator, listen_address: []const u8, listen_port: u16) !void {
    var buf = try allocator.alloc(u8, UDP_MAX_PAYLOAD);
    defer allocator.free(buf);

    const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(socket);

    const address = try net.Address.resolveIp(listen_address, listen_port);
    try posix.bind(socket, &address.any, address.getOsSockLen());
    debug.print("Listening {s}:{d}\n", .{ listen_address, listen_port });

    var sessions = Sessions.init(allocator);
    defer sessions.deinit();

    //Wait for incoming datagrams and process them
    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const recv_bytes = try posix.recvfrom(socket, buf, 0, &client_addr, &client_addr_len);

        //Per the spec we need to trim any leading line breaks
        const message = std.mem.trimLeft(u8, buf[0..recv_bytes], "\r\n");

        //Clients often send empty messages (\r\n) for keep alives, ignore them
        if (message.len == 0) {
            debug.print("Empty message, skipping\n", .{});
            continue;
        }

        const remote_address = try getAddressAndPort(allocator, client_addr);
        var request = Request.init(allocator);
        defer request.deinit();
        try request.parse(message);

        //Check to see if a session exists for the remote address, if not create one
        if (!sessions.contains(remote_address)) {
            if (request.method != .register) {
                debug.print("First message must be REGISTER\n", .{});
                continue;
            }

            const session = try Session.fromRegister(allocator, request);
            try sessions.put(remote_address, session);
        }

        //Process the message for the session
        const session = sessions.getPtr(remote_address) orelse unreachable;
        var response = Response.init(allocator);
        defer response.deinit();

        try session.handleMessage(request, &response);

        //Write the response back to the client
        var response_builder = std.ArrayList(u8).init(allocator);
        defer response_builder.deinit();
        const writer = response_builder.writer();

        try response.encode(writer);
        debug.print("Request: [{s}]\n", .{message});
        debug.print("Response: [{s}]\n", .{response_builder.items});
        _ = try posix.sendto(socket, response_builder.items, 0, &client_addr, client_addr_len);
    }
}

pub fn getAddressAndPort(allocator: mem.Allocator, addr: posix.sockaddr) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    const address = net.Address.initPosix(@alignCast(&addr));
    try address.format("", .{}, writer);

    return buffer.toOwnedSlice();
}

const Session = struct {
    sequence: u32,
    // expires: u32,
    // contact: headers.Contact,
    call_id: []const u8,
    // supported_methods: []headers.Method,

    fn fromRegister(allocator: mem.Allocator, request: Request) !Session {
        debug.print("Creating session for NEWUSERTODO\n", .{});
        const call_id = try allocator.alloc(u8, request.call_id.len);
        @memcpy(call_id, request.call_id);

        const sequence = request.sequence orelse return Request.RequestError.InvalidMessage;
        return Session{
            .sequence = sequence.number,
            .call_id = call_id,
        };
    }

    /// Accepts a SIP request for an established session and returns a response.
    /// All SIP messages will get routed through this to the appropriate handler
    /// for that method
    fn handleMessage(self: *Session, request: Request, response: *Response) !void {
        //TODO add some validation for call_id and out of order sequences
        //These fields have consistent responses across all methods
        for (request.via.items) |via| {
            try response.via.append(via);
        }
        response.to = request.to;
        response.to.?.tag = "server-tag"; //TODO we need to make sure this is always present, validate in parse or seperate function
        response.from = request.from;
        response.call_id = request.call_id;
        response.sequence = request.sequence;

        //Handle the different request methods
        switch (request.method) {
            .register => try self.handleRegister(request, response),
            else => try self.handleUnknown(request, response),
        }
    }

    fn handleRegister(self: *Session, request: Request, response: *Response) !void {
        _ = self;

        debug.print("REGISTER - session update\n", .{});

        for (request.contact.items) |contact_header| {
            try response.contact.append(.{
                .contact = contact_header.contact,
                .expires = request.expires,
            });
        }
    }

    fn handleUnknown(self: Session, request: Request, response: *Response) !void {
        _ = self;
        _ = request;
        response.status = .not_implemented;
    }
};

test "Server responds appropriately to REGISTER message" {
    const request_text = "REGISTER sip:localhost SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 172.20.10.4:51503;rport;branch=z9hG4bKPjDdUL.6kHzjJFszmWr9AGotAlsZvHTB0P\r\n" ++
        "Max-Forwards: 70\r\n" ++
        "From: \"Streats\" <sip:streats@localhost>;tag=fhKG9FMFGbyIi5LZTlwro5qigCxoFqwf\r\n" ++
        "To: \"Streats\" <sip:streats@localhost>\r\n" ++
        "Call-ID: Fb5KdYo-eWr4WVTWTv0vwxwi.XvJFoGf\r\n" ++
        "CSeq: 34848 REGISTER\r\n" ++
        "User-Agent: Telephone 1.6\r\n" ++
        "Contact: \"Streats\" <sip:streats@172.20.10.4:51503;ob>\r\n" ++
        "Expires: 0\r\n" ++
        "Content-Length:  0\r\n" ++
        "\r\n";

    var session = Session{ .call_id = "", .sequence = 0 };
    var request = Request.init(testing.allocator);
    defer request.deinit();
    try request.parse(request_text);

    var response = Response.init(testing.allocator);
    defer response.deinit();
    try session.handleMessage(request, &response);

    //TODO make this more thorough
    try testing.expectEqual(response.status, Response.StatusCode.ok);
    try testing.expectEqualStrings(response.call_id, request.call_id);
    try testing.expectEqual(response.sequence.?.number, request.sequence.?.number);
}
