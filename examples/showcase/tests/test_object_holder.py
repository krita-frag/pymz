from __future__ import absolute_import, print_function

import gc
import sys

import showcase


def test_object_holder_value_only():
    """ObjectHolder with just a value (child defaults to None)."""
    holder = showcase.ObjectHolder(42)
    assert holder.get_value() == 42
    assert holder.get_child() is None


def test_object_holder_with_child():
    """ObjectHolder with a child object - verifies py_init incref fix.

    Without the fix, fromPy(?*Object) returns a borrowed reference.
    The constructor args tuple is decref'd after py_init, which would
    free the child if no other reference exists. get_child() would then
    return a dangling pointer (use-after-free).
    """
    child = [1, 2, 3]  # a Python list object
    holder = showcase.ObjectHolder(99, child)
    assert holder.get_value() == 99
    # If the refcount fix is missing, child may have been freed and
    # get_child() returns garbage or crashes. Verify it's still valid.
    result = holder.get_child()
    assert result is not None
    assert list(result) == [1, 2, 3]
    # child must still be alive (holder holds a reference)
    assert list(child) == [1, 2, 3]


def test_object_holder_child_refcount():
    """Verify the child's refcount is correct after construction.

    The holder should hold exactly one reference to the child.
    After deleting the holder, the child's refcount should return
    to its original value.
    """
    child = [10, 20]
    ref_before = sys.getrefcount(child)
    holder = showcase.ObjectHolder(1, child)
    # holder + child + getrefcount arg = ref_before + 1
    ref_with_holder = sys.getrefcount(child)
    assert ref_with_holder == ref_before + 1, (
        "expected refcount %d, got %d" % (ref_before + 1, ref_with_holder)
    )
    del holder
    gc.collect()
    ref_after = sys.getrefcount(child)
    assert ref_after == ref_before, (
        "expected refcount %d after dealloc, got %d" % (ref_before, ref_after)
    )


def test_object_holder_dealloc():
    """Verify ObjectHolder is deallocated properly."""
    before = showcase.object_holder_dealloc_count()
    holder = showcase.ObjectHolder(5)
    del holder
    gc.collect()
    assert showcase.object_holder_dealloc_count() - before == 1


def test_object_holder_dealloc_with_child():
    """Verify ObjectHolder with child is deallocated (no leak)."""
    before = showcase.object_holder_dealloc_count()
    child = [1]
    holder = showcase.ObjectHolder(5, child)
    del holder
    gc.collect()
    assert showcase.object_holder_dealloc_count() - before == 1


def test_object_holder_property_set():
    """Verify property setter correctly manages refcounts."""
    child1 = [1]
    child2 = [2]
    ref1_before = sys.getrefcount(child1)
    ref2_before = sys.getrefcount(child2)

    holder = showcase.ObjectHolder(0, child1)
    # Set child to child2 via property (exercises setter fix)
    holder.child = child2

    # child1 should have its original refcount (setter released it)
    ref1_after = sys.getrefcount(child1)
    assert ref1_after == ref1_before, (
        "child1 refcount leak: expected %d, got %d" % (ref1_before, ref1_after)
    )

    # child2 should have +1 refcount (holder holds it)
    ref2_after = sys.getrefcount(child2)
    assert ref2_after == ref2_before + 1, (
        "child2 refcount wrong: expected %d, got %d" % (ref2_before + 1, ref2_after)
    )

    del holder
    gc.collect()
    # child2 should return to original refcount
    ref2_final = sys.getrefcount(child2)
    assert ref2_final == ref2_before, (
        "child2 refcount leak after dealloc: expected %d, got %d"
        % (ref2_before, ref2_final)
    )
