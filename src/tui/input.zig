const std = @import("std");
const builtin = @import("builtin");

/// Key codes for input handling
pub const Key = union(enum) {
    char: u8,
    ctrl: u8,
    alt: u8,
    special: SpecialKey,
    mouse: MouseEvent,
    none,

    /// Check if key is a specific character
    pub fn isCharKey(self: Key, c: u8) bool {
        return switch (self) {
            .char => |ch| ch == c,
            else => false,
        };
    }

    /// Check if key is a specific special key
    pub fn isSpecialKey(self: Key, s: SpecialKey) bool {
        return switch (self) {
            .special => |sk| sk == s,
            else => false,
        };
    }

    /// Check if key is none
    pub fn isNone(self: Key) bool {
        return self == .none;
    }

    pub const SpecialKey = enum {
        up,
        down,
        left,
        right,
        home,
        end,
        page_up,
        page_down,
        insert,
        delete,
        enter,
        tab,
        backtab,
        backspace,
        escape,
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
    };

    /// Check if key matches a character
    pub fn isChar(self: Key, c: u8) bool {
        return switch (self) {
            .char => |ch| ch == c,
            else => false,
        };
    }

    /// Check if key is Ctrl+C
    pub fn isCtrlC(self: Key) bool {
        return switch (self) {
            .ctrl => |c| c == 'c' or c == 'C',
            else => false,
        };
    }

    /// Check if key is Enter
    pub fn isEnter(self: Key) bool {
        return switch (self) {
            .special => |s| s == .enter,
            else => false,
        };
    }

    /// Check if key is Escape
    pub fn isEscape(self: Key) bool {
        return switch (self) {
            .special => |s| s == .escape,
            else => false,
        };
    }

    /// Check if key is Tab
    pub fn isTab(self: Key) bool {
        return switch (self) {
            .special => |s| s == .tab,
            else => false,
        };
    }
};

/// Mouse event data
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: MouseButton,
    modifiers: Modifiers,
};

/// Mouse buttons
pub const MouseButton = enum {
    left,
    middle,
    right,
    release,
    scroll_up,
    scroll_down,
};

/// Key modifiers
pub const Modifiers = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

