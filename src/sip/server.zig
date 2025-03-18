const std = @import("std");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const net = std.net;
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
        var request = try Request.parse(allocator, message);
        defer request.deinit(allocator);

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
        const response = switch (request.method) {
            .register => try session.handleRegister(allocator, request),
            else => try session.handleUnknown(allocator, request),
        };

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

        return Session{
            .sequence = request.sequence.number,
            .call_id = call_id,
        };
    }

    fn handleRegister(self: *Session, allocator: mem.Allocator, request: Request) !Response {
        _ = self;

        debug.print("REGISTER - session update\n", .{});
        var via = try allocator.alloc(headers.ViaHeader, 1); //TODO LEAKING!
        via[0] = request.via;

        var contact = try allocator.alloc(headers.ContactHeader, 1); //TODO LEAKING!
        contact[0] = .{
            .contact = request.contact.?.contact,
            .expires = request.expires,
        };

        return Response{
            .status = .ok,
            .via = via,
            .to = headers.ToHeader{
                .contact = request.to.contact,
                .tag = "server-tag",
            },
            .from = headers.FromHeader{
                .contact = request.from.contact,
                .tag = request.from.tag,
            },
            .call_id = request.call_id,
            .sequence = request.sequence,
            .contact = contact,
        };
    }

    fn handleUnknown(self: Session, allocator: mem.Allocator, request: Request) !Response {
        _ = self;
        _ = allocator;
        _ = request;
        return Response{
            .status = .ok,
            .via = &[_]headers.ViaHeader{},
            .to = headers.ToHeader{
                .contact = .{ .protocol = .sip, .user = "user", .host = "example.com" },
                .tag = "server-tag",
            },
            .from = headers.FromHeader{
                .contact = .{ .protocol = .sip, .user = "user", .host = "example.com" },
                .tag = "123456",
            },
            .call_id = "1234567890abcdef@192.168.1.100",
            .sequence = .{ .method = .register, .number = 1 },
            .contact = &[_]headers.ContactHeader{},
        };
    }
};
