#include "jni_helper.h"
#include "libclash.h"
#include <cstdlib>
#include <cstring>

namespace {
constexpr jsize payload_limit = 16 * 1024 * 1024;

bool clear_exception(JNIEnv *env) {
    if (!env->ExceptionCheck()) return false;
    env->ExceptionClear();
    return true;
}

// Go回执使用C堆分配；无论Java字符串构造成功与否均释放一次。
jstring consume_reply(JNIEnv *env, char *reply) {
    if (!reply) return nullptr;
    const auto result = jni_new_string(env, reply);
    std::free(reply);
    return clear_exception(env) ? nullptr : result;
}

bool valid_input(JNIEnv *env, jstring input) {
    if (!input) return false;
    const jsize length = env->GetStringLength(input);
    if (clear_exception(env) || length <= 0 || length > payload_limit) return false;
    const jchar *chars = env->GetStringChars(input, nullptr);
    const bool chars_failed = clear_exception(env);
    if (chars_failed || !chars) {
        if (chars) {
            env->ReleaseStringChars(input, chars);
            clear_exception(env);
        }
        return false;
    }
    bool valid = true;
    for (jsize index = 0; index < length; ++index) {
        // C字符串不能表达内嵌NUL；拒绝截断为另一份有效JSON。
        if (chars[index] == 0) { valid = false; break; }
    }
    env->ReleaseStringChars(input, chars);
    return !clear_exception(env) && valid;
}
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_appshub_bettbox_core_Core_getOwnedConfigStatusNative(JNIEnv *env, jobject) {
    return consume_reply(env, getAndroidOwnedConfigStatus());
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(
    JNIEnv *env, jobject, jlong epoch, jlong revision, jint kind, jstring input) {
    if (!valid_input(env, input)) return nullptr;
    char *payload = jni_get_string(env, input);
    if (clear_exception(env) || !payload) {
        std::free(payload);
        return nullptr;
    }
    const auto length = std::strlen(payload);
    if (length == 0 || length > static_cast<size_t>(payload_limit)) {
        std::free(payload);
        return nullptr;
    }
    char *reply = commitAndroidOwnedConfig(epoch, revision, kind, payload);
    std::free(payload);
    return consume_reply(env, reply);
}
