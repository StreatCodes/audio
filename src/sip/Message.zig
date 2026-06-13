const std = @import("std");
const headers = @import("./headers.zig");

pub const MessageError = error{
    InvalidMessage,
    RequiredField,
    BadRequest,
    BadResponse,
};

const Message = @This();

arena: std.heap.ArenaAllocator,
raw_message: []const u8,

start_line: headers.StartLine,
via: std.ArrayList(headers.ViaHeader),
contact: std.ArrayList(headers.ContactHeader),
allow: std.ArrayList(headers.Method),
supported: std.ArrayList(headers.Extension),
from: ?headers.FromHeader = null,
to: ?headers.ToHeader = null,
sequence: ?headers.Sequence = null,
call_id: ?[]const u8 = null,
expires: ?u32 = null,
max_forwards: ?u32 = null,
user_agent: ?[]const u8 = null,
accept: ?[]const u8 = null,
record_route: ?headers.RecordRoute = null,
server: ?[]const u8 = null,
content_type: ?[]const u8 = null,
body: []const u8 = "",

pub fn initResponse(gpa: std.mem.Allocator, status: headers.StatusCode) Message {
    return .{
        .arena = std.heap.ArenaAllocator{ .child_allocator = gpa, .state = .init },
        .raw_message = "",
        .start_line = .{
            .response = .{
                .version = "SIP/2.0",
                .status = status,
            },
        },
        .via = .empty,
        .contact = .empty,
        .allow = .empty,
        .supported = .empty,
    };
}

pub fn deinit(message: *Message) void {
    message.arena.deinit();
}

pub fn parse(gpa: std.mem.Allocator, message_text: []const u8) !Message {
    // parse the first line, unique between requests and responses
    var lines = std.mem.splitSequence(u8, message_text, "\r\n");
    const first_line_text = lines.next() orelse return MessageError.InvalidMessage;
    const start_line = try headers.StartLine.parse(first_line_text);

    var message = Message{
        .arena = std.heap.ArenaAllocator{ .child_allocator = gpa, .state = .init },
        .start_line = start_line,
        .raw_message = message_text,
        .via = .empty,
        .contact = .empty,
        .allow = .empty,
        .supported = .empty,
    };

    const allocator = message.arena.allocator();

    //Parse the headers
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "")) break;

        const splitIndex = std.mem.indexOfScalar(u8, line, ':') orelse return headers.HeaderError.InvalidHeader;
        const field = std.mem.trim(u8, line[0..splitIndex], " ");
        const value = std.mem.trim(u8, line[splitIndex + 1 ..], " ");

        const header_field = try headers.Header.fromString(field);

        switch (header_field) {
            .via => {
                const via = try headers.ViaHeader.parse(value);
                try message.via.append(allocator, via);
            },
            .max_forwards => message.max_forwards = try std.fmt.parseInt(u32, value, 10),
            .from => message.from = try headers.FromHeader.parse(value),
            .to => message.to = try headers.ToHeader.parse(value),
            .call_id => message.call_id = value,
            .cseq => message.sequence = try headers.Sequence.parse(value),
            .user_agent => message.user_agent = value,
            .accept => message.accept = value,
            .record_route => message.record_route = try headers.RecordRoute.parse(value),
            .contact => {
                const contact = try headers.ContactHeader.parse(value);
                try message.contact.append(allocator, contact);
            },
            .expires => message.expires = try std.fmt.parseInt(u32, value, 10),
            .allow => {
                var iter = std.mem.tokenizeScalar(u8, value, ',');
                while (iter.next()) |method_text| {
                    const trimmed = std.mem.trim(u8, method_text, " ");
                    try message.allow.append(allocator, try headers.Method.fromString(trimmed));
                }
            },
            .content_type => message.content_type = value,
            .content_length => {}, //Derived from body.len
            .supported => {
                var iter = std.mem.tokenizeScalar(u8, value, ',');
                while (iter.next()) |extension_text| {
                    const trimmed = std.mem.trim(u8, extension_text, " ");
                    try message.supported.append(allocator, try headers.Extension.fromString(trimmed));
                }
            },
        }
    }

    message.body = lines.rest();
    return message;
}

// Max-Forwards (required on requests; not on responses)

