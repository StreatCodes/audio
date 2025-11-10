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
const Session = @import("./Session.zig");

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
        var request = Request.init();
        defer request.deinit(allocator);
        try request.parse(allocator, message);

        //Check to see if a session exists for the remote address, if not create one
        if (!sessions.contains(remote_address)) {
            if (request.method != .register) {
                debug.print("First message must be REGISTER\n", .{});
                continue;
            }

            const session = Session.init(allocator);
            try sessions.put(remote_address, session);
        }

        //Process the message for the session
        const session = sessions.getPtr(remote_address) orelse unreachable;

        var response = try session.handleMessage(request) orelse continue;
        defer response.deinit(allocator);

        //Write the response back to the client
        var response_buffer = std.io.Writer.Allocating.init(allocator);

        try response.encode(&response_buffer.writer);
        debug.print("Request: [{s}]\n", .{message});
        debug.print("Response: [{s}]\n", .{response_buffer.written()});
        _ = try posix.sendto(socket, response_buffer.written(), 0, &client_addr, client_addr_len);
    }
}

pub fn getAddressAndPort(allocator: mem.Allocator, addr: posix.sockaddr) ![]const u8 {
    const buffer = try allocator.alloc(u8, 512);
    var writer = std.io.Writer.fixed(buffer);

    const address = net.Address.initPosix(@alignCast(&addr));
    try address.format(&writer);

    return writer.buffered(); //TODO unsure about this....
}
