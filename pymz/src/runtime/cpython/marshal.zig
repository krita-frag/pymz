//! Argument marshalling for pymz function/method wrappers.
//!
//! This module owns the argument-extraction and return-value pipeline that
//! sits between a Python `PyMethodDef` callback and the user's Zig function:
//!
//!   - `extractPositionalArg` / `convertField` / `validateKeywordNames` pull
//!     arguments out of Python tuples/dicts and convert them via `convert`.
//!   - `releaseArgsTuple` releases partially-converted arguments when a later
//!     argument fails or the wrapped function returns.
//!   - `handleReturn` converts a Zig return value (or error) into a
//!     `*c.PyObject` suitable for returning from a `PyMethodDef` callback.
//!
//! The conversion primitives themselves (`toPy`, `fromPy`, `releaseValue`,
//! `pyTypeName`) live in `convert.zig`; this module imports them rather than
//! duplicating the conversion logic. The dependency is one-way
//! (`marshal` -> `convert`): `convert.zig` does not import this module, so
//! there is no import cycle and the two responsibilities stay separable.

const std = @import("std");
const c = @import("python_c");
const errors = @import("errors.zig");
const object = @import("object.zig");
const types = @import("types.zig");
const traits = @import("traits.zig");
const convert = @import("convert.zig");

const Object = object.Object;

/// Release the first `count` converted arguments in a `std.meta.ArgsTuple(Fn)`.
///
/// Used by every `pyfn_*` / method wrapper to clean up partially-converted
/// argument tuples when a later argument fails to convert or after the wrapped
/// function returns. `skip` is the number of leading arguments that are not
/// Python-converted (e.g. `self` for instance methods, `cls` for class
/// methods); those slots are never touched.
pub fn releaseArgsTuple(
    comptime Fn: type,
    args: *std.meta.ArgsTuple(Fn),
    count: usize,
    comptime skip: usize,
) void {
    const Params = @typeInfo(Fn).@"fn".params;
    inline for (Params[skip..], 0..) |param, i| {
        if (i < count) {
            if (param.type) |_| {
                convert.releaseValue(&args[i + skip]);
            }
        }
    }
}

/// Count the required (non-optional) parameters in a function's parameter
/// list, skipping the first `skip` parameters (e.g. `self`/`cls` for instance
/// and class methods). Parameters with no type (e.g. `anytype`) are not
/// counted.
///
/// Comptime-only. Used by `pyfn_typed` and `MethodBuilder.wrapMethod` to
/// compute the minimum positional arity for arity-check error messages.
pub fn requiredParamCount(comptime Fn: type, comptime skip: usize) usize {
    const Params = @typeInfo(Fn).@"fn".params;
    var count: usize = 0;
    for (Params[skip..]) |param| {
        const PT = param.type orelse continue;
        if (@typeInfo(PT) != .optional) count += 1;
    }
    return count;
}

/// Extract a single positional argument from a Python tuple and convert it.
///
/// On success, returns the converted value. On failure, sets the appropriate
/// Python exception (`TypeError` for missing/mismatched arguments) and returns
/// `null`. The caller is responsible for releasing any previously converted
/// arguments and returning `null` from the wrapper.
///
/// `arg_label` is used in the error message and should identify the argument
/// (e.g. the 1-based index as a string, or the parameter name).
pub fn extractPositionalArg(
    comptime PT: type,
    args_tuple: *types.Tuple,
    index: usize,
    arg_label: []const u8,
) ?PT {
    const py_item = args_tuple.get(index) orelse {
        errors.typeError("missing argument {s}", .{arg_label});
        return null;
    };
    return convert.fromPy(PT, py_item) catch {
        errors.typeError(
            "argument {s} expects {s}, got {s}",
            .{ arg_label, @typeName(PT), convert.pyTypeName(py_item) },
        );
        return null;
    };
}

/// Convert a Python object into a struct field value, handling optional types
/// and `None` inputs. Used by `pyfn_kw` and any wrapper that fills struct
/// fields from Python arguments.
///
/// On success, returns the converted value. On failure, sets a `TypeError`
/// (with `field_name` and the expected/actual type names) and returns `null`.
/// The caller is responsible for releasing any previously converted fields.
pub fn convertField(
    comptime FT: type,
    py_item: *Object,
    field_name: []const u8,
) ?FT {
    if (@typeInfo(FT) == .optional) {
        if (py_item.isNone()) return null;
        const InnerT = @typeInfo(FT).optional.child;
        return convert.fromPy(InnerT, py_item) catch {
            errors.typeError(
                "argument '{s}' expects {s}, got {s}",
                .{ field_name, @typeName(FT), convert.pyTypeName(py_item) },
            );
            return null;
        };
    }
    return convert.fromPy(FT, py_item) catch {
        errors.typeError(
            "argument '{s}' expects {s}, got {s}",
            .{ field_name, @typeName(FT), convert.pyTypeName(py_item) },
        );
        return null;
    };
}

