const std = @import("std");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const net = std.net;
const sip = @import("./sip.zig");

//TODO
//Get next message from replying to register message with real response

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
        const message = buf[0..recv_bytes];

        var request = try sip.Request.parse(allocator, message);
        defer request.deinit();

        debug.print("Recieved {s} request from {s}\n{s}", .{ request.method.toString(), client_addr.data, message });

        var response = sip.Response.init(allocator);
        defer response.deinit();
        switch (request.method) {
            .register => try handleRegister(allocator, request, &response),
            else => debug.print("Unknown message:\n{s}\n", .{message}),
        }

        const response_message = try response.encode();
        const send_bytes = try posix.sendto(sockfd, response_message, 0, &client_addr, client_addr_len);
        debug.print("Responded with {d} bytes\n{s}", .{ send_bytes, response_message });
    }
}

fn handleRegister(allocator: mem.Allocator, request: sip.Request, response: *sip.Response) !void {
    response.statusCode = 200;

    const via_header = request.headers.get("Via") orelse return sip.SIPError.InvalidRequest;
    const from_header = request.headers.get("From") orelse return sip.SIPError.InvalidRequest;
    const to_header = request.headers.get("To") orelse return sip.SIPError.InvalidRequest;
    const call_id_header = request.headers.get("Call-ID") orelse return sip.SIPError.InvalidRequest;
    const cseq_header = request.headers.get("CSeq") orelse return sip.SIPError.InvalidRequest;
    const contact_header = request.headers.get("Contact") orelse return sip.SIPError.InvalidRequest;

    var to = try sip.Header.parse(allocator, to_header.value);
    try to.parameters.put("tag", "random-value-todo");

    var contact = try sip.Header.parse(allocator, contact_header.value);
    try contact.parameters.put("expires", "300");

    try response.headers.put("Via", try sip.Header.parse(allocator, via_header.value)); //rport needs to be filled
    try response.headers.put("To", to);
    try response.headers.put("From", try sip.Header.parse(allocator, from_header.value));
    try response.headers.put("Call-ID", try sip.Header.parse(allocator, call_id_header.value));
    try response.headers.put("CSeq", try sip.Header.parse(allocator, cseq_header.value));
    try response.headers.put("Contact", contact);
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
