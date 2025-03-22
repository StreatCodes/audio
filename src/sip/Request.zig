const std = @import("std");
const headers = @import("./headers.zig");
const mem = std.mem;
const debug = std.debug;
const ArrayList = std.ArrayList;

pub const RequestError = error{
    InvalidMessage,
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

pub fn init(alloactor: mem.Allocator) Request {
    return Request{ .via = ArrayList(headers.ViaHeader).init(alloactor), .contact = ArrayList(headers.ContactHeader).init(alloactor), .allow = ArrayList(headers.Method).init(alloactor), .supported = ArrayList(headers.Extension).init(alloactor) };
}

pub fn deinit(self: Request) void {
    self.via.deinit();
    self.contact.deinit();
    self.allow.deinit();
    self.supported.deinit();
}

pub fn parse(self: *Request, message_text: []const u8) !void {
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
                try self.via.append(via);
            },
            .max_forwards => self.max_forwards = try std.fmt.parseInt(u32, value, 10),
            .from => self.from = try headers.FromHeader.parse(value),
            .to => self.to = try headers.ToHeader.parse(value),
            .call_id => self.call_id = value,
            .cseq => self.sequence = try headers.Sequence.parse(value),
            .user_agent => self.user_agent = value,
            .contact => {
                const contact = try headers.ContactHeader.parse(value);
                try self.contact.append(contact);
            },
            .expires => self.expires = try std.fmt.parseInt(u32, value, 10),
            .allow => {
                var iter = std.mem.tokenizeScalar(u8, value, ',');
                while (iter.next()) |method_text| {
                    const trimmed = mem.trim(u8, method_text, " ");
                    try self.allow.append(try headers.Method.fromString(trimmed));
                }
            },
            .content_length => self.content_length = try std.fmt.parseInt(u32, value, 10),
            .content_type => self.content_type = value,
            .supported => {
                var iter = std.mem.tokenizeScalar(u8, value, ',');
                while (iter.next()) |extension_text| {
                    const trimmed = mem.trim(u8, extension_text, " ");
                    try self.supported.append(try headers.Extension.fromString(trimmed));
                }
            },
        }
    }

    self.body = lines.rest();
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
