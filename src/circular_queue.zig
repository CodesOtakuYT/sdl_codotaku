const std = @import("std");
const assert = std.debug.assert;

pub fn CircularQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Index = usize;

        items: [*]T,
        mask: Index,
        head: Index = 0,
        tail: Index = 0,

        pub fn init(items: []T) Self {
            assert(std.math.isPowerOfTwo(items.len));
            return .{
                .items = items.ptr,
                .mask = items.len - 1,
            };
        }

        fn index(self: *const Self, i: Index) Index {
            return i & self.mask;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == self.tail;
        }

        pub fn isFull(self: *const Self) bool {
            return self.head == self.index(self.tail + 1);
        }

        pub fn push(self: *Self, item: T) void {
            assert(!self.isFull());
            self.items[self.tail] = item;
            self.tail = self.index(self.tail + 1);
        }

        pub fn pop(self: *Self) T {
            assert(!self.isEmpty());
            const item = self.items[self.head];
            self.head = self.index(self.head + 1);
            return item;
        }
    };
}
