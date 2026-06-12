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
const Session = @import("./Session.zig");

pub const Connection = struct {
    socket: std.Io.net.Socket,
    address: std.Io.net.IpAddress,

    pub fn getAddressAndPort(self: Connection, allocator: mem.Allocator, user: []const u8) ![]const u8 {
        const address = net.Address.initPosix(@alignCast(&self.address));
        return try std.fmt.allocPrint(allocator, "{s}@{f}", .{ user, address });
    }

    pub fn getUri(self: Connection, allocator: std.mem.Allocator, user: []const u8) !std.Uri {
        const base_uri = try self.getAddressAndPort(allocator, user);
        defer allocator.free(base_uri);
        var uri = try std.Uri.parse(base_uri);
        uri.scheme = "sip";

        return uri;
    }
};

const UDP_MAX_PAYLOAD = 65507;

pub fn startServer(gpa: mem.Allocator, io: std.Io, listen_address: []const u8, listen_port: u16) !void {
    const buf = try gpa.alloc(u8, UDP_MAX_PAYLOAD);
    defer gpa.free(buf);

    const address = try std.Io.net.IpAddress.parse(listen_address, listen_port);
    const socket = try std.Io.net.IpAddress.bind(&address, io, .{ .mode = .dgram });
    defer socket.close(io);

    debug.print("Listening {s}:{d}\n", .{ listen_address, listen_port });

    var service = try Service.init(gpa, io);
    defer service.deinit();

    //Wait for incoming datagrams and process them
    while (true) {
        const buffer = try gpa.alloc(u8, 2048);
        defer gpa.free(buffer);
        const message = try socket.receive(io, buffer);

        const connection = Connection{
            .socket = socket,
            .address = message.from,
        };

        //Per the spec we need to trim any leading line breaks
        const trimmed_message = std.mem.trimStart(u8, message.data, "\r\n");

        //Clients often send empty messages (\r\n) for keep alives, ignore them
        if (trimmed_message.len == 0) continue;
        debug.print("Recieved: [{s}]\n", .{trimmed_message});

        try service.handleMessage(connection, trimmed_message);
        // service.handleMessage(connection, message) catch |err| {
        //     std.debug.print("Error handling message {any}\n", .{err});
        // };
    }
}
