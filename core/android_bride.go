//go:build android && cgo

package main

/*
#include <stdlib.h>

typedef int (*release_object_func)(void *obj);

typedef int (*protect_func)(void *tun_interface, int fd);

typedef const char* (*resolve_process_func)(void *tun_interface, int protocol, const char *source, const char *target, int uid);

static int protect(protect_func fn, void *tun_interface, int fd) {
    if (fn) {
        return fn(tun_interface, fd);
    }
    return 0;
}

static const char* resolve_process(resolve_process_func fn, void *tun_interface, int protocol, const char *source, const char *target, int uid) {
    if (fn) {
        return fn(tun_interface, protocol, source, target, uid);
    }
    return NULL;
}

static int release_object(release_object_func fn, void *obj) {
    if (fn) {
        return fn(obj);
    }
    return 0;
}
*/
import "C"
import (
	"core/androidstartup"
	"unsafe"
)

var (
	globalCallbacks struct {
		releaseObjectFunc  C.release_object_func
		protectFunc        C.protect_func
		resolveProcessFunc C.resolve_process_func
	}
)

func Protect(callback unsafe.Pointer, fd int) bool {
	return callback != nil && globalCallbacks.protectFunc != nil && C.protect(globalCallbacks.protectFunc, callback, C.int(fd)) != 0
}

func ResolveProcess(callback unsafe.Pointer, protocol int, source, target string, uid int) string {
	if globalCallbacks.resolveProcessFunc == nil {
		return ""
	}
	s := C.CString(source)
	defer C.free(unsafe.Pointer(s))
	t := C.CString(target)
	defer C.free(unsafe.Pointer(t))
	res := C.resolve_process(globalCallbacks.resolveProcessFunc, callback, C.int(protocol), s, t, C.int(uid))
	defer C.free(unsafe.Pointer(res))
	return C.GoString(res)
}

func releaseObjectChecked(callback unsafe.Pointer) error {
	if callback == nil {
		return nil
	}
	return androidstartup.ConfirmJNIRelease(int(C.release_object(globalCallbacks.releaseObjectFunc, callback)))
}

// 仅由State/Shutdown的OnceLease释放闭包调用，panic在Go收口边界捕获。
func releaseObject(callback unsafe.Pointer) {
	if err := releaseObjectChecked(callback); err != nil {
		panic(err)
	}
}

//export registerCallbacks
func registerCallbacks(markSocketFunc C.protect_func, resolveProcessFunc C.resolve_process_func, releaseObjectFunc C.release_object_func) {
	globalCallbacks.protectFunc = markSocketFunc
	globalCallbacks.resolveProcessFunc = resolveProcessFunc
	globalCallbacks.releaseObjectFunc = releaseObjectFunc
}
