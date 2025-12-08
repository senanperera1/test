#!/usr/bin/env bash
set -euxo pipefail

# -------- Config --------
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}
ANDROID_API=${ANDROID_API:-34}
ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS:-34.0.0}
ANDROID_NDK_VERSION=${ANDROID_NDK_VERSION:-26.1.10909125} # install exactly this

# Helper: retry a command up to N times with sleep
retry() {
  local tries=$1; shift
  local delay=$1; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if [ "$n" -ge "$tries" ]; then
      echo "Command failed after $tries attempts: $*" >&2
      return 1
    fi
    echo "Retry $n/$tries: $*"
    sleep "$delay"
  done
}

# -------- Install cmdline-tools + accept licenses --------
if [ ! -d "${ANDROID_SDK_ROOT}/cmdline-tools/latest" ]; then
  retry 3 5 wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip
  mkdir -p /tmp/cmdtools
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"
  mv /tmp/cmdtools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"
fi

export PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

# Licenses: non-interactive, ignore Broken pipe if stdin closes early
yes | sdkmanager --licenses || true

# Install SDK components (retry for flakiness)
retry 3 10 sdkmanager "platform-tools" \
                     "platforms;android-${ANDROID_API}" \
                     "build-tools;${ANDROID_BUILD_TOOLS}" \
                     "ndk;${ANDROID_NDK_VERSION}"

# Use exactly the requested NDK (avoid auto-picking highest)
NDK_DIR="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}"
if [ ! -d "${NDK_DIR}" ]; then
  echo "Requested NDK ${ANDROID_NDK_VERSION} not found at ${NDK_DIR}" >&2
  ls -la "${ANDROID_SDK_ROOT}/ndk/" || true
  exit 1
fi
echo "Using NDK at ${NDK_DIR}"

# -------- Build libtun2socks.so (Go v2, arm64) with resilient wrapper --------
rm -rf core tun2socks-android || true
mkdir -p core
cd core

go mod init example.com/tun2socks-wrapper

# Add v2 module and engine; tidy with retries
retry 3 5 go get "github.com/xjasonlyu/tun2socks/v2@v2.6.0"
retry 3 5 go get "github.com/xjasonlyu/tun2socks/v2/engine@v2.6.0"
go mod tidy

# The wrapper tries InsertJSON first; if InsertJSON signature changes,
# it falls back to a simplified Start-only path via a tiny adapter.
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

    engine "github.com/xjasonlyu/tun2socks/v2/engine"
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
    conf := buildConfig(int(fd), C.GoString(proxy))
    // Preferred path: Insert config JSON then start
    if err := engine.InsertJSON(conf); err != nil {
        // Fallback: attempt Start with minimal side effects if InsertJSON signature differs
        // Note: engine.Start() uses last inserted config; if insert fails, Start won't apply changes.
        // In that case we return an error to signal the JNI.
        return -1
    }
    engine.Start()
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
    return C.CString(fmt.Sprintf("tun2socks v2: started=%v", started))
}

func main() {}
EOF

# Cross-compile for Android arm64 with NDK clang; include common CGO flags
CC="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang"
export CC CGO_ENABLED=1 GOOS=android GOARCH=arm64
export CGO_CFLAGS="-fPIC"
export CGO_LDFLAGS="-llog -ldl"
retry 2 5 go build -buildmode=c-shared -o libtun2socks.so

cd ..

# -------- Android library with JNI wrapper --------
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

# Module build.gradle (AGP 8.6, match NDK)
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

    externalNativeBuild {
        ndkBuild { path "src/main/cpp/Android.mk" }
    }

    ndkVersion "26.1.10909125"
}
EOF

# Root Gradle setup (AGP 8.6 requires Gradle 8.6+)
echo "include ':tun2socks-android'" > settings.gradle
cat > build.gradle <<'EOF'
buildscript {
    repositories { google(); mavenCentral() }
    dependencies { classpath 'com.android.tools.build:gradle:8.6.0' }
}
allprojects { repositories { google(); mavenCentral() } }
EOF

# Gradle wrapper pinned to 8.6 and robust flags
gradle wrapper --gradle-version 8.6

# Build AAR using wrapper
# Add flags to avoid daemon issues and speed repeated builds on CI
export GRADLE_OPTS="-Dorg.gradle.jvmargs='-Xmx2g -Dfile.encoding=UTF-8' -Dorg.gradle.daemon=false"
./gradlew :tun2socks-android:assembleRelease --stacktrace --no-daemon
