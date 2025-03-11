const std = @import("std");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const net = std.net;
const sip = @import("./sip.zig");

//TODO
//learn how to correctly handle REGISTER requests, probably need a session, something like this

// const Session = struct {
//     remote_addr: []const u8,
//     branch: []const u8,
//     user: []const u8, //TODO we need to define a struct for this
//     user_tag: []const u8, // put in the above?
//     call_id: []const u8,
// }

const UDP_MAX_PAYLOAD = 65507;

pub fn startServer(allocator: mem.Allocator) !void {
    const port = 5060;
    const ip4_addr = "0.0.0.0";

    var buf = try allocator.alloc(u8, UDP_MAX_PAYLOAD);
    defer allocator.free(buf);

    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(sockfd);

    const addr = try net.Address.resolveIp(ip4_addr, port);
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    debug.print("Listening {s}:{d}\n", .{ ip4_addr, port });

    var client_addr: posix.sockaddr = undefined;
    var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    while (true) {
        const recv_bytes = try posix.recvfrom(sockfd, buf, 0, &client_addr, &client_addr_len);
        const message = std.mem.trimLeft(u8, buf[0..recv_bytes], "\r\n");
        if (message.len == 0) {
            debug.print("Empty messaage, skipping\n", .{});
            continue;
        }

        debug.print("Recieved request from {s}\n{s}", .{ client_addr.data, message });

        var request = sip.Message.init(allocator, .request);
        try request.parse(message);
        defer request.deinit();

        var response = sip.Message.init(allocator, .response);
        defer response.deinit();
        switch (request.method.?) {
            .register => try handleRegister(allocator, request, &response),
            else => debug.print("Unknown message:\n{s}\n", .{message}),
        }

        var response_builder = std.ArrayList(u8).init(allocator);
        defer response_builder.deinit();
        const writer = response_builder.writer();

        try response.encode(writer);
        const send_bytes = try posix.sendto(sockfd, response_builder.items, 0, &client_addr, client_addr_len);
        debug.print("Responded with {d} bytes\n{s}", .{ send_bytes, response_builder.items });
    }
}

fn handleRegister(allocator: mem.Allocator, request: sip.Message, response: *sip.Message) !void {
    response.status = 200;

    const via_header = try request.headers.get("Via").?.clone();
    var to_header = try request.headers.get("To").?.clone();
    const from_header = try request.headers.get("From").?.clone();
    const call_id_header = try request.headers.get("Call-ID").?.clone();
    const cseq_header = try request.headers.get("CSeq").?.clone();
    var contact_header = try request.headers.get("Contact").?.clone();

    try to_header.parameters.put("tag", "random-value-todo");
    try contact_header.parameters.put("expires", "300");

    try response.headers.put("Via", via_header); //rport needs to be filled
    try response.headers.put("To", to_header);
    try response.headers.put("From", from_header);
    try response.headers.put("Call-ID", call_id_header);
    try response.headers.put("CSeq", cseq_header);
    try response.headers.put("Contact", contact_header);
    try response.headers.put("Date", try sip.Header.parse(allocator, "Sun, 09 Mar 2025 12:00:00 GMT")); //TODO calculate from time
    try response.headers.put("Server", try sip.Header.parse(allocator, "StreatsSIP/0.1"));
    try response.headers.put("Content-Length", try sip.Header.parse(allocator, "0")); //TODO calculate from body
}

//RECEIVED
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

//EXPECTED RESPONSE
// SIP/2.0 200 OK
// Via: SIP/2.0/UDP 192.168.1.130:54216;rport=54216;branch=z9hG4bKPjVCXUYxi5CwuolMrq3U0IT1X8sXsgWDoh;received=192.168.1.130
// From: "Streats" <sip:streats@localhost>;tag=BXQAqfzJoJqWw3c9uJS71bwCq-WuaNtW
// To: "Streats" <sip:streats@localhost>;tag=as58f4d025
// Call-ID: jOyTomQC6PHEVeOXxOyxFV8drOmzbrs7
// CSeq: 13265 REGISTER
// Contact: <sip:streats@192.168.1.130:54216;ob>;expires=300
// Server: SIP Server/1.0
// Date: Mon, 10 Mar 2025 12:00:00 GMT
// Content-Length: 0

//OUR RESPONSE
// SIP/2.0 200 OK
// Via: "Streats" <sip:streats@localhost>
// To: "Streats" <sip:streats@localhost>;tag=as58f72bd1
// From: "Streats" <sip:streats@localhost>
// Call-ID: jOyTomQC6PHEVeOXxOyxFV8drOmzbrs7
// CSeq: 13265 REGISTER
// Contact: "Streats" <sip:streats@172.20.10.4:55595;ob>;expires=300
// Date: Sun, 09 Mar 2025 12:00:00 GMT
// Server: StreatsSIP/0.1
// Content-Length: 0

// Recieved REGISTER request from ??
// REGISTER sip:localhost SIP/2.0
// Via: SIP/2.0/UDP 192.168.1.130:54216;rport;branch=z9hG4bKPjP4d9xhAA5-1wraS89omw5uJqu6MGYIbz
// Max-Forwards: 70
// From: "Streats" <sip:streats@localhost>;tag=TyPbg19FhWXb2tB5xwvVNo8GPv0FNyay
// To: "Streats" <sip:streats@localhost>
// Call-ID: FCkNDKizKeK0QTkVArmuWZfudz3S3VLI
// CSeq: 56000 REGISTER
// User-Agent: Telephone 1.6
// Contact: "Streats" <sip:streats@192.168.1.130:54216;ob>
// Expires: 300
// Allow: PRACK, INVITE, ACK, BYE, CANCEL, UPDATE, INFO, SUBSCRIBE, NOTIFY, REFER, MESSAGE, OPTIONS
// Content-Length:  0

// Responded with 368 bytes
// Via: SIP/2.0/UDP 192.168.1.130:54216
// From: "Streats" <sip:streats@localhost>
// Contact: "Streats" <sip:streats@192.168.1.130:54216;expires=300
