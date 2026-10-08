#include "jni_helper.h"
#include "libclash.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

// 公开JNI函数表夹具，不启动JVM、Go runtime、VPN或文件描述符。
struct InputString : _jstring { std::u16string chars; std::string bytes; };
struct ByteArray : _jbyteArray { std::string bytes; };
static _jclass string_class;
static _jstring output_string;
static ByteArray input_bytes, output_bytes;
static InputString *active_input;
static bool pending;
static int failure, releases, commits, queries;
static bool null_reply;
static long long received_epoch, received_revision;
static int received_kind;
static bool received_payload;

static jclass find_class_fixture(JNIEnv *, const char *) { return &string_class; }
static jobject global_ref(JNIEnv *, jobject value) { return value; }
static jmethodID method(JNIEnv *, jclass, const char *, const char *) { return reinterpret_cast<jmethodID>(1); }
static jboolean exception_check(JNIEnv *) { return pending ? JNI_TRUE : JNI_FALSE; }
static void exception_clear(JNIEnv *) { pending = false; }
static void delete_ref(JNIEnv *, jobject) {}
static jsize string_length(JNIEnv *, jstring value) {
    if (failure == 1) pending = true;
    return static_cast<jsize>(static_cast<InputString *>(value)->chars.size());
}
static const jchar *string_chars(JNIEnv *, jstring value, jboolean *) {
    if (failure == 2) pending = true;
    return reinterpret_cast<const jchar *>(static_cast<InputString *>(value)->chars.data());
}
static void release_chars(JNIEnv *, jstring, const jchar *) { ++releases; }
static jobject call_object(JNIEnv *, jobject, jmethodID, va_list) {
    if (failure == 3) { pending = true; return nullptr; }
    input_bytes.bytes = active_input->bytes;
    return &input_bytes;
}
static jsize array_length(JNIEnv *, jarray value) {
    return static_cast<jsize>(static_cast<ByteArray *>(value)->bytes.size());
}
static void get_bytes(JNIEnv *, jbyteArray value, jsize start, jsize length, jbyte *target) {
    if (failure == 4) { pending = true; return; }
    std::memcpy(target, static_cast<ByteArray *>(value)->bytes.data() + start, length);
}
static jbyteArray new_bytes(JNIEnv *, jsize length) {
    if (failure == 5) { pending = true; return nullptr; }
    output_bytes.bytes.assign(static_cast<size_t>(length), '\0');
    return &output_bytes;
}
static void set_bytes(JNIEnv *, jbyteArray value, jsize start, jsize length, const jbyte *source) {
    if (failure == 6) { pending = true; return; }
    std::memcpy(static_cast<ByteArray *>(value)->bytes.data() + start, source, length);
}
static jobject new_object(JNIEnv *, jclass, jmethodID, va_list) {
    if (failure == 7) { pending = true; return nullptr; }
    return &output_string;
}

extern "C" char *getAndroidOwnedConfigStatus() {
    ++queries;
    if (null_reply) return nullptr;
    return strdup("{\"outcome\":\"rejected\"}");
}
extern "C" char *commitAndroidOwnedConfig(long long epoch, long long revision, int kind, char *payload) {
    ++commits;
    received_epoch = epoch; received_revision = revision; received_kind = kind;
    received_payload = std::strcmp(payload, "{\"public\":true}") == 0;
    if (null_reply) return nullptr;
    return strdup("{\"outcome\":\"staged\"}");
}
extern "C" jstring Java_com_appshub_bettbox_core_Core_getOwnedConfigStatusNative(JNIEnv *, jobject);
extern "C" jstring Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(JNIEnv *, jobject, jlong, jlong, jint, jstring);

int main() {
    JNINativeInterface methods{};
    methods.FindClass = find_class_fixture; methods.NewGlobalRef = global_ref;
    methods.GetMethodID = method; methods.ExceptionCheck = exception_check;
    methods.ExceptionClear = exception_clear; methods.DeleteLocalRef = delete_ref;
    methods.DeleteGlobalRef = delete_ref; methods.GetStringLength = string_length;
    methods.GetStringChars = string_chars; methods.ReleaseStringChars = release_chars;
    methods.CallObjectMethodV = call_object; methods.GetArrayLength = array_length;
    methods.GetByteArrayRegion = get_bytes; methods.NewByteArray = new_bytes;
    methods.SetByteArrayRegion = set_bytes; methods.NewObjectV = new_object;
    JNIEnv env{&methods};
    if (!initialize_jni(nullptr, &env)) return 1;
    int failed = 0, cases = 0;
    auto reset = [&]() { pending = false; failure = 0; null_reply = false; releases = commits = queries = 0; received_payload = false; };
    auto check = [&](bool valid) { ++cases; if (!valid) ++failed; };
    InputString input; input.chars = u"{\"public\":true}"; input.bytes = "{\"public\":true}";
    active_input = &input;
    reset();
    check(Java_com_appshub_bettbox_core_Core_getOwnedConfigStatusNative(&env, nullptr) != nullptr && queries == 1 && !pending);
    reset();
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &input) != nullptr &&
          commits == 1 && releases == 1 && received_epoch == 7 && received_revision == 9 && received_kind == 3 && received_payload && !pending);
    reset();
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, nullptr) == nullptr && commits == 0);
    InputString nul; nul.chars = std::u16string(u"{}\0{}", 5); nul.bytes = std::string("{}\0{}", 5);
    active_input = &nul; reset();
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &nul) == nullptr && commits == 0 && releases == 1 && !pending);
    InputString empty; active_input = &empty; reset();
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &empty) == nullptr && commits == 0);
    active_input = &input;
    for (int mode = 1; mode <= 4; ++mode) {
        reset(); failure = mode;
        check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &input) == nullptr && commits == 0 && !pending &&
              (mode != 2 || releases == 1));
    }
    for (int mode = 5; mode <= 7; ++mode) {
        reset(); failure = mode;
        check(Java_com_appshub_bettbox_core_Core_getOwnedConfigStatusNative(&env, nullptr) == nullptr && queries == 1 && !pending);
    }
    reset(); null_reply = true;
    check(Java_com_appshub_bettbox_core_Core_getOwnedConfigStatusNative(&env, nullptr) == nullptr && queries == 1 && !pending);
    reset(); null_reply = true;
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &input) == nullptr && commits == 1 && !pending);
    constexpr size_t limit = 16 * 1024 * 1024;
    InputString too_long; too_long.chars.assign(limit + 1, u'a');
    active_input = &too_long; reset();
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &too_long) == nullptr && commits == 0 && releases == 0);
    // 三字节BMP字符使UTF-8预算先于UTF-16长度预算触发。
    InputString unicode;
    unicode.chars.assign(limit / 3, u'中'); unicode.chars.push_back(u'a');
    unicode.bytes.reserve(limit + 1);
    for (size_t index = 0; index < limit / 3; ++index) unicode.bytes.append("\xe4\xb8\xad");
    unicode.bytes.push_back('a');
    active_input = &unicode; reset();
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &unicode) != nullptr && commits == 1 && releases == 1 && !pending);
    unicode.chars.push_back(u'a'); unicode.bytes.push_back('a'); reset();
    check(Java_com_appshub_bettbox_core_Core_commitOwnedConfigNative(&env, nullptr, 7, 9, 3, &unicode) == nullptr && commits == 0 && releases == 1 && !pending);
    std::printf("{\"native_config_cases\":%d,\"failed\":%d,\"actual_JVM\":false}\n", cases, failed);
    release_jni_initialization(&env);
    return failed ? 1 : 0;
}
