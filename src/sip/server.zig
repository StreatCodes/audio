const std = @import("std");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const net = std.net;
const Response = @import("./Response.zig");
const Request = @import("./Request.zig");
const headers = @import("./headers.zig");
const Service = @import("./Service.zig");

pub const Connection = struct {
    socket: posix.socket_t,
    address: posix.sockaddr,
    address_len: posix.socklen_t,

    pub fn getAddressAndPort(self: Connection, allocator: mem.Allocator) ![]const u8 {
        const address = net.Address.initPosix(@alignCast(&self.address));
        return try std.fmt.allocPrint(allocator, "{f}", .{address}); //TODO append port???
    }
};

const UDP_MAX_PAYLOAD = 65507;

pub fn startServer(allocator: mem.Allocator, listen_address: []const u8, listen_port: u16) !void {
    var buf = try allocator.alloc(u8, UDP_MAX_PAYLOAD);
    defer allocator.free(buf);

    const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(socket);

    const address = try net.Address.resolveIp(listen_address, listen_port);
    try posix.bind(socket, &address.any, address.getOsSockLen());
    debug.print("Listening {s}:{d}\n", .{ listen_address, listen_port });

    var service = Service.init(allocator);
    defer service.deinit();

    //Wait for incoming datagrams and process them
    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const recv_bytes = try posix.recvfrom(socket, buf, 0, &client_addr, &client_addr_len);
        const connection = Connection{
            .socket = socket,
            .address = client_addr,
            .address_len = client_addr_len,
        };

        //Per the spec we need to trim any leading line breaks
        const message = std.mem.trimLeft(u8, buf[0..recv_bytes], "\r\n");

        //Clients often send empty messages (\r\n) for keep alives, ignore them
        if (message.len == 0) continue;
        debug.print("Request: [{s}]\n", .{message});

        var request = Request.init();
        defer request.deinit(allocator);
        try request.parse(allocator, message);

        try service.handleMessage(connection, request);
    }
}
