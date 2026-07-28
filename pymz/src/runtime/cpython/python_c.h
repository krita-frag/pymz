#define PY_SSIZE_T_CLEAN 1

/* Python 3.12+ implements Py_INCREF as ob_refcnt_split[PY_BIG_ENDIAN]. When
 * translate-c runs against the system Python headers, the configure-time
 * WORDS_BIGENDIAN detection may not match Zig's target, so we force the
 * value based on the compiler's byte-order macros. All currently supported
 * targets (x86_64, aarch64) are little-endian. */
#if (defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)) || \
    defined(__BIG_ENDIAN__) || defined(__ARMEB__) || defined(__THUMBEB__) || \
    defined(__AARCH64EB__) || defined(_MIPSEB) || defined(__MIPSEB) || \
    defined(__MIPSEB__)
#  define PY_BIG_ENDIAN 1
#else
#  define PY_BIG_ENDIAN 0
#endif

/* CPython decorates public data symbols with import/export attributes.
 * translate-c occasionally misinterprets these declarations, so force a plain
 * extern declaration for all PyAPI_DATA symbols before including Python.h. */
#define PyAPI_DATA(RTYPE) extern RTYPE

#include <Python.h>

/* Use the stable ABI functions for reference counting on Python 3. This avoids
 * translate-c failures with the ob_refcnt_split[PY_BIG_ENDIAN] macro path used
 * by free-threaded / 3.12+ headers. Python 2 keeps the original macros. */
#if PY_MAJOR_VERSION >= 3
#  define Py_INCREF Py_IncRef
#  define Py_DECREF Py_DecRef
#  define Py_XINCREF Py_XIncRef
#  define Py_XDECREF Py_XDecRef
#endif

/* Keep reference-counting macros inside C. Python 2 implements them with
 * postfix increment and statement macros that Zig's C translator cannot
 * represent, while Python 3 versions vary between macros and ABI functions. */
static inline void pymz_Py_INCREF(PyObject *o) { Py_INCREF(o); }
static inline void pymz_Py_DECREF(PyObject *o) { Py_DECREF(o); }

/* Compatibility wrappers for singleton and type-check macros. */
static inline PyObject *pymz_Py_None(void) { return Py_None; }
static inline PyObject *pymz_Py_True(void) { return Py_True; }
static inline PyObject *pymz_Py_False(void) { return Py_False; }
static inline int pymz_PyBool_Check(PyObject *o) { return PyBool_Check(o); }
static inline int pymz_PyLong_Check(PyObject *o) { return PyLong_Check(o); }
#if PY_MAJOR_VERSION < 3
static inline int pymz_PyInt_Check(PyObject *o) { return PyInt_Check(o); }
#endif

/* PEP 489 multi-phase module initialization (Python 3.5+). PyModuleDef_Init
 * is a function, not a macro, but wrapping it via the same static-inline
 * pattern keeps all module-creation symbols behind the same #if guard so Zig
 * never resolves PyModuleDef on Python 2. */
#if PY_MAJOR_VERSION >= 3
static inline PyObject *pymz_PyModuleDef_Init(PyModuleDef *def) { return PyModuleDef_Init(def); }
#endif

/* Module creation is only part of the Python 3 module ABI. Keep the symbol
 * out of the Python 2 translation unit so Zig never has to resolve PyModuleDef
 * against Python 2 headers. */
#if PY_MAJOR_VERSION >= 3
static inline PyObject *pymz_PyModule_Create(PyModuleDef *def) { return PyModule_Create(def); }
#endif

/* PyType_FromMetaclass (Python 3.12+) wrapper for type creation via
 * PyType_Spec / PyType_Slot.  Kept behind a version gate so Zig never
 * references the symbol on older interpreters. */
#if PY_MAJOR_VERSION >= 3 && PY_MINOR_VERSION >= 12
static inline PyObject *pymz_PyType_FromMetaclass(PyTypeObject *metaclass, PyObject *module, PyType_Spec *spec, PyObject *bases) {
    return PyType_FromMetaclass(metaclass, module, spec, bases);
}
#endif

/* PyObject_GC_UnTrack is a macro (_PyObject_GC_UNTRACK) in CPython < 3.11
 * and a function in 3.11+. Zig's translate-c cannot see macros, so we wrap
 * it in a static inline function that is always visible to translate-c.
 * On all Python versions the underlying operation removes the object from
 * the GC tracking list without freeing it. */
static inline void pymz_PyObject_GC_UnTrack(PyObject *o) {
    PyObject_GC_UnTrack(o);
}
