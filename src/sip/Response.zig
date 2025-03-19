const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const ArrayList = std.ArrayList;
const headers = @import("./headers.zig");

const ResponseError = error{
    FieldRequired,
};

const Response = @This();
status: StatusCode = .ok,

via: ArrayList(headers.ViaHeader),
to: ?headers.ToHeader = null,
from: ?headers.FromHeader = null,
call_id: []const u8,
sequence: ?headers.Sequence = null,
contact: ArrayList(headers.ContactHeader),
server: ?[]const u8 = null,
allow: ArrayList(headers.Method),
content_length: u32 = 0,

body: []const u8 = "",

pub fn init(allocator: mem.Allocator) Response {
    return .{
        .via = ArrayList(headers.ViaHeader).init(allocator),
        .call_id = "",
        .contact = ArrayList(headers.ContactHeader).init(allocator),
        .allow = ArrayList(headers.Method).init(allocator),
    };
}

pub fn deinit(self: *Response) void {
    self.via.deinit();
    self.contact.deinit();
    self.allow.deinit();
}

pub fn encode(self: Response, writer: anytype) !void {
    try writer.print("SIP/2.0 {d} {s}\r\n", .{ @intFromEnum(self.status), self.status.toString() });
    for (self.via.items) |via| {
        try writer.print("{s}: ", .{headers.Header.via.toString()});
        try via.encode(writer);
    }

    if (self.to) |to| {
        try writer.print("{s}: ", .{headers.Header.to.toString()});
        try to.encode(writer);
    } else {
        return ResponseError.FieldRequired;
    }

    if (self.from) |from| {
        try writer.print("{s}: ", .{headers.Header.from.toString()});
        try from.encode(writer);
    } else {
        return ResponseError.FieldRequired;
    }

    try writer.print("{s}: ", .{headers.Header.call_id.toString()});
    try writer.print("{s}\r\n", .{self.call_id});

    if (self.sequence) |sequence| {
        try writer.print("{s}: ", .{headers.Header.cseq.toString()});
        try sequence.encode(writer);
    } else {
        return ResponseError.FieldRequired;
    }

    for (self.contact.items) |contact| {
        try writer.print("{s}: ", .{headers.Header.contact.toString()});
        try contact.encode(writer);
    }

    try writer.writeAll("\r\n");
    try writer.writeAll(self.body);
    //TODO do i need to write /r/n next?
}

const StatusCode = enum(u32) {
    ok = 200,

    fn toString(self: StatusCode) []const u8 {
        switch (self) {
            .ok => return "OK",
        }
    }
};

test "Responses are correctly generated" {
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();

    try response.via.append(.{
        .protocol = .udp,
        .address = .{ .host = "192.168.1.100", .port = 5060 },
        .branch = "z9hG4bK776asdhds",
        .received = "192.168.1.100",
    });

    try response.contact.append(.{
        .contact = .{ .protocol = .sip, .user = "user", .host = "192.168.1.100", .port = 5060 },
        .expires = 3600,
    });

    response.to = .{
        .contact = .{ .protocol = .sip, .user = "user", .host = "example.com" },
        .tag = "server-tag",
    };

    response.from = .{
        .contact = .{ .protocol = .sip, .user = "user", .host = "example.com" },
        .tag = "123456",
    };

    response.call_id = "1234567890abcdef@192.168.1.100";
    response.sequence = .{ .method = .register, .number = 1 };

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
        "Contact: <sip:user@192.168.1.100>;expires=3600\r\n" ++
        "\r\n";

    try std.testing.expect(std.mem.eql(u8, message_builder.items, expected_message));
}
