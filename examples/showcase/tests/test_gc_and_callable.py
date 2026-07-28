from __future__ import absolute_import, print_function

import gc

import showcase


# ============================================================================
# GCCycleNode - public ?*Object field auto-GC traversal.
#
# Unlike GCNode (which uses private _child + user-defined __traverse__/__clear__),
# GCCycleNode has a public `child` field. The framework should automatically:
#   - visit `child` in tp_traverse (cycle detection)
#   - clear `child` in tp_clear (cycle breaking)
#   - decref `child` in cleanupFields (dealloc)
# If auto-traversal is missing, the cycle leaks and dealloc count stays below 2.
# ============================================================================

def test_gc_cycle_node_no_child_is_collected():
    before = showcase.gc_cycle_node_dealloc_count()
    node = showcase.GCCycleNode(42)
    del node
    gc.collect()
    assert showcase.gc_cycle_node_dealloc_count() - before == 1


def test_gc_cycle_node_cycle_with_public_field_is_collected():
    before = showcase.gc_cycle_node_dealloc_count()
    a = showcase.GCCycleNode(1)
    b = showcase.GCCycleNode(2)
    a.set_child(b)
    b.set_child(a)
    a_id = id(a)
    b_id = id(b)
    del a
    del b
    gc.collect()
    # After GC, both should be deallocated. If tp_traverse doesn't visit
    # the public `child` field, GC can't detect the cycle -> leak.
    assert showcase.gc_cycle_node_dealloc_count() - before == 2


def test_gc_cycle_node_chain_is_collected():
    before = showcase.gc_cycle_node_dealloc_count()
    a = showcase.GCCycleNode(10)
    b = showcase.GCCycleNode(20)
    c = showcase.GCCycleNode(30)
    a.set_child(b)
    b.set_child(c)
    c.set_child(a)
    del a
    del b
    del c
    gc.collect()
    assert showcase.gc_cycle_node_dealloc_count() - before == 3


def test_gc_cycle_node_get_value():
    node = showcase.GCCycleNode(99)
    assert node.get_value() == 99


# ============================================================================
# CallableOpt - __call__ with optional argument.
#
# __call__(self, factor: ?i64) i64
# Before the fix, py_call required exactly N positional args and couldn't
# handle optional parameters. Calling instance() or instance(None) would
# raise TypeError instead of working correctly.
# ============================================================================

def test_call_with_no_args():
    obj = showcase.CallableOpt(7)
    # No args: factor is None -> return base
    assert obj() == 7


def test_call_with_arg():
    obj = showcase.CallableOpt(7)
    # With arg: factor = 3 -> return base * factor
    assert obj(3) == 21


def test_call_with_none_explicit():
    obj = showcase.CallableOpt(5)
    # Explicit None: same as no args
    assert obj(None) == 5


def test_call_rejects_too_many_args():
    obj = showcase.CallableOpt(1)
    try:
        obj(1, 2)
        assert False, "expected TypeError"
    except TypeError:
        pass
