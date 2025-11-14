const std = @import("std");
const headers = @import("./headers.zig");
const mem = std.mem;
const debug = std.debug;
const ArrayList = std.ArrayList;

pub const RequestError = error{
    InvalidMessage,
    FieldRequired,
};

const Request = @This();

method: headers.Method = .register,
uri: []const u8 = "",

via: ArrayList(headers.ViaHeader),
max_forwards: u32 = 70,
from: ?headers.FromHeader = null,
to: ?headers.ToHeader = null,
call_id: []const u8 = "",
sequence: ?headers.Sequence = null,
user_agent: ?[]const u8 = null,
contact: ArrayList(headers.ContactHeader),
expires: u32 = 300,
allow: ArrayList(headers.Method),
content_length: u32 = 0,
content_type: ?[]const u8 = null,
supported: ArrayList(headers.Extension),

body: []const u8 = "",

pub fn init() Request {
    return Request{
        .via = ArrayList(headers.ViaHeader).empty,
        .contact = ArrayList(headers.ContactHeader).empty,
        .allow = ArrayList(headers.Method).empty,
        .supported = ArrayList(headers.Extension).empty,
    };
}

pub fn deinit(self: *Request, allocator: mem.Allocator) void {
    self.via.deinit(allocator);
    self.contact.deinit(allocator);
    self.allow.deinit(allocator);
    self.supported.deinit(allocator);
}

pub fn dupe(self: Request, allocator: mem.Allocator) !Request {
    var new_request = self;

    new_request.via = ArrayList(headers.ViaHeader).empty;
    new_request.contact = ArrayList(headers.ContactHeader).empty;
    new_request.allow = ArrayList(headers.Method).empty;
    new_request.supported = ArrayList(headers.Extension).empty;

    try new_request.via.appendSlice(allocator, self.via.items);
    try new_request.contact.appendSlice(allocator, self.contact.items);
    try new_request.allow.appendSlice(allocator, self.allow.items);
    try new_request.supported.appendSlice(allocator, self.supported.items);

    return new_request;
}

pub fn parse(self: *Request, allocator: mem.Allocator, message_text: []const u8) !void {
    var lines = std.mem.splitSequence(u8, message_text, "\r\n");
    const first_line = lines.next() orelse return RequestError.InvalidMessage;

    //Parse the request line
    var first_line_values = std.mem.splitScalar(u8, first_line, ' ');

    const method = first_line_values.next() orelse return RequestError.InvalidMessage;
    const uri = first_line_values.next() orelse return RequestError.InvalidMessage;
    const version = first_line_values.next() orelse return RequestError.InvalidMessage;

    self.method = try headers.Method.fromString(method);
    self.uri = uri;
    if (!std.mem.eql(u8, version, "SIP/2.0")) return RequestError.InvalidMessage;

    //Parse the headers
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "")) break;

        const splitIndex = std.mem.indexOfScalar(u8, line, ':') orelse return headers.HeaderError.InvalidHeader;
        const field = std.mem.trim(u8, line[0..splitIndex], " ");
        const value = std.mem.trim(u8, line[splitIndex + 1 ..], " ");

        const header_field = try headers.Header.fromString(field);

        //TODO contact can have multiple values in one header that's comma seperated
        switch (header_field) {
            .via => {
                const via = try headers.ViaHeader.parse(value);
                try self.via.append(allocator, via);
            },
            .max_forwards => self.max_forwards = try std.fmt.parseInt(u32, value, 10),
            .from => self.from = try headers.FromHeader.parse(value),
            .to => self.to = try headers.ToHeader.parse(value),
            .call_id => self.call_id = value,
            .cseq => self.sequence = try headers.Sequence.parse(value),
            .user_agent => self.user_agent = value,
            .contact => {
                const contact = try headers.ContactHeader.parse(value);
                try self.contact.append(allocator, contact);
            },
            .expires => self.expires = try std.fmt.parseInt(u32, value, 10),
            .allow => {
                var iter = std.mem.tokenizeScalar(u8, value, ',');
                while (iter.next()) |method_text| {
                    const trimmed = mem.trim(u8, method_text, " ");
                    try self.allow.append(allocator, try headers.Method.fromString(trimmed));
                }
            },
            .content_length => self.content_length = try std.fmt.parseInt(u32, value, 10),
            .content_type => self.content_type = value,
            .supported => {
                var iter = std.mem.tokenizeScalar(u8, value, ',');
                while (iter.next()) |extension_text| {
                    const trimmed = mem.trim(u8, extension_text, " ");
                    try self.supported.append(allocator, try headers.Extension.fromString(trimmed));
                }
            },
        }
    }

    self.body = lines.rest();
}

