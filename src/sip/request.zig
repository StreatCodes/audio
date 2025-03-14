const std = @import("std");
const response = @import("./response.zig");
const headers = @import("./headers.zig");

//TODO this test is brittle
test "Requests are correctly generated" {
    const allocator = std.testing.allocator;
    var res = response.Message.init(allocator, .response);
    defer res.deinit();

    res.status = 200;

    try res.headers.put("Via", try headers.Header.parse(allocator, "SIP/2.0/UDP 192.168.1.100:5060;branch=z9hG4bK776asdhds;received=192.168.1.100"));
    try res.headers.put("To", try headers.Header.parse(allocator, "<sip:user@example.com>;tag=server-tag"));
    try res.headers.put("From", try headers.Header.parse(allocator, "<sip:user@example.com>;tag=123456"));
    try res.headers.put("Call-ID", try headers.Header.parse(allocator, "1234567890abcdef@192.168.1.100"));
    try res.headers.put("CSeq", try headers.Header.parse(allocator, "1 REGISTER"));
    try res.headers.put("Contact", try headers.Header.parse(allocator, "<sip:user@192.168.1.100:5060>;expires=3600"));
    try res.headers.put("Date", try headers.Header.parse(allocator, "Sat, 08 Mar 2025 12:00:00 GMT"));
    try res.headers.put("Server", try headers.Header.parse(allocator, "StreatsSIP/0.1"));
    try res.headers.put("Content-Length", try headers.Header.parse(allocator, "0"));

    var message_builder = std.ArrayList(u8).init(allocator);
    defer message_builder.deinit();
    const writer = message_builder.writer();

    try res.encode(writer);

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
