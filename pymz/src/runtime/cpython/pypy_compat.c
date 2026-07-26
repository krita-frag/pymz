/* Auto-generated PyPy compatibility stubs for 62 functions. */
#include <Python.h>
int PyBuffer_FillInfo(struct bufferinfo *arg0, struct _object *arg1, void *arg2, Py_ssize_t arg3, int arg4, int arg5) { return PyPyBuffer_FillInfo(arg0, arg1, arg2, arg3, arg4, arg5); }
char * PyByteArray_AsString(struct _object *arg0) { return PyPyByteArray_AsString(arg0); }
int PyByteArray_Check(void * arg0) { return PyPyByteArray_Check(arg0); }
struct _object * PyByteArray_FromStringAndSize(const char *arg0, Py_ssize_t arg1) { return PyPyByteArray_FromStringAndSize(arg0, arg1); }
Py_ssize_t PyByteArray_Size(struct _object *arg0) { return PyPyByteArray_Size(arg0); }
int PyBytes_AsStringAndSize(struct _object *arg0, char **arg1, Py_ssize_t *arg2) { return PyPyBytes_AsStringAndSize(arg0, arg1, arg2); }
struct _object * PyBytes_FromStringAndSize(const char *arg0, Py_ssize_t arg1) { return PyPyBytes_FromStringAndSize(arg0, arg1); }
struct _object * PyDict_GetItem(struct _object *arg0, struct _object *arg1) { return PyPyDict_GetItem(arg0, arg1); }
struct _object * PyDict_GetItemString(struct _object *arg0, const char *arg1) { return PyPyDict_GetItemString(arg0, arg1); }
struct _object * PyDict_Items(struct _object *arg0) { return PyPyDict_Items(arg0); }
struct _object * PyDict_New() { return PyPyDict_New(); }
int PyDict_Next(struct _object *arg0, Py_ssize_t *arg1, struct _object **arg2, struct _object **arg3) { return PyPyDict_Next(arg0, arg1, arg2, arg3); }
int PyDict_SetItem(struct _object *arg0, struct _object *arg1, struct _object *arg2) { return PyPyDict_SetItem(arg0, arg1, arg2); }
int PyDict_SetItemString(struct _object *arg0, const char *arg1, struct _object *arg2) { return PyPyDict_SetItemString(arg0, arg1, arg2); }
Py_ssize_t PyDict_Size(struct _object *arg0) { return PyPyDict_Size(arg0); }
void PyErr_Clear() { return PyPyErr_Clear(); }
void PyErr_Fetch(struct _object **arg0, struct _object **arg1, struct _object **arg2) { return PyPyErr_Fetch(arg0, arg1, arg2); }
struct _object * PyErr_Occurred() { return PyPyErr_Occurred(); }
void PyErr_Print() { return PyPyErr_Print(); }
void PyErr_Restore(struct _object *arg0, struct _object *arg1, struct _object *arg2) { return PyPyErr_Restore(arg0, arg1, arg2); }
void PyErr_SetString(struct _object *arg0, const char *arg1) { return PyPyErr_SetString(arg0, arg1); }
double PyFloat_AsDouble(struct _object *arg0) { return PyPyFloat_AsDouble(arg0); }
int PyFloat_Check(void * arg0) { return PyPyFloat_Check(arg0); }
struct _object * PyFloat_FromDouble(double arg0) { return PyPyFloat_FromDouble(arg0); }
int PyFrozenSet_Check(void * arg0) { return PyPyFrozenSet_Check(arg0); }
struct _object * PyFrozenSet_New(struct _object *arg0) { return PyPyFrozenSet_New(arg0); }
int PyList_Append(struct _object *arg0, struct _object *arg1) { return PyPyList_Append(arg0, arg1); }
struct _object * PyList_GetItem(struct _object *arg0, Py_ssize_t arg1) { return PyPyList_GetItem(arg0, arg1); }
struct _object * PyList_New(Py_ssize_t arg0) { return PyPyList_New(arg0); }
int PyList_SetItem(struct _object *arg0, Py_ssize_t arg1, struct _object *arg2) { return PyPyList_SetItem(arg0, arg1, arg2); }
Py_ssize_t PyList_Size(struct _object *arg0) { return PyPyList_Size(arg0); }
long long PyLong_AsLongLong(PyObject * arg0) { return PyPyLong_AsLongLong(arg0); }
unsigned long long PyLong_AsUnsignedLongLong(PyObject * arg0) { return PyPyLong_AsUnsignedLongLong(arg0); }
struct _object * PyLong_FromLongLong(Py_ssize_t arg0) { return PyPyLong_FromLongLong(arg0); }
struct _object * PyLong_FromSize_t(size_t arg0) { return PyPyLong_FromSize_t(arg0); }
struct _object * PyLong_FromSsize_t(Py_ssize_t arg0) { return PyPyLong_FromSsize_t(arg0); }
PyObject * PyLong_FromUnsignedLongLong(unsigned long long arg0) { return PyPyLong_FromUnsignedLongLong(arg0); }
struct _object * PyModule_GetDict(struct _object *arg0) { return PyPyModule_GetDict(arg0); }
char * PyModule_GetName(struct _object *arg0) { return PyPyModule_GetName(arg0); }
struct _object * PyObject_GetAttrString(struct _object *arg0, const char *arg1) { return PyPyObject_GetAttrString(arg0, arg1); }
int PyObject_IsInstance(struct _object *arg0, struct _object *arg1) { return PyPyObject_IsInstance(arg0, arg1); }
int PyObject_IsTrue(struct _object *arg0) { return PyPyObject_IsTrue(arg0); }
struct _object * PyObject_Repr(struct _object *arg0) { return PyPyObject_Repr(arg0); }
int PyObject_SetAttrString(struct _object *arg0, const char *arg1, struct _object *arg2) { return PyPyObject_SetAttrString(arg0, arg1, arg2); }
struct _object * PyObject_Str(struct _object *arg0) { return PyPyObject_Str(arg0); }
struct _object * PyObject_Type(struct _object *arg0) { return PyPyObject_Type(arg0); }
int PySet_Add(struct _object *arg0, struct _object *arg1) { return PyPySet_Add(arg0, arg1); }
int PySet_Check(void * arg0) { return PyPySet_Check(arg0); }
int PySet_Contains(struct _object *arg0, struct _object *arg1) { return PyPySet_Contains(arg0, arg1); }
struct _object * PySet_New(struct _object *arg0) { return PyPySet_New(arg0); }
struct _object * PySet_Pop(struct _object *arg0) { return PyPySet_Pop(arg0); }
Py_ssize_t PySet_Size(struct _object *arg0) { return PyPySet_Size(arg0); }
int PySlice_GetIndicesEx(struct _object *arg0, Py_ssize_t arg1, Py_ssize_t *arg2, Py_ssize_t *arg3, Py_ssize_t *arg4, Py_ssize_t *arg5) { return PyPySlice_GetIndicesEx(arg0, arg1, arg2, arg3, arg4, arg5); }
struct _object * PySlice_New(struct _object *arg0, struct _object *arg1, struct _object *arg2) { return PyPySlice_New(arg0, arg1, arg2); }
struct _object * PyTuple_GetItem(struct _object *arg0, Py_ssize_t arg1) { return PyPyTuple_GetItem(arg0, arg1); }
int PyTuple_SetItem(struct _object *arg0, Py_ssize_t arg1, struct _object *arg2) { return PyPyTuple_SetItem(arg0, arg1, arg2); }
Py_ssize_t PyTuple_Size(struct _object *arg0) { return PyPyTuple_Size(arg0); }
int PyType_Ready(struct _typeobject *arg0) { return PyPyType_Ready(arg0); }
char * PyUnicode_AsUTF8AndSize(PyObject * arg0, Py_ssize_t * arg1) { return PyPyUnicode_AsUTF8AndSize(arg0, arg1); }
struct _object * PyUnicode_FromStringAndSize(const char *arg0, Py_ssize_t arg1) { return PyPyUnicode_FromStringAndSize(arg0, arg1); }
void Py_DecRef(struct _object *arg0) { return PyPy_DecRef(arg0); }
void Py_IncRef(struct _object *arg0) { return PyPy_IncRef(arg0); }
