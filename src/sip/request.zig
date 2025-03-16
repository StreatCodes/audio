const std = @import("std");
const response = @import("./response.zig");
const headers = @import("./headers.zig");
const mem = std.mem;
const debug = std.debug;

const Request = @This();

method: headers.Method,
uri: []const u8,

via: headers.ViaHeader,
max_forwards: u32,
from: headers.FromHeader,
to: headers.ToHeader,
call_id: []const u8,
sequence: headers.Sequence,
user_agent: ?[]const u8,
contact: ?[]headers.Contact,
expires: ?u32,
allow: ?[]headers.Method,
content_length: ?u32,

body: []const u8,

pub fn parse(allocator: mem.Allocator, message_text: []const u8) !Request {
    var request: Request = undefined;

    var lines = std.mem.splitSequence(u8, message_text, "\r\n");
    const first_line = lines.next() orelse return response.SIPError.InvalidMessage;

    //Parse the request line
    var first_line_values = std.mem.splitScalar(u8, first_line, ' ');

    const method = first_line_values.next() orelse return response.SIPError.InvalidMessage;
    const uri = first_line_values.next() orelse return response.SIPError.InvalidMessage;
    const version = first_line_values.next() orelse return response.SIPError.InvalidMessage;

    request.method = try headers.Method.fromString(method);
    request.uri = uri;
    if (!std.mem.eql(u8, version, "SIP/2.0")) return response.SIPError.InvalidMessage;

    //Parse the headers
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "")) break;

        const splitIndex = std.mem.indexOfScalar(u8, line, ':') orelse return response.SIPError.InvalidHeader;
        const field = std.mem.trim(u8, line[0..splitIndex], " ");
        const value = std.mem.trim(u8, line[splitIndex + 1 ..], " ");

        const header_field = try headers.Header.fromString(field);

        switch (header_field) {
            .via => request.via = try headers.ViaHeader.parse(value),
            .max_forwards => request.max_forwards = try std.fmt.parseInt(u32, value, 10),
            // from
            // to
            .call_id => request.call_id = value,
            .cseq => request.sequence = try headers.Sequence.parse(value),
            .user_agent => request.user_agent = value,
            // contact
            .expires => request.expires = try std.fmt.parseInt(u32, value, 10),
            .allow => {
                var iter = std.mem.tokenizeScalar(u8, value, ',');
                var allow_methods = std.ArrayList(headers.Method).init(allocator);
                while (iter.next()) |method_text| {
                    const trimmed = mem.trim(u8, method_text, " ");
                    try allow_methods.append(try headers.Method.fromString(trimmed));
                }
                request.allow = try allow_methods.toOwnedSlice();
            },
            .content_length => request.content_length = try std.fmt.parseInt(u32, value, 10),
            else => debug.print("Unknown header {s}: {s}\n", .{ field, value }),
        }
    }

    request.body = lines.rest();
    return request;
}

pub fn deinit(self: *Request, allocator: mem.Allocator) void {
    if (self.allow) |allow| {
        allocator.free(allow);
    }
}

// REGISTER sip:localhost SIP/2.0
// Via: SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh
// Max-Forwards: 70
// From: "Streats" <sip:streats@localhost>;tag=BXQAqfzJoJqWw3c9uJS71bwCq-WuaNtW
// To: "Streats" <sip:streats@localhost>
// Call-ID: jOyTomQC6PHEVeOXxOyxFV8drOmzbrs7
// CSeq: 13265 REGISTER
// User-Agent: Telephone 1.6
// Contact: "Streats" <sip:streats@192.168.1.130:54216;ob>
// Expires: 300
// Allow: PRACK, INVITE, ACK, BYE, CANCEL, UPDATE, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS
// Content-Length:  0

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
    var request = try Request.parse(allocator, message);
    defer request.deinit(allocator);

    try std.testing.expect(request.method == .register);
    try std.testing.expect(std.mem.eql(u8, request.uri, "sip:localhost"));
    try std.testing.expect(std.mem.eql(u8, request.body, ""));
}