pub fn encode(self: Request, writer: *std.io.Writer) !void {
    try writer.print("{s} {s} SIP/2.0\r\n", .{ self.method.toString(), self.uri });
    for (self.via.items) |via| {
        try writer.print("{s}: ", .{headers.Header.via.toString()});
        try via.encode(writer);
    }

    try writer.print("{d}\r\n", .{self.max_forwards});

    if (self.from) |from| {
        try writer.print("{s}: ", .{headers.Header.from.toString()});
        try from.encode(writer);
    } else {
        return RequestError.FieldRequired;
    }

    if (self.to) |to| {
        try writer.print("{s}: ", .{headers.Header.to.toString()});
        try to.encode(writer);
    } else {
        return RequestError.FieldRequired;
    }

    try writer.print("{s}: ", .{headers.Header.call_id.toString()});
    try writer.print("{s}\r\n", .{self.call_id});

    if (self.sequence) |sequence| {
        try writer.print("{s}: ", .{headers.Header.cseq.toString()});
        try sequence.encode(writer);
    } else {
        return RequestError.FieldRequired;
    }

    if (self.user_agent) |user_agent| {
        try writer.print("{s}: ", .{headers.Header.user_agent.toString()});
        try writer.print("{s}\r\n", .{user_agent});
    } else {
        return RequestError.FieldRequired;
    }

    for (self.contact.items) |contact| {
        try writer.print("{s}: ", .{headers.Header.contact.toString()});
        try contact.encode(writer);
    }

    // TODO expires - may require making the field optional

    if (self.allow.items.len > 0) {
        try writer.print("{s}: ", .{headers.Header.allow.toString()});
        for (self.allow.items, 0..) |allow, index| {
            try writer.writeAll(allow.toString());
            if (index < self.allow.items.len - 1) {
                try writer.writeAll(", ");
            } else {
                try writer.writeAll("\r\n");
            }
        }
    }

    if (self.supported.items.len > 0) {
        try writer.print("{s}: ", .{headers.Header.supported.toString()});
        for (self.supported.items, 0..) |supported, index| {
            try writer.writeAll(supported.toString());
            if (index < self.supported.items.len - 1) {
                try writer.writeAll(", ");
            } else {
                try writer.writeAll("\r\n");
            }
        }
    }

    if (self.content_type) |content_type| {
        try writer.print("{s}: {s}\r\n", .{ headers.Header.content_type.toString(), content_type });
    }

    try writer.print("{s}: {d}\r\n", .{ headers.Header.content_length.toString(), self.content_length });

    try writer.writeAll("\r\n");
    try writer.writeAll(self.body);
    //TODO do i need to write /r/n next?
}

test "sip can correctly parse a SIP REGISTER message" {
    const message = "REGISTER sip:localhost SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 172.20.10.4:55595;rport;branch=z9hG4bKPj97wgnQ5d7IM3cfDd2QYcYf9H8hqJLxit\r\n" ++
        "Max-Forwards: 70\r\n" ++
        "From: \"Streats\" <sip:streats@localhost>;tag=Z.hw-WnzbyImNj0P.WWHJW9zhtQc1lm8\r\n" ++
        "To: \"Streats\" <sip:streats@localhost>\r\n" ++
        "Call-ID: xGAGzEIoe5SHqQnmK5W2jWsIF7kThRbn\r\n" ++
        "CSeq: 37838 REGISTER\r\n" ++
        "User-Agent: Telephone 1.6\r\n" ++
        "Contact: \"Streats\" <sip:streats@172.20.10.4:55595;ob>;expires=0\r\n" ++
        "Expires: 300\r\n" ++
        "Allow: PRACK, INVITE, ACK, BYE, CANCEL, UPDATE, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS\r\n" ++
        "Content-Length:  0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    var request = Request.init(allocator);
    defer request.deinit();

    try request.parse(message);
    try std.testing.expect(request.method == .register);
    try std.testing.expect(std.mem.eql(u8, request.uri, "sip:localhost"));
    try std.testing.expect(request.contact.items[0].expires == 0);
    try std.testing.expect(std.mem.eql(u8, request.body, ""));
}
