#include <jni.h>

#include <string.h>

#include <string>

#include "qz_core.h"

namespace {

// Strings cross JNI as UTF-8 byte arrays: GetStringUTFChars / NewStringUTF
// use Modified UTF-8, which mangles emoji in node names.
std::string to_string(JNIEnv* env, jbyteArray bytes) {
    if (bytes == nullptr) {
        return {};
    }
    std::string out(static_cast<size_t>(env->GetArrayLength(bytes)), '\0');
    env->GetByteArrayRegion(bytes, 0, static_cast<jsize>(out.size()), reinterpret_cast<jbyte*>(out.data()));
    return out;
}

} // namespace

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_splitvpn_android_core_CoreClient_callNative(
    JNIEnv* env,
    jclass,
    jbyteArray root,
    jbyteArray request) {
    const std::string root_text = to_string(env, root);
    const std::string request_text = to_string(env, request);
    char* reply = qz_core_call(root_text.c_str(), request_text.c_str());
    if (reply == nullptr) {
        return nullptr;
    }
    const jsize length = static_cast<jsize>(strlen(reply));
    jbyteArray result = env->NewByteArray(length);
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, length, reinterpret_cast<const jbyte*>(reply));
    }
    qz_core_free(reply);
    return result;
}
