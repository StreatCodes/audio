const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const headers = @import("./headers.zig");

const StatusCode = enum(u32) {
    ok = 200,

    fn toString(self: StatusCode) []const u8 {
        switch (self) {
            .ok => return "OK",
        }
    }
};

const Response = @This();
status: StatusCode,

via: []headers.ViaHeader,
to: headers.ToHeader,
from: headers.FromHeader,
call_id: []const u8,
sequence: headers.Sequence,
contact: []headers.Contact,
server: ?[]const u8 = null,
allow: ?[]headers.Method = null,
content_length: ?u32 = null,

body: []const u8 = "",

pub fn encode(self: *Response, writer: anytype) !void {
    try writer.print("SIP/2.0 {d} {s}\r\n", .{ @intFromEnum(self.status), self.status.toString() });
    for (self.via) |via| {
        try writer.print("{s}: ", .{headers.Header.via.toString()});
        try via.encode(writer);
    }

    try writer.print("{s}: ", .{headers.Header.to.toString()});
    try self.to.encode(writer);

    try writer.print("{s}: ", .{headers.Header.from.toString()});
    try self.from.encode(writer);

    try writer.print("{s}: ", .{headers.Header.call_id.toString()});
    try writer.print("{s}\r\n", .{self.call_id});

    try writer.print("{s}: ", .{headers.Header.cseq.toString()});
    try self.sequence.encode(writer);

    for (self.contact) |contact| {
        try writer.print("{s}: ", .{headers.Header.contact.toString()});
        try contact.encode(writer); //TODO convert to contactHeader....
        try writer.writeAll("\r\n");
    }

    try writer.writeAll("\r\n");
    try writer.writeAll(self.body);
    //TODO do i need to write /r/n next?
}

test "Responses are correctly generated" {
    const allocator = std.testing.allocator;

    var via = [_]headers.ViaHeader{
        .{
            .protocol = .udp,
            .address = .{ .host = "192.168.1.100", .port = 5060 },
            .branch = "z9hG4bK776asdhds",
            .received = "192.168.1.100",
        },
    };

    var contact = [_]headers.Contact{
        .{ .protocol = .sip, .user = "user", .host = "192.168.1.100", .port = 5060 },
    };

    var response = Response{
        .status = .ok,
        .via = &via,
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
        .contact = &contact,
    };

    var message_builder = std.ArrayList(u8).init(allocator);
    defer message_builder.deinit();
    const writer = message_builder.writer();

    try response.encode(writer);

    const expected_message = "SIP/2.0 200 OK\r\n" ++
        "Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds;received=192.168.1.100\r\n" ++
        "To: <sip:user@example.com>;tag=server-tag\r\n" ++
        "From: <sip:user@example.com>;tag=123456\r\n" ++
        "Call-ID: 1234567890abcdef@192.168.1.100\r\n" ++
        "CSeq: 1 REGISTER\r\n" ++
        "Contact: <sip:user@192.168.1.100:5060>\r\n" ++ //TODO re add ;expires=3600 once ContactHeader exists
        "\r\n";

    try std.testing.expect(std.mem.eql(u8, message_builder.items, expected_message));
}