pub fn encode(message: Message, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: std.ArrayList(u8) = try .initCapacity(allocator, 4096);

    try message.start_line.encode(allocator, &buffer);

    for (message.via.items) |via| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.via.toString()});
        try via.encode(allocator, &buffer);
    }

    if (message.max_forwards) |max_forwards| {
        try buffer.print(allocator, "{s}: {d}\r\n", .{ headers.Header.max_forwards.toString(), max_forwards });
    } else if (message.start_line == .request) {
        return MessageError.RequiredField;
    }

    if (message.to) |to| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.to.toString()});
        try to.encode(allocator, &buffer);
    } else {
        return MessageError.RequiredField;
    }

    if (message.from) |from| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.from.toString()});
        try from.encode(allocator, &buffer);
    } else {
        return MessageError.RequiredField;
    }

    if (message.call_id) |call_id| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.call_id.toString()});
        try buffer.print(allocator, "{s}\r\n", .{call_id});
    } else {
        return MessageError.RequiredField;
    }

    if (message.sequence) |sequence| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.cseq.toString()});
        try sequence.encode(allocator, &buffer);
    } else {
        return MessageError.RequiredField;
    }

    if (message.user_agent) |user_agent| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.user_agent.toString()});
        try buffer.print(allocator, "{s}\r\n", .{user_agent});
    }

    if (message.accept) |accept| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.accept.toString()});
        try buffer.print(allocator, "{s}\r\n", .{accept});
    }

    for (message.contact.items) |contact| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.contact.toString()});
        try contact.encode(allocator, &buffer);
    }

    if (message.expires) |expires| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.expires.toString()});
        try buffer.print(allocator, "{d}\r\n", .{expires});
    }

    if (message.allow.items.len > 0) {
        try buffer.print(allocator, "{s}: ", .{headers.Header.allow.toString()});
        for (message.allow.items, 0..) |allow, index| {
            try buffer.appendSlice(allocator, allow.toString());
            if (index < message.allow.items.len - 1) {
                try buffer.appendSlice(allocator, ", ");
            } else {
                try buffer.appendSlice(allocator, "\r\n");
            }
        }
    }

    if (message.supported.items.len > 0) {
        try buffer.print(allocator, "{s}: ", .{headers.Header.supported.toString()});
        for (message.supported.items, 0..) |supported, index| {
            try buffer.appendSlice(allocator, supported.toString());
            if (index < message.supported.items.len - 1) {
                try buffer.appendSlice(allocator, ", ");
            } else {
                try buffer.appendSlice(allocator, "\r\n");
            }
        }
    }

    if (message.record_route) |record_route| {
        try buffer.print(allocator, "{s}: ", .{headers.Header.record_route.toString()});
        try record_route.encode(allocator, &buffer);
    }

    if (message.content_type) |content_type| {
        try buffer.print(allocator, "{s}: {s}\r\n", .{ headers.Header.content_type.toString(), content_type });
    }

    try buffer.print(allocator, "{s}: {d}\r\n", .{ headers.Header.content_length.toString(), message.body.len });

    try buffer.appendSlice(allocator, "\r\n");
    try buffer.appendSlice(allocator, message.body);

    return buffer.toOwnedSlice(allocator);
}

pub fn addVia(self: *Message, via: headers.ViaHeader) !void {
    try self.via.append(self.arena.allocator(), via);
}

pub fn addContact(self: *Message, contact: headers.ContactHeader) !void {
    try self.contact.append(self.arena.allocator(), contact);
}

pub fn addAllow(self: *Message, contact: headers.ContactHeader) !void {
    try self.contact.append(self.arena.allocator(), contact);
}

pub fn addExtension(self: *Message, extension: headers.Extension) !void {
    try self.supported.append(self.arena.allocator(), extension);
}

test "sip can correctly parse a SIP REGISTER message" {
    const message_text = "REGISTER sip:localhost SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 172.20.10.4:55595;rport;branch=z9hG4bKPj97wgnQ5d7IM3cfDd2QYcYf9H8hqJLxit\r\n" ++
        "Max-Forwards: 49\r\n" ++
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
    var message = try Message.parse(allocator, message_text);
    defer message.deinit();

    try std.testing.expectEqual(message.start_line.request.method, .register);
    try std.testing.expectEqualStrings(message.start_line.request.uri.scheme, "sip");
    try std.testing.expectEqual(message.contact.items[0].expires.?, 0);
    try std.testing.expectEqual(message.max_forwards.?, 49);
    try std.testing.expectEqualStrings(message.call_id.?, "xGAGzEIoe5SHqQnmK5W2jWsIF7kThRbn");
    try std.testing.expectEqual(message.expires.?, 300);
    try std.testing.expect(std.mem.eql(u8, message.body, ""));
}

