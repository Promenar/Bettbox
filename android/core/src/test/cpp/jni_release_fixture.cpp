#include "jni_helper.h"
#include "libclash.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <type_traits>
#include <utility>

// 公开 JNI 函数表夹具：不启动 JVM、Go runtime、VPN、网络或真实文件描述符。
static bool pending_exception;
static int active_case;
static int registrations;
static int get_env_calls;
static int attach_calls;
static int detach_calls;
static int delete_calls;
static int exception_checks;
static int exception_clears;
static int protect_jni_calls;
static int resolve_jni_calls;
static int followup_result;

static protect_func captured_protect;
static resolve_process_func captured_resolve;
static release_object_func captured_release;
static JNIEnv *current_env;
static _jclass public_class;
static _jobject public_object;

static jclass fixture_find_class(JNIEnv *, const char *) { return &public_class; }
static jobject new_global_ref(JNIEnv *, jobject value) { return value; }
static void delete_local_ref(JNIEnv *, jobject) {}
static jmethodID get_method_id(JNIEnv *, jclass, const char *, const char *) {
    return reinterpret_cast<jmethodID>(1);
}
static jboolean exception_check(JNIEnv *) {
    ++exception_checks;
    return pending_exception ? JNI_TRUE : JNI_FALSE;
}
static void exception_clear(JNIEnv *) {
    ++exception_clears;
    pending_exception = false;
}
static void delete_global_ref(JNIEnv *, jobject) {
    ++delete_calls;
    if (active_case == 3) pending_exception = true;
}
static jboolean call_boolean_method(JNIEnv *, jobject, jmethodID, va_list) {
    ++protect_jni_calls;
    return JNI_FALSE;
}
static jint push_local_frame(JNIEnv *, jint) {
    ++resolve_jni_calls;
    return -1;
}

static jint get_env(JavaVM *, void **result, jint) {
    ++get_env_calls;
    if (active_case == 4 || active_case == 5 || active_case == 6 ||
        active_case == 9 || active_case == 10 || active_case == 12 ||
        active_case == 13) {
        *result = nullptr;
        return JNI_EDETACHED;
    }
    if (active_case == 7) {
        *result = current_env;
        return JNI_EVERSION;
    }
    if (active_case == 11) {
        *result = nullptr;
        return JNI_OK;
    }
    *result = current_env;
    return JNI_OK;
}
static jint attach_current_thread(JavaVM *, JNIEnv **result, void *) {
    ++attach_calls;
    *result = active_case == 13 ? nullptr : current_env;
    if (active_case == 5 || active_case == 9 || active_case == 10) return JNI_ERR;
    return JNI_OK;
}
static jint detach_current_thread(JavaVM *) {
    ++detach_calls;
    return active_case == 6 || active_case == 12 ? JNI_ERR : JNI_OK;
}

// 捕获真实 core.cpp 在 JNI_OnLoad 中注册的三个生产回调。
extern "C" void registerCallbacks(protect_func protect_callback,
                                  resolve_process_func resolve_callback,
                                  release_object_func release_callback) {
    ++registrations;
    captured_protect = protect_callback;
    captured_resolve = resolve_callback;
    captured_release = release_callback;
}
extern "C" GoUint8 startTUN(int, void *) { return 0; }
extern "C" GoUint8 stopTun() { return 0; }
extern "C" void suspend(int) {}
extern "C" jint JNI_OnLoad(JavaVM *, void *);

// 旧版 void 回调仍可编译，但固定映射为 -1，避免把 ABI 编译失败误当成语义 RED。
template <typename Callback, typename... Arguments>
static int invoke_checked(Callback callback, Arguments &&...arguments) {
    using Result = std::invoke_result_t<Callback, Arguments...>;
    if constexpr (std::is_void_v<Result>) {
        callback(std::forward<Arguments>(arguments)...);
        return -1;
    } else {
        return static_cast<int>(callback(std::forward<Arguments>(arguments)...));
    }
}

