#include "jni_helper.h"
#include "libclash.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
static int owned_starts, owned_stops, owned_fd;
static _jbyteArray bytes;
static _jstring reply_string;

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
    return mode >= 5 && mode != 6 ? 7 : -1;
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
extern "C" int suspendChecked(int) { return 0; }
extern "C" jint JNI_OnLoad(JavaVM *, void *);
extern "C" jboolean Java_com_appshub_bettbox_core_Core_startNativeTun(JNIEnv *, jobject, jobject, jobject);
extern "C" jboolean Java_com_appshub_bettbox_core_Core_stopNativeTun(JNIEnv *);

static jbyteArray newBytes(JNIEnv *, jsize) { return &bytes; }
static void setBytes(JNIEnv *, jbyteArray, jsize, jsize, const jbyte *) {}
static jobject newString(JNIEnv *, jclass, jmethodID, va_list) {
    if (mode == 8) { pending=true;return nullptr; }
    return &reply_string;
}
extern "C" char *startTUNOwned(long long epoch, long long revision, long long generation, int fd, void *) {
    ++owned_starts; owned_fd=fd;
    if(epoch!=1 || revision!=2 || generation!=3) std::abort();
    return mode==7 ? nullptr : strdup("public receipt");
}
extern "C" char *stopTUNOwned(long long epoch, long long revision, long long generation) {
    ++owned_stops;
    if(epoch!=1 || revision!=2 || generation!=3) std::abort();
    if(mode==9) jni_mark_cleanup_unknown();
    return strdup("public stop receipt");
}
extern "C" jstring Java_com_appshub_bettbox_core_Core_startOwnedTunNative(JNIEnv *,jobject,jlong,jlong,jlong,jobject,jobject);
extern "C" jstring Java_com_appshub_bettbox_core_Core_stopOwnedTunNative(JNIEnv *,jobject,jlong,jlong,jlong);
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    mode=std::atoi(argv[1]);if(mode<1 || mode>9) return 2;
    JNINativeInterface methods{};
    methods.FindClass=findClass;methods.NewGlobalRef=globalRef;methods.GetMethodID=method;
    methods.CallIntMethodV=callInt;methods.ExceptionCheck=exceptionCheck;methods.ExceptionClear=exceptionClear;
    methods.DeleteGlobalRef=deleteGlobal;methods.DeleteLocalRef=deleteLocal;
    methods.NewByteArray=newBytes;methods.SetByteArrayRegion=setBytes;methods.NewObjectV=newString;
    JNIEnv env{&methods};current_env=&env;
    JNIInvokeInterface invocation{};invocation.GetEnv=getEnv;JavaVM vm{&invocation};
    if(JNI_OnLoad(&vm,nullptr)!=JNI_VERSION_1_6) return 3;
    const auto reply=Java_com_appshub_bettbox_core_Core_startOwnedTunNative(&env,nullptr,1,2,3,&lease,&callback);
    const bool expects_reply=mode==4 || mode==5 || mode==9;
    int failed=(reply!=nullptr)!=expects_reply;
    failed+=pending;
    failed+=owned_starts!=(mode==4 || mode>=5 && mode!=6 ? 1 : 0);
    if(owned_starts) failed+=owned_fd!=(mode==4 ? -1 : 7);
    failed+=deletes!=(mode<=4 ? 1 : 0);
    if(mode<=3) {
        const int previous_peeks=peeks,previous_claims=claims;
        failed+=Java_com_appshub_bettbox_core_Core_startOwnedTunNative(&env,nullptr,1,2,3,&lease,&callback)!=nullptr;
        failed+=peeks!=previous_peeks || claims!=previous_claims || owned_starts!=0 || deletes!=1;
    }
    const auto stop=Java_com_appshub_bettbox_core_Core_stopOwnedTunNative(&env,nullptr,1,2,3);
    failed+=(stop!=nullptr)!=(mode>3 && mode!=8 && mode!=9);
    failed+=owned_stops!=1 || pending;
    std::printf("{\"case\":%d,\"failed\":%d,\"actual_JVM\":false}\n",mode,failed);
    return failed ? 1 : 0;
}