/// Input reader for handling keyboard and mouse events
pub const InputReader = struct {
    stdin: std.fs.File,
    buf: [32]u8 = undefined,
    buf_len: usize = 0,

    pub fn init() InputReader {
        return InputReader{
            .stdin = std.fs.File.stdin(),
        };
    }

    /// Read next input event (non-blocking if terminal is in raw mode)
    pub fn readKey(self: *InputReader) Key {
        // Read bytes
        const bytes_read = self.stdin.read(&self.buf) catch return .none;
        if (bytes_read == 0) return .none;

        self.buf_len = bytes_read;
        return self.parseInput();
    }

    /// Parse input buffer into key event
    fn parseInput(self: *InputReader) Key {
        if (self.buf_len == 0) return .none;

        const first = self.buf[0];

        // Control characters
        if (first < 32) {
            return switch (first) {
                0 => .none,
                3 => Key{ .ctrl = 'c' }, // Ctrl+C
                4 => Key{ .ctrl = 'd' }, // Ctrl+D
                9 => Key{ .special = .tab },
                10, 13 => Key{ .special = .enter },
                27 => self.parseEscape(),
                127 => Key{ .special = .backspace },
                else => Key{ .ctrl = first + 'a' - 1 },
            };
        }

        // Regular character
        return Key{ .char = first };
    }

    /// Parse escape sequences
    fn parseEscape(self: *InputReader) Key {
        // Just Escape key
        if (self.buf_len == 1) {
            return Key{ .special = .escape };
        }

        // Alt+key
        if (self.buf_len == 2 and self.buf[1] >= 32) {
            return Key{ .alt = self.buf[1] };
        }

        // CSI sequences
        if (self.buf_len >= 3 and self.buf[1] == '[') {
            return self.parseCSI();
        }

        // SS3 sequences (arrow keys on some terminals)
        if (self.buf_len >= 3 and self.buf[1] == 'O') {
            return self.parseSS3();
        }

        return Key{ .special = .escape };
    }

    /// Parse CSI (Control Sequence Introducer) sequences
    fn parseCSI(self: *InputReader) Key {
        if (self.buf_len < 3) return Key{ .special = .escape };

        const code = self.buf[2];

        // Simple arrow keys and such
        return switch (code) {
            'A' => Key{ .special = .up },
            'B' => Key{ .special = .down },
            'C' => Key{ .special = .right },
            'D' => Key{ .special = .left },
            'H' => Key{ .special = .home },
            'F' => Key{ .special = .end },
            'Z' => Key{ .special = .backtab },
            '1' => self.parseExtendedCSI(),
            '2' => if (self.buf_len >= 4 and self.buf[3] == '~') Key{ .special = .insert } else .none,
            '3' => if (self.buf_len >= 4 and self.buf[3] == '~') Key{ .special = .delete } else .none,
            '5' => if (self.buf_len >= 4 and self.buf[3] == '~') Key{ .special = .page_up } else .none,
            '6' => if (self.buf_len >= 4 and self.buf[3] == '~') Key{ .special = .page_down } else .none,
            '<' => self.parseMouse(),
            else => .none,
        };
    }

    /// Parse extended CSI sequences (function keys, etc.)
    fn parseExtendedCSI(self: *InputReader) Key {
        if (self.buf_len < 4) return .none;

        // Home/End
        if (self.buf[3] == '~') {
            return switch (self.buf[2]) {
                '1' => Key{ .special = .home },
                '4' => Key{ .special = .end },
                else => .none,
            };
        }

        // Function keys
        if (self.buf_len >= 5 and self.buf[4] == '~') {
            const num = (self.buf[2] - '0') * 10 + (self.buf[3] - '0');
            return switch (num) {
                11 => Key{ .special = .f1 },
                12 => Key{ .special = .f2 },
                13 => Key{ .special = .f3 },
                14 => Key{ .special = .f4 },
                15 => Key{ .special = .f5 },
                17 => Key{ .special = .f6 },
                18 => Key{ .special = .f7 },
                19 => Key{ .special = .f8 },
                20 => Key{ .special = .f9 },
                21 => Key{ .special = .f10 },
                23 => Key{ .special = .f11 },
                24 => Key{ .special = .f12 },
                else => .none,
            };
        }

        return .none;
    }

    /// Parse SS3 sequences
    fn parseSS3(self: *InputReader) Key {
        if (self.buf_len < 3) return Key{ .special = .escape };

        return switch (self.buf[2]) {
            'A' => Key{ .special = .up },
            'B' => Key{ .special = .down },
            'C' => Key{ .special = .right },
            'D' => Key{ .special = .left },
            'H' => Key{ .special = .home },
            'F' => Key{ .special = .end },
            'P' => Key{ .special = .f1 },
            'Q' => Key{ .special = .f2 },
            'R' => Key{ .special = .f3 },
            'S' => Key{ .special = .f4 },
            else => .none,
        };
    }

    /// Parse SGR mouse events
    fn parseMouse(self: *InputReader) Key {
        // Format: CSI < Cb ; Cx ; Cy M/m
        // We need to parse the numbers
        var i: usize = 3; // Skip "ESC [ <"
        var button: u32 = 0;
        var x: u32 = 0;
        var y: u32 = 0;
        var state: u8 = 0; // 0=button, 1=x, 2=y

        while (i < self.buf_len) : (i += 1) {
            const c = self.buf[i];
            if (c >= '0' and c <= '9') {
                const digit = c - '0';
                switch (state) {
                    0 => button = button * 10 + digit,
                    1 => x = x * 10 + digit,
                    2 => y = y * 10 + digit,
                    else => {},
                }
            } else if (c == ';') {
                state += 1;
            } else if (c == 'M' or c == 'm') {
                // M = press, m = release
                const mb: MouseButton = switch (button & 3) {
                    0 => if (c == 'm') .release else .left,
                    1 => if (c == 'm') .release else .middle,
                    2 => if (c == 'm') .release else .right,
                    else => .release,
                };

                // Check for scroll
                const final_button = if (button & 64 != 0)
                    if (button & 1 != 0) MouseButton.scroll_down else MouseButton.scroll_up
                else
                    mb;

                return Key{ .mouse = MouseEvent{
                    .x = @intCast(if (x > 0) x - 1 else 0),
                    .y = @intCast(if (y > 0) y - 1 else 0),
                    .button = final_button,
                    .modifiers = Modifiers{
                        .shift = (button & 4) != 0,
                        .alt = (button & 8) != 0,
                        .ctrl = (button & 16) != 0,
                    },
                } };
            }
        }

        return .none;
    }

    /// Poll for input with timeout (milliseconds)
    pub fn poll(self: *InputReader, timeout_ms: i32) bool {
        _ = self;
        _ = timeout_ms;

        // For simplicity, we'll use blocking reads
        // A full implementation would use poll/select/epoll
        return true;
    }
};

/// Event for the application event loop
pub const Event = union(enum) {
    key: Key,
    resize: struct { width: u16, height: u16 },
    tick,
    quit,
};

/// Event queue for buffering events
pub const EventQueue = struct {
    events: std.ArrayList(Event),
    input: InputReader,

    pub fn init(allocator: std.mem.Allocator) EventQueue {
        return EventQueue{
            .events = std.ArrayList(Event).init(allocator),
            .input = InputReader.init(),
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.events.deinit();
    }

    /// Push an event to the queue
    pub fn push(self: *EventQueue, event: Event) !void {
        try self.events.append(event);
    }

    /// Pop an event from the queue
    pub fn pop(self: *EventQueue) ?Event {
        if (self.events.items.len > 0) {
            return self.events.orderedRemove(0);
        }
        return null;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *EventQueue) bool {
        return self.events.items.len == 0;
    }

    /// Read input and queue events
    pub fn pollInput(self: *EventQueue) !void {
        const key = self.input.readKey();
        if (key != .none) {
            try self.push(Event{ .key = key });
        }
    }
};

// Tests
test "key detection" {
    const enter = Key{ .special = .enter };
    try std.testing.expect(enter.isEnter());
    try std.testing.expect(!enter.isEscape());

    const escape = Key{ .special = .escape };
    try std.testing.expect(escape.isEscape());

    const char_a = Key{ .char = 'a' };
    try std.testing.expect(char_a.isChar('a'));
    try std.testing.expect(!char_a.isChar('b'));

    const ctrl_c = Key{ .ctrl = 'c' };
    try std.testing.expect(ctrl_c.isCtrlC());
}

test "event queue" {
    const allocator = std.testing.allocator;
    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    try queue.push(.tick);
    try queue.push(.quit);

    try std.testing.expect(!queue.isEmpty());

    const first = queue.pop();
    try std.testing.expect(first != null);
    try std.testing.expect(first.? == .tick);

    const second = queue.pop();
    try std.testing.expect(second != null);
    try std.testing.expect(second.? == .quit);

    try std.testing.expect(queue.isEmpty());
}