static void reset_case_counters() {
    pending_exception = false;
    get_env_calls = 0;
    attach_calls = 0;
    detach_calls = 0;
    delete_calls = 0;
    exception_checks = 0;
    exception_clears = 0;
    protect_jni_calls = 0;
    resolve_jni_calls = 0;
    followup_result = -3;
}

static bool release_case(int case_number, int *result) {
    jobject object = &public_object;
    if (case_number == 8) object = nullptr;
    if (case_number == 2) pending_exception = true;
    *result = invoke_checked(captured_release, static_cast<void *>(object));
    switch (case_number) {
        case 1:
            return *result == 1 && get_env_calls == 1 && attach_calls == 0 &&
                   detach_calls == 0 && delete_calls == 1 && exception_clears == 0 &&
                   !pending_exception;
        case 2:
            return *result == 0 && get_env_calls == 1 && attach_calls == 0 &&
                   detach_calls == 0 && delete_calls == 0 && exception_clears == 1 &&
                   !pending_exception;
        case 3:
            return *result == 2 && get_env_calls == 1 && attach_calls == 0 &&
                   detach_calls == 0 && delete_calls == 1 && exception_clears == 1 &&
                   !pending_exception;
        case 4:
            return *result == 1 && get_env_calls == 1 && attach_calls == 1 &&
                   detach_calls == 1 && delete_calls == 1 && exception_clears == 0 &&
                   !pending_exception;
        case 5:
            return *result == 0 && get_env_calls == 1 && attach_calls == 1 &&
                   detach_calls == 0 && delete_calls == 0 && !pending_exception;
        case 6:
            return *result == 2 && get_env_calls == 1 && attach_calls == 1 &&
                   detach_calls == 1 && delete_calls == 1 && !pending_exception;
        case 7:
            return *result == 0 && get_env_calls == 1 && attach_calls == 0 &&
                   detach_calls == 0 && delete_calls == 0 && !pending_exception;
        case 8:
            return *result == 0 && get_env_calls == 0 && attach_calls == 0 &&
                   detach_calls == 0 && delete_calls == 0 && !pending_exception;
        case 11:
            return *result == 0 && get_env_calls == 1 && attach_calls == 0 &&
                   detach_calls == 0 && delete_calls == 0 && !pending_exception;
        case 13:
            return *result == 0 && get_env_calls == 1 && attach_calls == 1 &&
                   detach_calls == 1 && delete_calls == 0 && !pending_exception;
        default:
            return false;
    }
}

static bool protect_attach_failure_case(int *result) {
    *result = captured_protect(static_cast<void *>(&public_object), 0);
    return *result == 0 && get_env_calls == 1 && attach_calls == 1 &&
           detach_calls == 0 && protect_jni_calls == 0 && !pending_exception;
}

static bool resolve_attach_failure_case(int *result) {
    const char *resolved = captured_resolve(static_cast<void *>(&public_object), 0, "", "", 0);
    if (!resolved) {
        *result = -2;
        return false;
    }
    *result = resolved[0] == '\0' ? 0 : 1;
    std::free(const_cast<char *>(resolved));
    return *result == 0 && get_env_calls == 1 && attach_calls == 1 &&
           detach_calls == 0 && resolve_jni_calls == 0 && !pending_exception;
}

static bool protect_detach_failure_sticks_to_release_case(int *result) {
    *result = captured_protect(static_cast<void *>(&public_object), 0);
    active_case = 1;
    followup_result = invoke_checked(captured_release, static_cast<void *>(&public_object));
    return *result == 0 && followup_result == 2 && get_env_calls == 2 &&
           attach_calls == 1 && detach_calls == 1 && delete_calls == 1 &&
           protect_jni_calls == 1 && !pending_exception;
}

static bool protect_preexisting_exception_case(int *result) {
    pending_exception = true;
    *result = captured_protect(static_cast<void *>(&public_object), 0);
    return *result == 0 && exception_clears == 1 && protect_jni_calls == 0 &&
           !pending_exception;
}

