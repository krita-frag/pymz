const stubs = @import("../src/stubs.zig");

pub const content = stubs.generate("pyzigtest", &.{
    stubs.func("add", "a: int, b: int", "int", "Add two numbers."),
    stubs.constant("TEST_STR", "str", "A test string constant."),
});
