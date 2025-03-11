const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const fmt = std.fmt;

pub const SIPError = error{
    InvalidMessage,
    InvalidMethod,
    InvalidHeader,
    InvalidStatusCode,
};

pub const Header = struct {
    const HeaderParamters = std.array_hash_map.StringArrayHashMap([]const u8);

    value: []const u8,
    parameters: HeaderParamters,

    //TODO we should trim these values
    pub fn parse(allocator: mem.Allocator, header_text: []const u8) !Header {
        var header: Header = undefined;

        var tokens = mem.tokenizeScalar(u8, header_text, ';');
        header.value = tokens.next() orelse return SIPError.InvalidHeader;
        header.parameters = HeaderParamters.init(allocator);

        while (tokens.next()) |token| {
            var param_tokens = mem.splitScalar(u8, token, '=');
            const param_field = param_tokens.next() orelse return SIPError.InvalidHeader;
            const param_value = param_tokens.next();
            if (param_tokens.next() != null) return SIPError.InvalidHeader;

            try header.parameters.put(param_field, param_value orelse "");
        }

        return header;
    }

    pub fn encode(self: Header, writer: anytype) !void {
        try writer.writeAll(self.value);

        var iter = self.parameters.iterator();
        while (iter.next()) |param| {
            const field = param.key_ptr.*;
            const value = param.value_ptr.*;

            try writer.print(";{s}", .{field});

            if (value.len > 0) {
                try writer.print("={s}", .{value});
            }
        }
    }

    pub fn clone(self: Header) !Header {
        return Header{
            .value = self.value,
            .parameters = try self.parameters.clone(),
        };
    }
};

//TODO Status should really be an enum
fn statusCodeToString(status_code: u32) ![]const u8 {
    switch (status_code) {
        200 => return "OK",
        else => return SIPError.InvalidStatusCode,
    }
}

const Method = enum {
    register,
    invite,
    ack,
    cancel,
    bye,
    options,

    pub fn fromString(method: []const u8) !Method {
        if (std.mem.eql(u8, method, "REGISTER")) return Method.register;
        if (std.mem.eql(u8, method, "INVITE")) return Method.invite;
        if (std.mem.eql(u8, method, "ACK")) return Method.ack;
        if (std.mem.eql(u8, method, "CANCEL")) return Method.cancel;
        if (std.mem.eql(u8, method, "BYE")) return Method.bye;
        if (std.mem.eql(u8, method, "OPTIONS")) return Method.options;
        return SIPError.InvalidMethod;
    }

    pub fn toString(self: Method) []const u8 {
        switch (self) {
            .register => return "REGISTER",
            .invite => return "INVITE",
            .ack => return "ACK",
            .cancel => return "CANCEL",
            .bye => return "BYE",
            .options => return "OPTIONS",
        }
    }
};

const MessageType = union(enum) {
    request,
    response,
};

pub const Message = struct {
    const Headers = std.array_hash_map.StringArrayHashMap(Header);

    allocator: mem.Allocator,
    message_type: MessageType,
    method: ?Method,
    uri: ?[]const u8,
    status: ?u32,
    headers: Headers,
    body: []const u8,

    pub fn init(allocator: mem.Allocator, message_type: MessageType) Message {
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

                self.method = try Method.fromString(method);
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

            const header = try Header.parse(self.allocator, value);

            //TODO this needs to be getOrPut to append when duplicate headers are detected
            //Additionally, we'll need to merge the values when duplicate headers are found
            try self.headers.put(field, header);
        }

        self.body = lines.rest();
    }

    pub fn encode(self: *Message, writer: anytype) !void {
        //TODO validation and handle MessageType.request
        try writer.print("SIP/2.0 {d} {s}\r\n", .{ self.status.?, try statusCodeToString(self.status.?) });

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

//TODO this test is brittle
test "Requests are correctly generated" {
    const allocator = std.testing.allocator;
    var response = Message.init(allocator, .response);
    defer response.deinit();

    response.status = 200;

    try response.headers.put("Via", try Header.parse(allocator, "SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds;received=192.168.1.100"));
    try response.headers.put("To", try Header.parse(allocator, "<sip:user@example.com>;tag=server-tag"));
    try response.headers.put("From", try Header.parse(allocator, "<sip:user@example.com>;tag=123456"));
    try response.headers.put("Call-ID", try Header.parse(allocator, "1234567890abcdef@192.168.1.100"));
    try response.headers.put("CSeq", try Header.parse(allocator, "1 REGISTER"));
    try response.headers.put("Contact", try Header.parse(allocator, "<sip:user@192.168.1.100:5060>;expires=3600"));
    try response.headers.put("Date", try Header.parse(allocator, "Sat, 08 Mar 2025 12:00:00 GMT"));
    try response.headers.put("Server", try Header.parse(allocator, "StreatsSIP/0.1"));
    try response.headers.put("Content-Length", try Header.parse(allocator, "0"));

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
        "Contact: <sip:user@192.168.1.100:5060>;expires=3600\r\n" ++
        "Date: Sat, 08 Mar 2025 12:00:00 GMT\r\n" ++
        "Server: StreatsSIP/0.1\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    try std.testing.expect(std.mem.eql(u8, message_builder.items, expected_message));
}
