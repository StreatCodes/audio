const std = @import("std");

/// A convenience wrapper around `std.StringHashMap` which dupes the key value
/// for easier memory management. It is the callers responsibility to free the
/// contents of the values. This wrapper also ensures thread saftey.
pub fn Bucket(
    comptime T: type,
) type {
    const Transaction = struct {
        io: std.Io,
        value: *T,
        lock: *std.Io.RwLock,

        const Self = @This();

        pub fn deinit(transaction: Self) void {
            transaction.lock.unlock(transaction.io);
        }
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        map: std.StringHashMap(T),
        lock: std.Io.RwLock,

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .lock = .init,
                .map = .init(allocator),
            };
        }

        pub fn deinit(bucket: *Self) void {
            var iter = bucket.map.iterator();
            while (iter.next()) |entry| {
                bucket.allocator.free(entry.key_ptr.*);
            }

            bucket.map.deinit();
        }

        /// Clobbers any existing data. The key will be duplicated and freed
        /// when `Bucket.deinit` is called. The key will only be duplicated
        /// if the bucket does not already contain that key.
        pub fn put(bucket: *Self, key: []const u8, value: T) !void {
            try bucket.lock.lock(bucket.io);
            defer bucket.lock.unlock(bucket.io);

            if (bucket.map.contains(key)) {
                return try bucket.map.put(key, value);
            }

            const new_key = try bucket.allocator.dupe(u8, key);
            try bucket.map.put(new_key, value);
        }

        /// Finds the value associated with a key in the bucket
        pub fn get(bucket: *Self, key: []const u8) std.Io.Cancelable!?T {
            try bucket.lock.lockShared(bucket.io);
            defer bucket.lock.unlockShared(bucket.io);

            return bucket.map.get(key);
        }

        /// Returns a `Transaction` if the key is in the bucket. While the transaction
        /// is active the bucket will be locked. It's the consumer's responsibility to
        /// deinit the `Transaction` so the bucket can be unlocked. This function returns
        /// null and no cleanup is required if the given key is not found.
        pub fn getPtr(bucket: *Self, key: []const u8) std.Io.Cancelable!?Transaction {
            try bucket.lock.lock(bucket.io);

            const value = bucket.map.getPtr(key) orelse {
                bucket.lock.unlock(bucket.io);
                return null;
            };

            return .{
                .io = bucket.io,
                .value = value,
                .lock = &bucket.lock,
            };
        }

        /// Returns true if the bucket contains the key
        pub fn contains(bucket: *Self, key: []const u8) std.Io.Cancelable!bool {
            try bucket.lock.lockShared(bucket.io);
            defer bucket.lock.unlockShared(bucket.io);

            return bucket.map.contains(key);
        }

        /// If there is an Entry with a matching key, it is deleted from the hash map,
        /// and this function returns true. Otherwise this function returns false.
        /// Additionally, if an Entry is found the associated Key will be freed.
        pub fn remove(bucket: *Self, key: []const u8) std.Io.Cancelable!bool {
            try bucket.lock.lock(bucket.io);
            defer bucket.lock.unlock(bucket.io);

            if (bucket.map.getKey(key)) |existing_key| {
                defer bucket.allocator.free(existing_key);
                return bucket.map.remove(existing_key);
            }

            return false;
        }
    };
}
