#include "jni_helper.h"

#include <cstdlib>
#include <malloc.h>
#include <cstring>

static JavaVM *global_vm;

static jclass c_string;
static jmethodID m_new_string;
static jmethodID m_get_bytes;

static bool clear_pending_exception(JNIEnv *env) {
    if (!env->ExceptionCheck()) return false;
    env->ExceptionClear();
    return true;
}

void release_jni_initialization(JNIEnv *env) {
    clear_pending_exception(env);
    if (c_string) del_global(c_string);
    c_string = nullptr;
    m_new_string = nullptr;
    m_get_bytes = nullptr;
}

bool initialize_jni(JavaVM *vm, JNIEnv *env) {
    release_jni_initialization(env);
    global_vm = vm;
    const auto local_class = find_class("java/lang/String");
    if (clear_pending_exception(env) || !local_class) return false;
    c_string = reinterpret_cast<jclass>(new_global(local_class));
    env->DeleteLocalRef(local_class);
    if (clear_pending_exception(env) || !c_string) {
        release_jni_initialization(env);
        return false;
    }
    const auto fail = [&]() {
        release_jni_initialization(env);
        return false;
    };
    m_new_string = find_method(c_string, "<init>", "([B)V");
    if (clear_pending_exception(env) || !m_new_string) return fail();
    m_get_bytes = find_method(c_string, "getBytes", "()[B");
    if (clear_pending_exception(env) || !m_get_bytes) return fail();
    return true;
}

JavaVM *global_java_vm() {
    return global_vm;
}

char *jni_get_string(JNIEnv *env, jstring str) {
    if (!str || !m_get_bytes) return strdup("");
    const auto array = reinterpret_cast<jbyteArray>(env->CallObjectMethod(str, m_get_bytes));
    if (env->ExceptionCheck() || !array) {
        env->ExceptionClear();
        return strdup("");
    }
    const int length = env->GetArrayLength(array);
    if (env->ExceptionCheck() || length < 0) {
        env->ExceptionClear();
        return strdup("");
    }
    const auto content = static_cast<char *>(malloc(static_cast<size_t>(length) + 1));
    if (!content) return nullptr;
    env->GetByteArrayRegion(array, 0, length, reinterpret_cast<jbyte *>(content));
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        free(content);
        return strdup("");
    }
    content[length] = 0;
    return content;
}

jstring jni_new_string(JNIEnv *env, const char *str) {
    if (!str || !c_string || !m_new_string) return nullptr;
    const auto length = static_cast<int>(strlen(str));
    const auto array = env->NewByteArray(length);
    if (clear_pending_exception(env) || !array) return nullptr;
    env->SetByteArrayRegion(array, 0, length, reinterpret_cast<const jbyte *>(str));
    if (clear_pending_exception(env)) {
        env->DeleteLocalRef(array);
        return nullptr;
    }
    const auto result = reinterpret_cast<jstring>(env->NewObject(c_string, m_new_string, array));
    env->DeleteLocalRef(array);
    if (clear_pending_exception(env)) return nullptr;
    return result;
}

int jni_catch_exception(JNIEnv *env) {
    const int result = env->ExceptionCheck();
    if (result) {
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
    return result;
}

void jni_attach_thread(scoped_jni *jni) {
    JavaVM *vm = global_java_vm();
    if (vm->GetEnv(reinterpret_cast<void **>(&jni->env), JNI_VERSION_1_6) == JNI_OK) {
        jni->require_release = 0;
        return;
    }
    if (vm->AttachCurrentThread(&jni->env, nullptr) != JNI_OK) {
        abort();
    }
    jni->require_release = 1;
}

void jni_detach_thread(const scoped_jni *env) {
    JavaVM *vm = global_java_vm();
    if (env->require_release) {
        vm->DetachCurrentThread();
    }
}

void release_string(char **str) {
    free(*str);
}
