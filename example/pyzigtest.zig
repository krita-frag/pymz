const pymz = @import("pymz");

fn add(args: pymz.Args) pymz.PyResult(?*pymz.c.PyObject) {
    const a = try args.getInt(0);
    const b = try args.getInt(1);
    return @ptrCast(try pymz.Int.from(a + b));
}

fn initModule(mod: *pymz.Module) pymz.PyResult(void) {
    const test_str = try pymz.Str.fromSlice("test!");
    defer test_str.decref();
    try mod.addObjectRef("TEST_STR", @ptrCast(test_str));
}

var module_methods = [_]pymz.MethodDef{
    pymz.method("add", pymz.pyfn(add), .varargs, "Add two numbers"),
    pymz.sentinel(),
};

comptime {
    _ = pymz.moduleInit("pyzigtest", &module_methods, initModule);
}
