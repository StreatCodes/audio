const std = @import("std");

pub const Header = packed struct {
    fileTypeBlocID: u32, // actually [4]u8 - Identifier « RIFF »  (0x52, 0x49, 0x46, 0x46)
    fileSize: u32, // Overall file size minus 8 bytes
    fileFormatID: u32, // actually [4]u8 - Format = « WAVE »  (0x57, 0x41, 0x56, 0x45)

    formatBlocID: u32, // actually [4]u8 - Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
    blocSize: u32, // Chunk size minus 8 bytes, which is 16 bytes here  (0x10)
    audioFormat: u16, // Audio format (1: PCM integer, 3: IEEE 754 float)
    nbrChannels: u16, // Number of channels
    frequency: u32, // Sample rate (in hertz)
    bytePerSec: u32, // Number of bytes to read per second (Frequency * BytePerBloc).
    bytePerBloc: u16, // Number of bytes per block (NbrChannels * BitsPerSample / 8).
    bitsPerSample: u16, // Number of bits per sample

    dataBlocID: u32, // actually [4]u8 - Identifier « data »  (0x64, 0x61, 0x74, 0x61)
    dataSize: u32, // SampledData size
};

pub const Wav = struct {
    header: Header,
    data: []const u8,

    pub fn parse(file: []const u8) Wav {
        const header_end = @sizeOf(Header);
        const data = file[0..header_end];

        const header = std.mem.bytesToValue(Header, data);
        return Wav{
            .header = header,
            .data = file[header_end..],
        };
    }
};