test "sip can correctly parse a SIP INVITE message with a body" {
    const sdp_body = "v=0\r\n" ++
        "o=alice 2890844526 2890844526 IN IP4 192.168.1.100\r\n" ++
        "s=-\r\n" ++
        "c=IN IP4 192.168.1.100\r\n" ++
        "t=0 0\r\n" ++
        "m=audio 49170 RTP/AVP 0\r\n";

    const message_text = "INVITE sip:bob@example.com SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds\r\n" ++
        "Max-Forwards: 70\r\n" ++
        "From: \"Alice\" <sip:alice@example.com>;tag=1928301774\r\n" ++
        "To: \"Bob\" <sip:bob@example.com>\r\n" ++
        "Call-ID: a84b4c76e66710@192.168.1.100\r\n" ++
        "CSeq: 314159 INVITE\r\n" ++
        "Contact: <sip:alice@192.168.1.100:5060>\r\n" ++
        "Content-Type: application/sdp\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{sdp_body.len}) ++ "\r\n" ++
        "\r\n" ++
        sdp_body;

    const allocator = std.testing.allocator;
    var message = try Message.parse(allocator, message_text);
    defer message.deinit();

    try std.testing.expectEqual(message.start_line.request.method, .invite);
    try std.testing.expectEqualStrings(message.start_line.request.uri.scheme, "sip");
    try std.testing.expectEqual(message.max_forwards.?, 70);
    try std.testing.expectEqualStrings(message.call_id.?, "a84b4c76e66710@192.168.1.100");
    try std.testing.expectEqualStrings(message.content_type.?, "application/sdp");
    try std.testing.expectEqualStrings(message.body, sdp_body);
    try std.testing.expectEqual(message.sequence.?.number, 314159);
    try std.testing.expectEqual(message.sequence.?.method, .invite);
}

test "sip can correctly parse a 200 OK response to INVITE" {
    const message_text = "SIP/2.0 200 OK\r\n" ++
        "Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds;received=192.168.1.100\r\n" ++
        "From: \"Alice\" <sip:alice@example.com>;tag=1928301774\r\n" ++
        "To: \"Bob\" <sip:bob@example.com>;tag=a6c85cf\r\n" ++
        "Call-ID: a84b4c76e66710@192.168.1.100\r\n" ++
        "CSeq: 314159 INVITE\r\n" ++
        "Contact: <sip:bob@192.168.1.101:5060>\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    var message = try Message.parse(allocator, message_text);
    defer message.deinit();

    try std.testing.expectEqual(message.start_line.response.status, .ok);
    try std.testing.expectEqualStrings(message.to.?.tag.?, "a6c85cf");
    try std.testing.expectEqualStrings(message.from.?.tag.?, "1928301774");
    try std.testing.expectEqual(message.sequence.?.method, .invite);
    try std.testing.expectEqual(message.via.items.len, 1);
    try std.testing.expectEqualStrings(message.via.items[0].received.?, "192.168.1.100");
    try std.testing.expect(std.mem.eql(u8, message.body, ""));
}

test "sip can correctly parse a 404 Not Found response" {
    const message_text = "SIP/2.0 404 Not Found\r\n" ++
        "Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds\r\n" ++
        "From: \"Alice\" <sip:alice@example.com>;tag=1928301774\r\n" ++
        "To: \"Bob\" <sip:bob@example.com>;tag=a6c85cf\r\n" ++
        "Call-ID: a84b4c76e66710@192.168.1.100\r\n" ++
        "CSeq: 314159 INVITE\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    var message = try Message.parse(allocator, message_text);
    defer message.deinit();

    try std.testing.expectEqual(message.start_line.response.status, .not_found);
    try std.testing.expect(message.contact.items.len == 0);
    try std.testing.expect(message.user_agent == null);
    try std.testing.expect(std.mem.eql(u8, message.body, ""));
}

