const std = @import("std");
const Message = @import("Message.zig");

pub fn startServer(gpa: std.mem.Allocator, io: std.Io, listen_address: []const u8, listen_port: u16) !Server {
    const address = try std.Io.net.IpAddress.parse(listen_address, listen_port);
    const socket = try std.Io.net.IpAddress.bind(&address, io, .{ .mode = .dgram });

    std.debug.print("Listening {s}:{d}\n", .{ listen_address, listen_port });

    return .{
        .gpa = gpa,
        .io = io,
        .socket = socket,
        .buffer = try gpa.alloc(u8, UDP_MAX_PAYLOAD),
    };
}

const UDP_MAX_PAYLOAD = 65507;

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket: std.Io.net.Socket,
    buffer: []u8,

    pub fn next(iter: Server) !?Message {
        const message = try iter.socket.receive(iter.io, iter.buffer);

        //Per the spec we need to trim any leading line breaks
        const trimmed_message = std.mem.trimStart(u8, message.data, "\r\n");

        //Clients often send empty messages (\r\n) for keep alives, ignore them
        if (trimmed_message.len == 0) return next(iter);
        std.debug.print("Recieved: [{s}]\n", .{trimmed_message});

        return try Message.parse(iter.gpa, trimmed_message);
    }

    pub fn close(iter: Server) void {
        iter.gpa.free(iter.buffer);
        iter.socket.close(iter.io);
    }
};
