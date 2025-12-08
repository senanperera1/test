#!/usr/bin/env bash
set -euxo pipefail

ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}
ANDROID_API=${ANDROID_API:-34}
ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS:-34.0.0}
ANDROID_NDK_VERSION=${ANDROID_NDK_VERSION:-26.3.11579264}

# Install Android SDK + NDK
if [ ! -d "${ANDROID_SDK_ROOT}/cmdline-tools/latest" ]; then
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"
  mv /tmp/cmdtools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"
fi
export PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"
yes | sdkmanager --licenses || true
sdkmanager "platform-tools" "platforms;android-${ANDROID_API}" "build-tools;${ANDROID_BUILD_TOOLS}" "ndk;${ANDROID_NDK_VERSION}"
NDK_DIR="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}"

# Build libtun2socks.so from Go
rm -rf core tun2socks-android || true
mkdir -p core
cd core
go mod init example.com/tun2socks-wrapper
echo 'package main; func main(){}' > main.go
CC="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang"
export CC CGO_ENABLED=1 GOOS=android GOARCH=arm64
go build -buildmode=c-shared -o libtun2socks.so
cd ..

# Create Android library project
mkdir -p tun2socks-android/src/main/java/com/example/tun2socks
mkdir -p tun2socks-android/src/main/cpp
mkdir -p tun2socks-android/src/main/jniLibs/arm64-v8a
cp core/libtun2socks.so tun2socks-android/src/main/jniLibs/arm64-v8a/

# Java API
cat > tun2socks-android/src/main/java/com/example/tun2socks/Tun2Socks.java <<'EOF'
package com.example.tun2socks;
public class Tun2Socks {
    static {
        System.loadLibrary("tun2socks_jni");
        System.loadLibrary("tun2socks");
    }
    public static native int start(int tunFd, String proxyUrl);
    public static native int stop();
    public static native String coreInfo();
}
EOF

# JNI bridge
cat > tun2socks-android/src/main/cpp/tun2socks_jni.c <<'EOF'
#include <jni.h>
#include <dlfcn.h>

typedef int (*start_fn)(int fd, const char *url);
typedef int (*stop_fn)();
typedef const char* (*info_fn)();

static void *handle; static start_fn core_start; static stop_fn core_stop; static info_fn core_info;

static void ensure_loaded() {
    if (handle) return;
    handle = dlopen("libtun2socks.so", RTLD_NOW);
    core_start = (start_fn)dlsym(handle, "tun2socks_start");
    core_stop  = (stop_fn)dlsym(handle, "tun2socks_stop");
    core_info  = (info_fn)dlsym(handle, "tun2socks_info");
}

JNIEXPORT jint JNICALL Java_com_example_tun2socks_Tun2Socks_start(JNIEnv *env,jclass,jint fd,jstring proxyUrl){
    ensure_loaded(); if(!core_start){return -2;}
    const char *url=(*env)->GetStringUTFChars(env,proxyUrl,0);
    int rc=core_start(fd,url);
    (*env)->ReleaseStringUTFChars(env,proxyUrl,url);
    return rc;
}

JNIEXPORT jint JNICALL Java_com_example_tun2socks_Tun2Socks_stop(JNIEnv *env,jclass){
    ensure_loaded(); if(!core_stop){return -2;}
    return core_stop();
}

JNIEXPORT jstring JNICALL Java_com_example_tun2socks_Tun2Socks_coreInfo(JNIEnv *env,jclass){
    ensure_loaded(); if(!core_info) return (*env)->NewStringUTF(env,"info not exported");
    const char *s=core_info();
    return (*env)->NewStringUTF(env,s?s:"null");
}
EOF

# Android.mk for JNI
cat > tun2socks-android/src/main/cpp/Android.mk <<'EOF'
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE    := tun2socks_jni
LOCAL_SRC_FILES := tun2socks_jni.c
LOCAL_LDLIBS    := -llog -ldl
include $(BUILD_SHARED_LIBRARY)
EOF

# Gradle configs
cat > tun2socks-android/build.gradle <<'EOF'
plugins { id 'com.android.library' }
android {
    namespace "com.example.tun2socks"
    compileSdk 34
    defaultConfig {
        minSdk 21
        targetSdk 34
        ndk { abiFilters 'arm64-v8a' }
    }
    sourceSets {
        main {
            java.srcDirs = ['src/main/java']
            jniLibs.srcDirs = ['src/main/jniLibs']
        }
    }
    externalNativeBuild { ndkBuild { path "src/main/cpp/Android.mk" } }
}
EOF

echo "include ':tun2socks-android'" > settings.gradle
cat > build.gradle <<'EOF'
buildscript {
    repositories { google(); mavenCentral() }
    dependencies { classpath 'com.android.tools.build:gradle:8.4.0' }
}
allprojects { repositories { google(); mavenCentral() } }
EOF

cd tun2socks-android
gradle wrapper --gradle-version 8.4
./gradlew :assembleRelease --stacktrace