test "sip can correctly parse an OPTIONS request with multiple Via headers" {
    const message_text = "OPTIONS sip:carol@chicago.com SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP server10.biloxi.com;branch=z9hG4bK4b43c2ff8.1\r\n" ++
        "Via: SIP/2.0/UDP bigbox3.site3.atlanta.com;branch=z9hG4bK77ef4c2312983.1\r\n" ++
        "Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds\r\n" ++
        "Max-Forwards: 68\r\n" ++
        "From: \"Alice\" <sip:alice@atlanta.com>;tag=1928301774\r\n" ++
        "To: <sip:carol@chicago.com>\r\n" ++
        "Call-ID: a84b4c76e66710\r\n" ++
        "CSeq: 63104 OPTIONS\r\n" ++
        "Contact: <sip:alice@pc33.atlanta.com>\r\n" ++
        "Accept: application/sdp\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    var message = try Message.parse(allocator, message_text);
    defer message.deinit();

    try std.testing.expectEqual(message.start_line.request.method, .options);
    try std.testing.expectEqual(message.via.items.len, 3);
    try std.testing.expectEqualStrings(message.via.items[0].address.host, "server10.biloxi.com");
    try std.testing.expectEqualStrings(message.via.items[2].address.host, "pc33.atlanta.com");
    try std.testing.expectEqual(message.max_forwards.?, 68);
}

test "sip can correctly parse a BYE request with no optional headers" {
    const message_text = "BYE sip:bob@192.168.1.101:5060 SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK392839842\r\n" ++
        "Max-Forwards: 70\r\n" ++
        "From: \"Alice\" <sip:alice@example.com>;tag=1928301774\r\n" ++
        "To: \"Bob\" <sip:bob@example.com>;tag=a6c85cf\r\n" ++
        "Call-ID: a84b4c76e66710@192.168.1.100\r\n" ++
        "CSeq: 314160 BYE\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    var message = try Message.parse(allocator, message_text);
    defer message.deinit();

    try std.testing.expectEqual(message.start_line.request.method, .bye);
    try std.testing.expectEqual(message.sequence.?.number, 314160);
    try std.testing.expectEqual(message.sequence.?.method, .bye);
    try std.testing.expect(message.contact.items.len == 0);
    try std.testing.expect(message.expires == null);
    try std.testing.expect(message.user_agent == null);
}

test "sip can correctly parse a message with Supported and Record-Route headers" {
    const message_text = "INVITE sip:bob@example.com SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds\r\n" ++
        "Max-Forwards: 70\r\n" ++
        "Record-Route: <sip:proxy1.example.com;lr>\r\n" ++
        "From: \"Alice\" <sip:alice@example.com>;tag=1928301774\r\n" ++
        "To: \"Bob\" <sip:bob@example.com>\r\n" ++
        "Call-ID: a84b4c76e66710@192.168.1.100\r\n" ++
        "CSeq: 314159 INVITE\r\n" ++
        "Contact: <sip:alice@192.168.1.100:5060>\r\n" ++
        "Supported: 100rel, timer, replaces\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    var message = try Message.parse(allocator, message_text);
    defer message.deinit();

    try std.testing.expectEqual(message.supported.items.len, 3);
    try std.testing.expectEqual(message.supported.items[0], .one_hundred_rel);
    try std.testing.expectEqual(message.supported.items[1], .timer);
    try std.testing.expectEqual(message.supported.items[2], .replaces);
    try std.testing.expect(message.record_route != null);
}

test "sip parse fails on a message with an invalid header line" {
    const message_text = "REGISTER sip:localhost SIP/2.0\r\n" ++
        "Via SIP/2.0/UDP 172.20.10.4:55595\r\n" ++ // missing colon
        "Content-Length: 0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    try std.testing.expectError(headers.HeaderError.InvalidHeader, Message.parse(allocator, message_text));
}

test "sip can correctly encode a basic response" {
    const allocator = std.testing.allocator;

    var response = Message.initResponse(allocator, .ok);
    defer response.deinit();

    try response.addVia(.{
        .protocol = .udp,
        .address = .{ .host = "192.168.1.100", .port = 5060 },
        .branch = "z9hG4bK776asdhds",
        .received = "192.168.1.100",
    });

    try response.addContact(.{
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

    const message = try response.encode(allocator);
    defer allocator.free(message);

    const expected_message = "SIP/2.0 200 OK\r\n" ++
        "Via: SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds;received=192.168.1.100\r\n" ++
        "To: <sip:user@example.com>;tag=server-tag\r\n" ++
        "From: <sip:user@example.com>;tag=123456\r\n" ++
        "Call-ID: 1234567890abcdef@192.168.1.100\r\n" ++
        "CSeq: 1 REGISTER\r\n" ++
        "Contact: <sip:user@192.168.1.100>;expires=3600\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    try std.testing.expectEqualStrings(message, expected_message);
}
