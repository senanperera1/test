#!/usr/bin/env bash
set -euxo pipefail

# -------- Env --------
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}
ANDROID_API=${ANDROID_API:-34}
ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS:-34.0.0}
# Use an NDK version CI installs consistently. Logs showed 26.1 gets installed even when 26.3 was requested.
ANDROID_NDK_VERSION=${ANDROID_NDK_VERSION:-26.1.10909125}

# -------- Install Android cmdline-tools + accept licenses non-interactively --------
if [ ! -d "${ANDROID_SDK_ROOT}/cmdline-tools/latest" ]; then
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip
  mkdir -p /tmp/cmdtools
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"
  mv /tmp/cmdtools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"
fi

export PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

# Accept ALL licenses without prompts (prevents CI hang)
yes | sdkmanager --licenses || true

# Install required SDK components
sdkmanager "platform-tools" \
           "platforms;android-${ANDROID_API}" \
           "build-tools;${ANDROID_BUILD_TOOLS}" \
           "ndk;${ANDROID_NDK_VERSION}"

# Detect actual installed NDK (handles side-by-side installs)
NDK_DIR=$(ls -d "${ANDROID_SDK_ROOT}/ndk/"*/ 2>/dev/null | sort -V | tail -n1 | sed 's:/*$::')
if [ -z "${NDK_DIR}" ]; then
  echo "NDK not found under ${ANDROID_SDK_ROOT}/ndk" >&2
  exit 1
fi
echo "Using NDK at ${NDK_DIR}"

# -------- Build libtun2socks.so (Go, arm64) with real exports --------
rm -rf core tun2socks-android || true
mkdir -p core
cd core

go mod init example.com/tun2socks-wrapper

# Pull tun2socks v1 (stable API) to avoid CI surprises
go get "github.com/xjasonlyu/tun2socks@v1.18.3"
go mod tidy

# Export native functions used by JNI and call v1 engine
cat > main.go <<'EOF'
package main
/*
#include <stdlib.h>
*/
import "C"

import (
    "encoding/json"
    "fmt"
    "strings"

    engine "github.com/xjasonlyu/tun2socks/engine"
)

var started bool

func buildConfig(fd int, proxy string) string {
    p := proxy
    if !strings.Contains(p, "://") {
        p = "socks5://" + p
    }
    cfg := map[string]any{
        "device":   map[string]any{"fdbased": map[string]any{"fd": fd}},
        "proxy":    map[string]any{"socks5":  map[string]any{"addr": p}},
        "netstack": map[string]any{"enable":  true},
    }
    b, _ := json.Marshal(cfg)
    return string(b)
}

//export tun2socks_start
func tun2socks_start(fd C.int, proxy *C.char) C.int {
    if started {
        return 0
    }
    cfg := buildConfig(int(fd), C.GoString(proxy))
    if err := engine.Start(cfg); err != nil {
        return -1
    }
    started = true
    return 0
}

//export tun2socks_stop
func tun2socks_stop() C.int {
    if !started {
        return 0
    }
    engine.Stop()
    started = false
    return 0
}

//export tun2socks_info
func tun2socks_info() *C.char {
    return C.CString(fmt.Sprintf("tun2socks v1: started=%v", started))
}

func main() {}
EOF

# Cross-compile for Android arm64 with NDK clang
CC="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang"
export CC CGO_ENABLED=1 GOOS=android GOARCH=arm64
go build -buildmode=c-shared -o libtun2socks.so

cd ..

# -------- Android library project with JNI wrapper --------
mkdir -p tun2socks-android/src/main/java/com/example/tun2socks
mkdir -p tun2socks-android/src/main/cpp
mkdir -p tun2socks-android/src/main/jniLibs/arm64-v8a

# Include the Go-built shared library
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

# JNI bridge that forwards to Go exports in libtun2socks.so
cat > tun2socks-android/src/main/cpp/tun2socks_jni.c <<'EOF'
#include <jni.h>
#include <dlfcn.h>

typedef int (*start_fn)(int fd, const char *url);
typedef int (*stop_fn)();
typedef const char* (*info_fn)();

static void *handle = NULL;
static start_fn core_start = NULL;
static stop_fn  core_stop  = NULL;
static info_fn  core_info  = NULL;

static void ensure_loaded() {
    if (handle) return;
    handle = dlopen("libtun2socks.so", RTLD_NOW);
    if (!handle) return;
    core_start = (start_fn)dlsym(handle, "tun2socks_start");
    core_stop  = (stop_fn)dlsym(handle, "tun2socks_stop");
    core_info  = (info_fn)dlsym(handle, "tun2socks_info");
}

JNIEXPORT jint JNICALL Java_com_example_tun2socks_Tun2Socks_start(JNIEnv *env, jclass clazz, jint fd, jstring proxyUrl) {
    ensure_loaded();
    if (!core_start) return -2;
    const char *url = (*env)->GetStringUTFChars(env, proxyUrl, 0);
    int rc = core_start(fd, url);
    (*env)->ReleaseStringUTFChars(env, proxyUrl, url);
    return rc;
}

JNIEXPORT jint JNICALL Java_com_example_tun2socks_Tun2Socks_stop(JNIEnv *env, jclass clazz) {
    ensure_loaded();
    if (!core_stop) return -2;
    return core_stop();
}

JNIEXPORT jstring JNICALL Java_com_example_tun2socks_Tun2Socks_coreInfo(JNIEnv *env, jclass clazz) {
    ensure_loaded();
    if (!core_info) return (*env)->NewStringUTF(env, "info not exported");
    const char *s = core_info();
    return (*env)->NewStringUTF(env, s ? s : "null");
}
EOF

# NDK build file for JNI
cat > tun2socks-android/src/main/cpp/Android.mk <<'EOF'
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE    := tun2socks_jni
LOCAL_SRC_FILES := tun2socks_jni.c
LOCAL_LDLIBS    := -llog -ldl
include $(BUILD_SHARED_LIBRARY)
EOF

# Module build.gradle (pin AGP to 8.6)
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

    // Use ndk-build for the JNI bridge
    externalNativeBuild {
        ndkBuild {
            path "src/main/cpp/Android.mk"
        }
    }

    // Pin the NDK version to what CI installed (prevents mismatches)
    ndkVersion "26.1.10909125"
}
EOF

# Root settings.gradle
echo "include ':tun2socks-android'" > settings.gradle

# Root build.gradle (AGP 8.6 requires Gradle 8.6+)
cat > build.gradle <<'EOF'
buildscript {
    repositories { google(); mavenCentral() }
    dependencies { classpath 'com.android.tools.build:gradle:8.6.0' }
}
allprojects { repositories { google(); mavenCentral() } }
EOF

# -------- Pin Gradle wrapper to 8.6 and build --------
gradle wrapper --gradle-version 8.6

# Build AAR using wrapper from repo root
./gradlew :tun2socks-android:assembleRelease --stacktrace
