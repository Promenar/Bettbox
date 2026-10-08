#include "jni_helper.h"
#include "libclash.h"
#include <cstdio>
#include <cstring>
#include <initializer_list>

// 用公开 JNI 函数表检查生产 helper 的异常短路；不启动 JVM 或使用真实 FD。
static bool pending;
static int failure;
static int invalid_calls;
static int deleted_globals;
static int registered_callbacks;
static JNIEnv *current_env;
static _jclass string_class;
static _jbyteArray bytes;
static _jstring string_value;

static jclass findClass(JNIEnv *, const char *) {
    if (failure == 1) { pending = true; return nullptr; }
    return &string_class;
}
static jobject globalRef(JNIEnv *, jobject value) {
    if (!value || pending) ++invalid_calls;
    if (failure == 2) { pending = true; return nullptr; }
    return value;
}
static jmethodID method(JNIEnv *, jclass value, const char *name, const char *) {
    if (!value || pending) ++invalid_calls;
    if (failure == 3 || (failure == 6 && std::strcmp(name, "protect") == 0) ||
        (failure == 7 && std::strcmp(name, "peek") == 0) ||
        (failure == 8 && std::strcmp(name, "getBytes") == 0)) {
        pending = true; return nullptr;
    }
    return reinterpret_cast<jmethodID>(1);
}
static jbyteArray byteArray(JNIEnv *, jsize) {
    if (failure == 4) { pending = true; return nullptr; }
    return &bytes;
}
static void setRegion(JNIEnv *, jbyteArray value, jsize, jsize, const jbyte *) {
    if (!value || pending) ++invalid_calls;
    if (failure == 5) pending = true;
}
static jobject newObject(JNIEnv *, jclass value, jmethodID id, va_list) {
    if (!value || !id || pending) ++invalid_calls;
    if (failure == 9) { pending = true; return nullptr; }
    return &string_value;
}
static jboolean exceptionCheck(JNIEnv *) { return pending ? JNI_TRUE : JNI_FALSE; }
static void exceptionClear(JNIEnv *) { pending = false; }
static void deleteRef(JNIEnv *, jobject) {}
static void deleteGlobal(JNIEnv *, jobject) { ++deleted_globals; }
static jint getEnv(JavaVM *, void **result, jint) { *result = current_env; return JNI_OK; }

// 仅满足真实 core.cpp 的链接，不启动核心或访问任何描述符。
extern "C" void registerCallbacks(protect_func, resolve_process_func, release_object_func) { ++registered_callbacks; }
extern "C" GoUint8 startTUN(int, void *) { return 0; }
extern "C" GoUint8 stopTun() { return 0; }
extern "C" void suspend(int) {}
extern "C" jint JNI_OnLoad(JavaVM *, void *);

int main() {
    JNINativeInterface methods{};
    methods.FindClass = findClass;
    methods.NewGlobalRef = globalRef;
    methods.GetMethodID = method;
    methods.NewByteArray = byteArray;
    methods.SetByteArrayRegion = setRegion;
    methods.NewObjectV = newObject;
    methods.ExceptionCheck = exceptionCheck;
    methods.ExceptionClear = exceptionClear;
    methods.DeleteGlobalRef = deleteGlobal;
    methods.DeleteLocalRef = deleteRef;
    JNIEnv env{&methods};
    current_env = &env;
    JNIInvokeInterface invocation{};
    invocation.GetEnv = getEnv;
    JavaVM vm{&invocation};
    int failed = 0;
    for (int mode : {1, 2, 3, 8}) {
        pending = false; invalid_calls = 0; failure = mode;
        if (initialize_jni(&vm, &env) || invalid_calls != 0 || pending) ++failed;
    }
    pending = false; invalid_calls = 0; failure = 0;
    if (!initialize_jni(&vm, &env)) ++failed;
    for (int mode : {4, 5, 9}) {
        pending = false; invalid_calls = 0; failure = mode;
        auto result = jni_new_string(&env, "public");
        if (result != nullptr || invalid_calls != 0 || pending) ++failed;
    }
    for (int mode : {6, 7}) {
        release_jni_initialization(&env);
        pending = false; invalid_calls = 0; failure = mode;
        deleted_globals = 0; registered_callbacks = 0;
        const auto status = JNI_OnLoad(&vm, nullptr);
        if (status != JNI_ERR || invalid_calls != 0 || registered_callbacks != 0 ||
            deleted_globals != 1 || pending) ++failed;
    }
    std::printf("{\"JNI_failure_cases\":9,\"failed\":%d,\"actual_JVM\":false}\n", failed);
    return failed ? 1 : 0;
}
