const std = @import("std");
const CircularQueue = @import("circular_queue.zig").CircularQueue;

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();
        const Queue = CircularQueue(T);

        queue: Queue,
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},
        is_closed: bool = false,

        pub fn init(items: []T) Self {
            return .{
                .queue = Queue.init(items),
            };
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.isFull()) {
                if (self.is_closed) return error.Closed;
                self.not_full.wait(&self.mutex);
            }

            if (self.is_closed) return error.Closed;
            self.queue.push(item);
            self.not_empty.signal();
        }

        pub fn tryPush(self: *Self, item: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed or self.queue.isFull()) return false;

            self.queue.push(item);
            self.not_empty.signal();

            return true;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.queue.isEmpty()) {
                if (self.is_closed) return null;
                self.not_empty.wait(&self.mutex);
            }

            const item = self.queue.pop();
            self.not_full.signal();
            return item;
        }

        pub fn tryPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.isEmpty()) return null;

            const item = self.queue.pop();
            self.not_full.signal();
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.is_closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }
    };
}

const expectEqual = std.testing.expectEqual;

test "hello" {
    var items: [8]usize = undefined;
    var channel = Channel(usize).init(&items);
    defer channel.close();

    for (0..6) |i| try channel.push(i);
    for (0..6) |i| try expectEqual(i, channel.pop().?);
}
