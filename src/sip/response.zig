const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;
const headers = @import("./headers.zig");

pub const SIPError = error{
    InvalidMessage,
    InvalidMethod,
    InvalidHeader,
    InvalidStatusCode,
};

pub const Message = struct {
    const Headers = std.array_hash_map.StringArrayHashMap(headers.Header);

    allocator: mem.Allocator,
    message_type: headers.MessageType,
    method: ?headers.Method,
    uri: ?[]const u8,
    status: ?u32,
    headers: Headers,
    body: []const u8,

    pub fn init(allocator: mem.Allocator, message_type: headers.MessageType) Message {
        return Message{
            .allocator = allocator,
            .message_type = message_type,
            .method = null,
            .uri = null,
            .status = null,
            .headers = Headers.init(allocator),
            .body = &[_]u8{},
        };
    }

    pub fn deinit(self: *Message) void {
        var iter = self.headers.iterator();
        while (iter.next()) |header| {
            header.value_ptr.*.parameters.deinit();
        }
        self.headers.deinit();
    }

    pub fn parse(self: *Message, message_text: []const u8) !void {
        var lines = std.mem.splitSequence(u8, message_text, "\r\n");
        const first_line = lines.next() orelse return SIPError.InvalidMessage;

        var first_line_values = std.mem.splitScalar(u8, first_line, ' ');

        //Parse the first line
        switch (self.message_type) {
            .request => {
                const method = first_line_values.next() orelse return SIPError.InvalidMessage;
                const uri = first_line_values.next() orelse return SIPError.InvalidMessage;
                const version = first_line_values.next() orelse return SIPError.InvalidMessage;

                self.method = try headers.Method.fromString(method);
                self.uri = uri;
                if (!std.mem.eql(u8, version, "SIP/2.0")) return SIPError.InvalidMessage;
            },
            .response => {
                const version = first_line_values.next() orelse return SIPError.InvalidMessage;
                const status_code = first_line_values.next() orelse return SIPError.InvalidMessage;
                // const status_text = first_line_values.next() orelse return SIPError.InvalidMessage;

                if (!std.mem.eql(u8, version, "SIP/2.0")) return SIPError.InvalidMessage;
                self.status = try fmt.parseInt(u32, status_code, 10);
            },
        }

        //Parse the headers
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "")) break;

            const splitIndex = std.mem.indexOfScalar(u8, line, ':') orelse return SIPError.InvalidHeader;
            const field = std.mem.trim(u8, line[0..splitIndex], " ");
            const value = std.mem.trim(u8, line[splitIndex + 1 ..], " ");

            const header = try headers.Header.parse(self.allocator, value);

            //TODO this needs to be getOrPut to append when duplicate headers are detected
            //Additionally, we'll need to merge the values when duplicate headers are found
            try self.headers.put(field, header);
        }

        self.body = lines.rest();
    }

    pub fn encode(self: *Message, writer: anytype) !void {
        //TODO validation and handle MessageType.request
        try writer.print("SIP/2.0 {d} {s}\r\n", .{ self.status.?, try headers.statusCodeToString(self.status.?) });

        //TODO some ordering is likely required here..
        var header_iterator = self.headers.iterator();
        while (header_iterator.next()) |header| {
            const field = header.key_ptr.*;
            const value = header.value_ptr.*;

            try writer.print("{s}: ", .{field});
            try value.encode(writer);
            try writer.writeAll("\r\n");
        }

        try writer.writeAll("\r\n");
        try writer.writeAll(self.body);
        //TODO do i need to write /r/n next?
    }
};

test "sip can correctly parse a SIP REGISTER message" {
    const message = "REGISTER sip:localhost SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 172.20.10.4:55595;rport;branch=z9hG4bKPj97wgnQ5d7IM3cfDd2QYcYf9H8hqJLxit\r\n" ++
        "Max-Forwards: 70\r\n" ++
        "From: \"Streats\" <sip:streats@localhost>;tag=Z.hw-WnzbyImNj0P.WWHJW9zhtQc1lm8\r\n" ++
        "To: \"Streats\" <sip:streats@localhost>\r\n" ++
        "Call-ID: xGAGzEIoe5SHqQnmK5W2jWsIF7kThRbn\r\n" ++
        "CSeq: 37838 REGISTER\r\n" ++
        "User-Agent: Telephone 1.6\r\n" ++
        "Contact: \"Streats\" <sip:streats@172.20.10.4:55595;ob>\r\n" ++
        "Expires: 300\r\n" ++
        "Allow: PRACK, INVITE, ACK, BYE, CANCEL, UPDATE, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS\r\n" ++
        "Content-Length:  0\r\n" ++
        "\r\n";

    const allocator = std.testing.allocator;
    var request = Message.init(allocator, .request);
    defer request.deinit();

    try request.parse(message);

    try std.testing.expect(request.method == .register);
    try std.testing.expect(std.mem.eql(u8, request.uri.?, "sip:localhost"));
    try std.testing.expect(std.mem.eql(u8, request.body, ""));
}