/// Validate keyword argument names against a comptime list of valid names.
///
/// Iterates over every key in `kwargs_dict` and ensures each is a string that
/// matches one of `names`, and that the corresponding index is not already
/// occupied by a positional argument (`pos_count`). On any violation, sets a
/// `TypeError` and returns `false`; the caller should abort the wrapper.
///
/// `nameAtIndex` must be a `comptime fn(comptime usize) []const u8` that
/// returns the valid keyword name for a given index, or an empty string if
/// the index is out of range. The index is comptime because callers iterate
/// it inside an `inline for`.
pub fn validateKeywordNames(
    kwargs_dict: *types.Dict,
    pos_count: usize,
    comptime nameAtIndex: fn (comptime index: usize) []const u8,
    comptime field_count: usize,
) bool {
    var pos: c.Py_ssize_t = 0;
    var key_obj: ?*c.PyObject = null;
    var value_obj: ?*c.PyObject = null;
    while (c.PyDict_Next(@ptrCast(kwargs_dict), &pos, &key_obj, &value_obj) != 0) {
        const keyword_obj: *Object = @ptrCast(key_obj orelse {
            errors.typeError("keyword argument name must be str", .{});
            return false;
        });
        if (!object.Str.check(keyword_obj)) {
            errors.typeError("keyword argument name must be str", .{});
            return false;
        }

        const keyword_name = object.Str.asString(@ptrCast(keyword_obj)) catch |err| {
            errors.mapError(err);
            return false;
        };

        var found_idx: ?usize = null;
        inline for (0..field_count) |i| {
            if (std.mem.eql(u8, keyword_name, comptime nameAtIndex(i))) {
                found_idx = i;
                break;
            }
        }

        if (found_idx == null) {
            errors.typeError("got an unexpected keyword argument '{s}'", .{keyword_name});
            return false;
        }
        if (found_idx.? < pos_count) {
            errors.typeError("got multiple values for argument '{s}'", .{keyword_name});
            return false;
        }
    }
    return true;
}

/// Convert a Zig return value (possibly an error union) into a Python object
/// suitable for returning from a `PyMethodDef` callback.
///
/// On a Zig error, maps it to a Python exception (unless one is already set)
/// and returns `null`. On success, returns a NEW reference. Owned temporary
/// values produced by the wrapper are released via `releaseReturnedValue`.
pub fn handleReturn(comptime RT: type, result: RT) ?*c.PyObject {
    switch (@typeInfo(RT)) {
        .error_union => {
            if (result) |value| {
                return handlePayload(@TypeOf(value), value);
            } else |err| {
                if (errors.errorOccurred() == null) {
                    errors.mapError(err);
                }
                return null;
            }
        },
        else => return handlePayload(RT, result),
    }
}

/// Release ownership of a wrapper-produced value after `toPy` has converted it
/// to a Python object.
///
/// Zig functions that return `*Object` / `*c.PyObject` follow the CPython
/// return-value convention: they return a NEW reference. `toPy` already
/// incref'd to produce the Python-side new ref, so the original is decref'd
/// here to avoid a leak. Mutable `[]u8` slices returned by the wrapper are
/// freed through `convert.releaseValue`.
fn releaseReturnedValue(value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            if (value) |inner| {
                releaseReturnedValue(inner);
            }
            _ = optional_info;
        },
        .pointer => |pointer_info| {
            if (traits.isObjectPtr(T)) {
                value.decref();
                return;
            }
            if (pointer_info.child == c.PyObject) {
                @as(*object.Object, @ptrCast(value)).decref();
                return;
            }
            if (pointer_info.size == .slice and pointer_info.child == u8 and !pointer_info.is_const) {
                convert.releaseValue(&value);
            }
        },
        else => {},
    }
}

fn handlePayload(comptime T: type, value: T) ?*c.PyObject {
    defer releaseReturnedValue(value);
    const obj = convert.toPy(value) catch return null;
    return @ptrCast(obj);
}
