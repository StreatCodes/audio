const std = @import("std");

pub const Header = packed struct {
    file_type_bloc_id: u32, // actually [4]u8 - Identifier « RIFF »  (0x52, 0x49, 0x46, 0x46)
    file_size: u32, // Overall file size minus 8 bytes
    file_format_id: u32, // actually [4]u8 - Format = « WAVE »  (0x57, 0x41, 0x56, 0x45)

    format_bloc_id: u32, // actually [4]u8 - Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
    bloc_size: u32, // Chunk size minus 8 bytes, which is 16 bytes here  (0x10)
    audio_format: u16, // Audio format (1: PCM integer, 3: IEEE 754 float)
    nbr_channels: u16, // Number of channels
    frequency: u32, // Sample rate (in hertz)
    byte_per_sec: u32, // Number of bytes to read per second (Frequency * BytePerBloc).
    byte_per_bloc: u16, // Number of bytes per block (NbrChannels * BitsPerSample / 8).
    bits_per_sample: u16, // Number of bits per sample

    data_bloc_id: u32, // actually [4]u8 - Identifier « data »  (0x64, 0x61, 0x74, 0x61)
    data_size: u32, // SampledData size
};

pub const Wav = struct {
    header: Header,
    data: []const u8,

    pub fn parse(file: []const u8) Wav {
        const header_end = @sizeOf(Header);
        const header_data = file[0..header_end];

        const header = std.mem.bytesToValue(Header, header_data);
        return Wav{
            .header = header,
            .data = file[header_end..],
        };
    }
};
