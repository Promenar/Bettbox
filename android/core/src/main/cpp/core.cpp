#ifdef LIBCLASH
#include <jni.h>
#include <cstring>

static jmethodID m_fd_lease_peek;
static jmethodID m_fd_lease_claim;

// 回调异常只转换成固定失败，禁止描述包含私有参数的Java异常。
static bool clear_callback_exception(JNIEnv *env) {
    if (!env->ExceptionCheck()) return false;
    env->ExceptionClear();
    return true;
}
#include "jni_helper.h"
#include "libclash.h"

// 删除只尝试一次；异常不能证明引用已释放，也不能安全地重复删除。
static void release_preclaim_callback(JNIEnv *env, jobject callback) {
    if (!callback) return;
    del_global(callback);
    if (clear_callback_exception(env)) jni_mark_cleanup_unknown();
}

extern "C"
JNIEXPORT jboolean JNICALL
Java_com_appshub_bettbox_core_Core_startNativeTun(JNIEnv *env, jobject, jobject lease, jobject cb) {
    if (!lease || jni_cleanup_unknown()) return JNI_FALSE;
    const jint pending_fd = env->CallIntMethod(lease, m_fd_lease_peek);
    if (clear_callback_exception(env) || pending_fd < 0) return JNI_FALSE;

    jobject interface = nullptr;
    if (pending_fd > 0) {
        if (!cb) return JNI_FALSE;
        interface = new_global(cb);
        if (clear_callback_exception(env) || !interface) {
            release_preclaim_callback(env, interface);
            return JNI_FALSE;
        }
    }
    const jint fd = env->CallIntMethod(lease, m_fd_lease_claim);
    const bool claim_failed = clear_callback_exception(env);
    // Java领取抛异常时，无法从返回值确认FD是否已经移交。
    if (claim_failed) jni_mark_cleanup_unknown();
    if (claim_failed || fd < 0) {
        release_preclaim_callback(env, interface);
        return JNI_FALSE;
    }
    // 从领取开始，FD与global ref均由Go接管，包括失败返回路径。
    return startTUN(fd, interface) ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT jboolean JNICALL
Java_com_appshub_bettbox_core_Core_stopNativeTun(JNIEnv *) {
    // 未知JNI责任不阻止Go收回已知资源，但不能报告整体清理成功。
    const bool stopped = stopTun();
    return stopped && !jni_cleanup_unknown() ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT void JNICALL
Java_com_appshub_bettbox_core_Core_suspend(JNIEnv *, jobject, jint suspended) {
    suspend(suspended);
}


static jmethodID m_tun_interface_protect;
static jmethodID m_tun_interface_resolve_process;


// 显式finish参与返回判定，析构仅作为所有提前返回的同一次保底收尾。
struct callback_thread_scope {
    scoped_jni value{};
    callback_thread_scope() { jni_attach_thread(&value); }
    ~callback_thread_scope() { jni_detach_thread(&value); }
    bool finish() { return jni_finish_thread_checked(&value); }
};

static int release_jni_object_impl(void *obj) {
    if (!obj) return jni_cleanup_unknown() ? 2 : 0;
    callback_thread_scope thread;
    JNIEnv *env = thread.value.env;
    int result = 0;
    if (env && !clear_callback_exception(env)) {
        del_global(static_cast<jobject>(obj));
        result = clear_callback_exception(env) ? 2 : 1;
    }
    if (!thread.finish() || jni_cleanup_unknown()) return 2;
    return result;
}

static int call_tun_interface_protect_impl(void *tun_interface, const int fd) {
    callback_thread_scope thread;
    JNIEnv *env = thread.value.env;
    int result = 0;
    if (env && !clear_callback_exception(env) && tun_interface && !jni_cleanup_unknown()) {
        const jboolean protected_socket = env->CallBooleanMethod(static_cast<jobject>(tun_interface),
                            m_tun_interface_protect, fd);
        if (!clear_callback_exception(env) && protected_socket == JNI_TRUE) result = 1;
    }
    if (!thread.finish() || jni_cleanup_unknown()) return 0;
    return result;
}

static const char *
call_tun_interface_resolve_process_impl(void *tun_interface, int protocol,
                                        const char *source,
                                        const char *target,
                                        const int uid) {
    callback_thread_scope thread;
    JNIEnv *env = thread.value.env;
    const auto fail = [&]() -> const char * { thread.finish(); return strdup(""); };
    if (!env) return fail();
    if (clear_callback_exception(env) || !tun_interface || jni_cleanup_unknown()) return fail();
    if (env->PushLocalFrame(8) < 0) {
        clear_callback_exception(env);
        return fail();
    }
    const auto sourceString = new_string(source);
    if (!sourceString || clear_callback_exception(env)) {
        env->PopLocalFrame(nullptr);
        clear_callback_exception(env);
        return fail();
    }
    const auto targetString = new_string(target);
    if (!targetString || clear_callback_exception(env)) {
        env->PopLocalFrame(nullptr);
        clear_callback_exception(env);
        return fail();
    }
    const auto packageName = reinterpret_cast<jstring>(env->CallObjectMethod(static_cast<jobject>(tun_interface),
                                                                       m_tun_interface_resolve_process,
                                                                       protocol,
                                                                       sourceString,
                                                                       targetString,
                                                                       uid));
    if (clear_callback_exception(env) || !packageName) {
        env->PopLocalFrame(nullptr);
        clear_callback_exception(env);
        return fail();
    }
    const auto result = get_string(packageName);
    const bool failed = clear_callback_exception(env);
    env->PopLocalFrame(nullptr);
    const bool frame_failed = clear_callback_exception(env);
    const bool finished = thread.finish();
    if (failed || frame_failed || !finished || jni_cleanup_unknown()) {
        free(const_cast<char *>(result));
        return strdup("");
    }
    return result;
}

extern "C"
JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    if (!initialize_jni(vm, env)) return JNI_ERR;
    const auto load_failed = [&]() {
        release_jni_initialization(env);
        m_tun_interface_protect = nullptr;
        m_tun_interface_resolve_process = nullptr;
        m_fd_lease_peek = nullptr;
        m_fd_lease_claim = nullptr;
        return JNI_ERR;
    };

    const auto c_tun_interface = find_class("com/appshub/bettbox/core/TunInterface");
    if (clear_callback_exception(env) || !c_tun_interface) return load_failed();

    m_tun_interface_protect = find_method(c_tun_interface, "protect", "(I)Z");
    if (clear_callback_exception(env) || !m_tun_interface_protect) return load_failed();
    m_tun_interface_resolve_process = find_method(c_tun_interface, "resolverProcess",
                                                  "(ILjava/lang/String;Ljava/lang/String;I)Ljava/lang/String;");

    if (clear_callback_exception(env) || !m_tun_interface_resolve_process) return load_failed();
    const auto c_fd_lease = find_class("com/appshub/bettbox/core/TunFDLease");
    if (clear_callback_exception(env) || !c_fd_lease) return load_failed();
    m_fd_lease_peek = find_method(c_fd_lease, "peek", "()I");
    if (clear_callback_exception(env) || !m_fd_lease_peek) return load_failed();
    m_fd_lease_claim = find_method(c_fd_lease, "claim", "()I");
    if (clear_callback_exception(env) || !m_fd_lease_claim) return load_failed();

    registerCallbacks(&call_tun_interface_protect_impl,
                      &call_tun_interface_resolve_process_impl,
                      &release_jni_object_impl);
    return JNI_VERSION_1_6;
}
#endif
