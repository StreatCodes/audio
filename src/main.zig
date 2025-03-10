const std = @import("std");
const wav = @import("./wav.zig");
const l16 = @import("./l16.zig");
const server = @import("./server.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    try server.startServer(allocator);

    // var dir = std.fs.cwd();
    // const file_name = "./wars.wav";
    // const file = try dir.readFileAlloc(allocator, file_name, 100_000_000);
    // defer allocator.free(file);

    // const waveform = wav.Wav.parse(file);
    // std.debug.print("{any} body length: {d}\n", .{ waveform.header, waveform.data.len });

    // const samples: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, waveform.data));

    // var sesh = l16.RTP_L16.init(&allocator);

    // const port = 6969;
    // const addr = "streats.dev";
    // std.debug.print("Connecting to {s}:{d}\n", .{ addr, port });
    // var conn = try std.net.tcpConnectToHost(allocator, addr, port);
    // defer conn.close();

    // // const addr= try std.net.Address.resolveIp("streats.dev", 6969);
    // // std.posix.socket(domain: u32, socket_type: u32, protocol: u32)
    // // std.posix.connect(sock: socket_t, sock_addr: *const sockaddr, len: socklen_t)

    // const samples_per_packet = 722;
    // var i: usize = 0;
    // while (i < samples.len) : (i += samples_per_packet) {
    //     var end = i + samples_per_packet;
    //     if (end > samples.len) end = samples.len;

    //     const packet = try sesh.encodePacket(samples[i..end], false);
    //     try conn.writeAll(packet);
    //     std.debug.print("Send packet offset {d} len {d}\n", .{ i, packet.len });
    //     allocator.free(packet);
    // }
}