static bool resolve_preexisting_exception_case(int *result) {
    pending_exception = true;
    const char *resolved = captured_resolve(static_cast<void *>(&public_object), 0, "", "", 0);
    if (!resolved) {
        *result = -2;
        return false;
    }
    *result = resolved[0] == '\0' ? 0 : 1;
    std::free(const_cast<char *>(resolved));
    return *result == 0 && exception_clears == 1 && resolve_jni_calls == 0 &&
           !pending_exception;
}

static bool protect_null_interface_case(int *result) {
    *result = captured_protect(nullptr, 0);
    return *result == 0 && protect_jni_calls == 0 && !pending_exception;
}

static bool resolve_null_interface_case(int *result) {
    const char *resolved = captured_resolve(nullptr, 0, "", "", 0);
    if (!resolved) {
        *result = -2;
        return false;
    }
    *result = resolved[0] == '\0' ? 0 : 1;
    std::free(const_cast<char *>(resolved));
    return *result == 0 && resolve_jni_calls == 0 && !pending_exception;
}

int main(int argc, char **argv) {
    int case_number = 0;
    if (argc == 2) case_number = static_cast<int>(std::strtol(argv[1], nullptr, 10));

    JNINativeInterface methods{};
    methods.FindClass = fixture_find_class;
    methods.NewGlobalRef = new_global_ref;
    methods.DeleteLocalRef = delete_local_ref;
    methods.GetMethodID = get_method_id;
    methods.ExceptionCheck = exception_check;
    methods.ExceptionClear = exception_clear;
    methods.DeleteGlobalRef = delete_global_ref;
    methods.CallBooleanMethodV = call_boolean_method;
    methods.PushLocalFrame = push_local_frame;
    JNIEnv env{&methods};
    current_env = &env;

    JNIInvokeInterface invocation{};
    invocation.GetEnv = get_env;
    invocation.AttachCurrentThread = attach_current_thread;
    invocation.DetachCurrentThread = detach_current_thread;
    JavaVM vm{&invocation};

    // 初始化必须先在正常模式完成，随后才切换到每个独立失败模式。
    active_case = 0;
    const bool initialized = JNI_OnLoad(&vm, nullptr) == JNI_VERSION_1_6 &&
                             registrations == 1 && captured_release && captured_protect &&
                             captured_resolve;
    active_case = case_number;
    reset_case_counters();

    int result = -3;
    bool passed = initialized;
    if (passed && ((case_number >= 1 && case_number <= 8) || case_number == 11 ||
                   case_number == 13)) {
        passed = release_case(case_number, &result);
    } else if (passed && case_number == 9) {
        passed = protect_attach_failure_case(&result);
    } else if (passed && case_number == 10) {
        passed = resolve_attach_failure_case(&result);
    } else if (passed && case_number == 12) {
        passed = protect_detach_failure_sticks_to_release_case(&result);
    } else if (passed && case_number == 14) {
        passed = protect_preexisting_exception_case(&result);
    } else if (passed && case_number == 15) {
        passed = resolve_preexisting_exception_case(&result);
    } else if (passed && case_number == 16) {
        passed = protect_null_interface_case(&result);
    } else if (passed && case_number == 17) {
        passed = resolve_null_interface_case(&result);
    } else {
        passed = false;
    }

    std::printf("{\"case\":%d,\"result\":%d,\"followup_result\":%d,"
                "\"get_env\":%d,\"attach\":%d,"
                "\"detach\":%d,\"delete\":%d,\"checks\":%d,\"clears\":%d,"
                "\"protect_jni\":%d,\"resolve_jni\":%d,\"failed\":%d}\n",
                case_number, result, followup_result, get_env_calls, attach_calls,
                detach_calls, delete_calls, exception_checks, exception_clears,
                protect_jni_calls, resolve_jni_calls, passed ? 0 : 1);
    return passed ? 0 : 1;
}
