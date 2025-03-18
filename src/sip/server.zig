const std = @import("std");
const os = std.os;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const net = std.net;
const response = @import("./response.zig");
const headers = @import("./headers.zig");

const Sessions = std.StringHashMap(Session);
const UDP_MAX_PAYLOAD = 65507;

pub fn startServer(allocator: mem.Allocator, listen_address: []const u8, listen_port: u16) !void {
    var buf = try allocator.alloc(u8, UDP_MAX_PAYLOAD);
    defer allocator.free(buf);

    const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(socket);

    const address = try net.Address.resolveIp(listen_address, listen_port);
    try posix.bind(socket, &address.any, address.getOsSockLen());
    debug.print("Listening {s}:{d}\n", .{ listen_address, listen_port });

    var sessions = Sessions.init(allocator);
    defer sessions.deinit();

    //Wait for incoming datagrams and process them
    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const recv_bytes = try posix.recvfrom(socket, buf, 0, &client_addr, &client_addr_len);

        //Per the spec we need to trim any leading line breaks
        const message = std.mem.trimLeft(u8, buf[0..recv_bytes], "\r\n");

        //Clients often send empty messages (\r\n) for keep alives, ignore them
        if (message.len == 0) {
            debug.print("Empty message, skipping\n", .{});
            continue;
        }

        var request = response.Message.init(allocator, .request);
        try request.parse(message);
        defer request.deinit();

        const remote_address = try getAddressAndPort(allocator, client_addr);
        var res = response.Message.init(allocator, .response);
        defer res.deinit();

        if (sessions.getPtr(remote_address)) |session| {
            //Handle messages for existing sessions
            switch (request.method.?) {
                .register => try session.handleRegister(allocator, request, &res),
                else => debug.print("Unknown message:\n{s}\n", .{message}),
            }
        } else {
            //No session found for remote address, create one
            if (request.method.? != .register) {
                debug.print("First message must be REGISTER\n", .{});
                continue;
            }

            const session = try Session.fromRegister(allocator, request, &res);
            try sessions.put(remote_address, session);
        }

        var response_builder = std.ArrayList(u8).init(allocator);
        defer response_builder.deinit();
        const writer = response_builder.writer();

        try res.encode(writer);
        _ = try posix.sendto(socket, response_builder.items, 0, &client_addr, client_addr_len);
    }
}

pub fn getAddressAndPort(allocator: mem.Allocator, addr: posix.sockaddr) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    const address = net.Address.initPosix(@alignCast(&addr));
    try address.format("", .{}, writer);

    return buffer.toOwnedSlice();
}

const Session = struct {
    sequence: u32,
    expires: u32,
    contact: headers.Contact,
    call_id: []const u8,
    supported_methods: []headers.Method,

    fn fromRegister(allocator: mem.Allocator, request: response.Message, res: *response.Message) !Session {
        debug.print("REGISTER - New session\n", .{});
        var session: Session = undefined;
        session.sequence = 1337;

        const via_header = try request.headers.get("Via").?.clone();
        var to_header = try request.headers.get("To").?.clone();
        const from_header = try request.headers.get("From").?.clone();
        const call_id_header = try request.headers.get("Call-ID").?.clone();
        const cseq_header = try request.headers.get("CSeq").?.clone();
        var contact_header = try request.headers.get("Contact").?.clone();

        try to_header.parameters.put("tag", "random-value-todo");
        try contact_header.parameters.put("expires", "300");

        try res.headers.put("Via", via_header); //rport needs to be filled
        try res.headers.put("To", to_header);
        try res.headers.put("From", from_header);
        try res.headers.put("Call-ID", call_id_header);
        try res.headers.put("CSeq", cseq_header);
        try res.headers.put("Contact", contact_header);
        try res.headers.put("Date", try headers.Header.parse(allocator, "Sun, 09 Mar 2025 12:00:00 GMT")); //TODO calculate from time
        try res.headers.put("Server", try headers.Header.parse(allocator, "StreatsSIP/0.1"));
        try res.headers.put("Content-Length", try headers.Header.parse(allocator, "0")); //TODO calculate from body
        res.status = 200;

        return session;
    }

    fn handleRegister(self: *Session, allocator: mem.Allocator, request: response.Message, res: *response.Message) !void {
        debug.print("REGISTER - session update\n", .{});
        _ = self;
        _ = allocator;
        _ = request;
        _ = res;
    }
};

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
