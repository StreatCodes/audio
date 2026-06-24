const std = @import("std");
const util = @import("util.zig");
const headers = @import("../sip/headers.zig");
const Registration = @import("Registration.zig");
const Message = @import("../sip/Message.zig");
const Transaction = @import("Transaction.zig");
const TransactionState = Transaction.TransactionState;

const Service = @This();

pub const ServiceError = error{
    MaxForwardsExceeded,
    NotRegistered,
    RecipientNotFound,
};

gpa: std.mem.Allocator,
io: std.Io,
transactions: util.Bucket(Transaction),
registrations: util.Bucket(Registration),

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Service {
    return Service{
        .gpa = gpa,
        .io = io,
        .transactions = .init(gpa, io),
        .registrations = .init(gpa, io),
    };
}

pub fn deinit(service: *Service) void {
    service.transactions.deinit();
    service.registrations.deinit();
}

pub fn start(service: *Service, listen_address: []const u8, listen_port: u16) !void {
    const address = try std.Io.net.IpAddress.parse(listen_address, listen_port);
    var server = try std.Io.net.IpAddress.listen(&address, service.io, .{});
    defer server.deinit(service.io);

    std.debug.print("Starting server {s}:{d}\n", .{ listen_address, listen_port });

    while (true) {
        const stream = try server.accept(service.io);
        std.debug.print("New connection {}\n", .{stream.socket.address});

        //TODO not sure if this is ok to fire and forget
        _ = service.io.async(handleConn, .{ service, stream });
    }
}

pub fn handleConn(service: *Service, stream: std.Io.net.Stream) !void {
    defer stream.close(service.io);
    service.readMessages(stream) catch |err| {
        switch (err) {
            else => {
                std.debug.print("Error reading message {}\n", .{err});
            },
        }
    };

    std.debug.print("Connection closed {}\n", .{stream.socket.address});
}

pub fn readMessages(service: *Service, stream: std.Io.net.Stream) !void {
    const reader_buffer = try service.gpa.alloc(u8, 4096);
    defer service.gpa.free(reader_buffer);
    var reader = stream.reader(service.io, reader_buffer);

    while (true) {
        const max_sip_size = 65535;
        const message_buffer = try service.gpa.alloc(u8, max_sip_size);
        defer service.gpa.free(message_buffer);

        var message = try Message.readMessage(service.gpa, &reader.interface, message_buffer);
        defer message.deinit();
        std.debug.print("Recieved [{s}]\n", .{message.raw_message});

        const branch = try message.branch();

        // Existing transaction
        if (try service.transactions.get(branch)) |transaction| {
            std.debug.print("existing transaction {s}\n", .{branch});
            try service.handleMessage(transaction, message);
            return;
        }

        // New transaction
        switch (message.start_line) {
            .request => |request_line| {
                std.debug.print("new transaction {s}\n", .{branch});

                const transaction = Transaction{
                    .method = request_line.method,
                    .state = if (request_line.method == .invite) .proceeding else .trying,
                    .stream = stream,
                };

                try service.transactions.put(branch, transaction);
                try service.handleMessage(transaction, message);
            },
            .response => {
                std.debug.print("Unknown transaction response, ignoring {s}\n", .{branch});
            },
        }
    }
}

pub fn handleMessage(service: *Service, transaction: Transaction, message: Message) !void {
    const new_state = switch (transaction.method) {
        .register => try transaction.handleRegister(service, message),
        else => blk: {
            // TODO reply not implemented
            break :blk TransactionState.completed;
        },
    };

    // If the transaction is complete we can stop tracking it, otherwise update it
    const branch = try message.branch();
    if (new_state == .completed) {
        _ = try service.transactions.remove(branch);
    } else {
        try service.transactions.put(branch, .{
            .method = transaction.method,
            .state = new_state,
            .stream = transaction.stream,
        });
    }
}
