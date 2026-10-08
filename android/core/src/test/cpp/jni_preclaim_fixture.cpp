#include "jni_helper.h"
#include "libclash.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>

// 公开函数表直接调用生产入口；每个进程一个场景，不重置粘滞责任。
static bool pending;
static int mode, deletes, peeks, claims, starts, stops;
static JNIEnv *current_env;
static _jclass clazz;
static _jobject callback, lease;
static jclass findClass(JNIEnv *, const char *) { return &clazz; }
static jobject globalRef(JNIEnv *, jobject object) {
    if (object == &callback && (mode == 2 || mode == 6)) {
        pending = true;
        return mode == 6 ? nullptr : object;
    }
    return object;
}
static jmethodID method(JNIEnv *, jclass, const char *name, const char *) {
    return reinterpret_cast<jmethodID>(std::strcmp(name, "peek") == 0 ? 1 : 2);
}
static jint callInt(JNIEnv *, jobject, jmethodID id, va_list) {
    if (id == reinterpret_cast<jmethodID>(1)) { ++peeks; return 7; }
    ++claims;
    if (mode == 3) pending = true;
    return mode == 5 ? 7 : -1;
}
static jboolean exceptionCheck(JNIEnv *) { return pending ? JNI_TRUE : JNI_FALSE; }
static void exceptionClear(JNIEnv *) { pending = false; }
static void deleteLocal(JNIEnv *, jobject) {}
static void deleteGlobal(JNIEnv *, jobject object) {
    if (object == &callback) {
        ++deletes;
        if (mode == 1 || mode == 2) pending = true;
    }
}
static jint getEnv(JavaVM *, void **result, jint) { *result = current_env; return JNI_OK; }
extern "C" void registerCallbacks(protect_func, resolve_process_func, release_object_func) {}
extern "C" GoUint8 startTUN(int, void *) { ++starts; return 1; }
extern "C" GoUint8 stopTun() { ++stops; return 1; }
extern "C" void suspend(int) {}
extern "C" jint JNI_OnLoad(JavaVM *, void *);
extern "C" jboolean Java_com_appshub_bettbox_core_Core_startNativeTun(JNIEnv *, jobject, jobject, jobject);
extern "C" jboolean Java_com_appshub_bettbox_core_Core_stopNativeTun(JNIEnv *);

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    mode = std::atoi(argv[1]);
    if (mode < 1 || mode > 6) return 2;
    JNINativeInterface methods{};
    methods.FindClass = findClass;
    methods.NewGlobalRef = globalRef;
    methods.GetMethodID = method;
    methods.CallIntMethodV = callInt;
    methods.ExceptionCheck = exceptionCheck;
    methods.ExceptionClear = exceptionClear;
    methods.DeleteGlobalRef = deleteGlobal;
    methods.DeleteLocalRef = deleteLocal;
    JNIEnv env{&methods};
    current_env = &env;
    JNIInvokeInterface invocation{};
    invocation.GetEnv = getEnv;
    JavaVM vm{&invocation};
    if (JNI_OnLoad(&vm, nullptr) != JNI_VERSION_1_6) return 3;
    const bool started = Java_com_appshub_bettbox_core_Core_startNativeTun(&env, nullptr, &lease, &callback);
    const bool unknown = mode <= 3;
    int failed = (started != (mode == 5)) || pending || (jni_cleanup_unknown() != unknown);
    failed += starts != (mode == 5 ? 1 : 0);
    failed += deletes != (mode == 6 || mode == 5 ? 0 : 1);
    const int previous_peeks = peeks, previous_claims = claims;
    if (unknown) {
        failed += Java_com_appshub_bettbox_core_Core_startNativeTun(&env, nullptr, &lease, &callback) != JNI_FALSE;
        failed += peeks != previous_peeks || claims != previous_claims || starts != 0 || deletes != 1;
    }
    const bool stopped = Java_com_appshub_bettbox_core_Core_stopNativeTun(&env);
    failed += stopped != !unknown || stops != 1 || pending;
    std::printf("{\"case\":%d,\"failed\":%d,\"actual_JVM\":false}\n", mode, failed);
    return failed ? 1 : 0;
}

// 旧入口夹具仅满足新增ABI链接，不调用带身份启动。
extern "C" char *startTUNOwned(long long, long long, long long, int, void *) { return nullptr; }
extern "C" char *stopTUNOwned(long long, long long, long long) { return nullptr; }
