//! Python class support for Zig-backed types.

const core = @import("class/core.zig");
const repr = @import("class/repr.zig");
const generate = @import("class/generate.zig");

pub const ClassDef = core.ClassDef;
pub const Wrapper = core.Wrapper;
pub const unwrap = core.unwrap;
pub const unwrapConst = core.unwrapConst;
pub const unwrapChecked = core.unwrapChecked;
pub const unwrapCheckedConst = core.unwrapCheckedConst;

pub const Repr = repr.Repr;
pub const Str = repr.Str;

pub const generateClass = generate.generateClass;
pub const class = generate.class;
pub const classWithBase = generate.classWithBase;
