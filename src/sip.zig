const std = @import("std");
const debug = std.debug;
const mem = std.mem;

pub const SIPError = error{
    InvalidRequest,
    InvalidMethod,
    InvalidHeader,
    InvalidStatusCode,
};

const HeaderParamters = std.array_hash_map.StringArrayHashMap([]const u8);
pub const Header = struct {
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

    pub fn encode(self: Header, allocator: mem.Allocator) ![]const u8 {
        var parameter_builder = std.ArrayList(u8).init(allocator);
        const writer = parameter_builder.writer();

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

        return parameter_builder.toOwnedSlice();
    }
};

const Headers = std.array_hash_map.StringArrayHashMap(Header);

fn parseHeaders(allocator: mem.Allocator, lines: *std.mem.SplitIterator(u8, .sequence)) !Headers {
    var headers = Headers.init(allocator);

    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "")) break;

        const splitIndex = std.mem.indexOfScalar(u8, line, ':') orelse return SIPError.InvalidHeader;
        const field = std.mem.trim(u8, line[0..splitIndex], " ");
        const value = std.mem.trim(u8, line[splitIndex + 1 ..], " ");

        const header = try Header.parse(allocator, value);

        //TODO this needs to be getOrPut to append when duplicate headers are detected
        //Additionally, we'll need to merge the values when duplicate headers are found
        try headers.put(field, header);
    }

    return headers;
}

fn statusCodeToString(status_code: u32) ![]const u8 {
    switch (status_code) {
        200 => return "OK",
        else => return SIPError.InvalidStatusCode,
    }
}

pub const Response = struct {
    allocator: mem.Allocator,
    statusCode: u32,
    headers: Headers,
    body: []u8,

    pub fn init(allocator: mem.Allocator) Response {
        return Response{
            .allocator = allocator,
            .statusCode = 0,
            .headers = Headers.init(allocator),
            .body = &[_]u8{},
        };
    }

    pub fn deinit(self: *Response) void {
        var iter = self.headers.iterator();
        while (iter.next()) |header| {
            header.value_ptr.*.parameters.deinit();
        }
        self.headers.deinit();
    }

    pub fn encode(self: *Response) ![]const u8 {
        var response_builder = std.ArrayList(u8).init(self.allocator);
        const writer = response_builder.writer();

        try writer.print("SIP/2.0 {d} {s}\r\n", .{ self.statusCode, try statusCodeToString(self.statusCode) });

        //TODO some ordering is likely required here..
        var header_iterator = self.headers.iterator();
        while (header_iterator.next()) |header| {
            const field = header.key_ptr.*;
            const value = header.value_ptr.*;

            const encoded_value = try value.encode(self.allocator);
            defer self.allocator.free(encoded_value);

            try writer.print("{s}: {s}\r\n", .{ field, encoded_value });
        }

        try writer.writeAll("\r\n");
        try writer.writeAll(self.body);
        //TODO do i need to write /r/n next?

        return try response_builder.toOwnedSlice();
    }
};

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

pub const Request = struct {
    allocator: mem.Allocator,
    method: Method,
    uri: []const u8,
    headers: Headers,
    body: []const u8,

    pub fn deinit(self: *Request) void {
        var iter = self.headers.iterator();
        while (iter.next()) |header| {
            header.value_ptr.*.parameters.deinit();
        }
        self.headers.deinit();
    }

    pub fn parse(allocator: mem.Allocator, message: []const u8) !Request {
        var request: Request = undefined;
        request.allocator = allocator;

        var lines = std.mem.splitSequence(u8, message, "\r\n");
        const first_line = lines.next() orelse return SIPError.InvalidRequest;

        var first_line_values = std.mem.splitScalar(u8, first_line, ' ');

        const method = first_line_values.next() orelse return SIPError.InvalidRequest;
        const uri = first_line_values.next() orelse return SIPError.InvalidRequest;
        const version = first_line_values.next() orelse return SIPError.InvalidRequest;

        request.method = try Method.fromString(method);
        request.uri = uri;
        if (!std.mem.eql(u8, version, "SIP/2.0")) return SIPError.InvalidRequest;

        request.headers = try parseHeaders(allocator, &lines);
        request.body = lines.rest();
        return request;
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

    var allocator = std.testing.allocator;
    var request = try Request.parse(&allocator, message);
    defer request.deinit();

    try std.testing.expect(request.method == .register);
    try std.testing.expect(std.mem.eql(u8, request.uri, "sip:localhost"));
    try std.testing.expect(std.mem.eql(u8, request.body, ""));
}

//TODO this test is brittle
test "Requests are correctly generated" {
    var allocator = std.testing.allocator;
    var response = Response.init(&allocator);
    defer response.deinit();

    response.statusCode = 200;

    try response.headers.put("Via", try Header.parse(&allocator, "SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds;received=192.168.1.100"));
    try response.headers.put("To", try Header.parse(&allocator, "<sip:user@example.com>;tag=server-tag"));
    try response.headers.put("From", try Header.parse(&allocator, "<sip:user@example.com>;tag=123456"));
    try response.headers.put("Call-ID", try Header.parse(&allocator, "1234567890abcdef@192.168.1.100"));
    try response.headers.put("CSeq", try Header.parse(&allocator, "1 REGISTER"));
    try response.headers.put("Contact", try Header.parse(&allocator, "<sip:user@192.168.1.100:5060>;expires=3600"));
    try response.headers.put("Date", try Header.parse(&allocator, "Sat, 08 Mar 2025 12:00:00 GMT"));
    try response.headers.put("Server", try Header.parse(&allocator, "StreatsSIP/0.1"));
    try response.headers.put("Content-Length", try Header.parse(&allocator, "0"));

    const message = try response.encode();
    defer allocator.free(message);

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

    try std.testing.expect(std.mem.eql(u8, message, expected_message));
}
