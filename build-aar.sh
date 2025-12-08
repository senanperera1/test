#!/usr/bin/env bash
set -euxo pipefail

# -------- Config --------
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}
ANDROID_API=${ANDROID_API:-34}
ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS:-34.0.0}
ANDROID_NDK_VERSION=${ANDROID_NDK_VERSION:-26.1.10909125} # install exactly this

# Helper: retry
retry() { local t=$1; shift; local d=$1; shift; local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge "$t" ] && return 1; sleep "$d"; done; }

# -------- Install cmdline-tools + accept licenses --------
if [ ! -d "${ANDROID_SDK_ROOT}/cmdline-tools/latest" ]; then
  retry 3 5 wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip
  mkdir -p /tmp/cmdtools
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
  mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"
  mv /tmp/cmdtools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"
fi

export PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"
yes | sdkmanager --licenses || true

retry 3 10 sdkmanager "platform-tools" \
                     "platforms;android-${ANDROID_API}" \
                     "build-tools;${ANDROID_BUILD_TOOLS}" \
                     "ndk;${ANDROID_NDK_VERSION}"

NDK_DIR="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}"
[ -d "${NDK_DIR}" ] || (echo "NDK missing at ${NDK_DIR}" >&2; ls -la "${ANDROID_SDK_ROOT}/ndk/"; exit 1)
echo "Using NDK at ${NDK_DIR}"

# -------- Build libtun2socks.so using go-tun2socks --------
rm -rf core tun2socks-android || true
mkdir -p core
cd core

go mod init example.com/tun2socks-wrapper
# Pin to a known stable release
retry 3 5 go get github.com/eycorsican/go-tun2socks@v1.16.6
go mod tidy

cat > main.go <<'EOF'
package main
/*
#include <stdlib.h>
*/
import "C"

import (
    "fmt"
    "net"
    "strings"
    "time"

    t2s "github.com/eycorsican/go-tun2socks/core"
    lwip "github.com/eycorsican/go-tun2socks/core/lwip"
    socks "github.com/eycorsican/go-tun2socks/proxy/socks"
)

var started bool

//export tun2socks_start
func tun2socks_start(fd C.int, proxy *C.char) C.int {
    if started {
        return 0
    }
    // Normalize proxy: ensure scheme
    addr := C.GoString(proxy)
    if !strings.Contains(addr, "://") {
        addr = "socks5://" + addr
    }

    // Create SOCKS proxy handlers
    tcpHandler, err := socks.NewTCPHandler(addr, socks.TCPHandlerOptions{
        // Optional timeouts tuned for Android
        ConnectTimeout:  10 * time.Second,
        HandshakeTimeout:10 * time.Second,
    })
    if err != nil {
        return -1
    }
    udpHandler, err := socks.NewUDPHandler(addr, socks.UDPHandlerOptions{})
    if err != nil {
        return -1
    }

    // Build LWIP netstack and wire to fd-based device
    var dev t2s.Device
    dev, err = lwip.NewLWIPStack()
    if err != nil {
        return -1
    }

    // fdbased device from integer fd
    tunFile := &fileFromFD{Fd: int(fd)}
    dev, err = t2s.NewFdbasedDevice(int(fd), 1500)
    if err != nil {
        return -1
    }

    // Start core
    t2s.RegisterTCPConnectionHandler(tcpHandler)
    t2s.RegisterUDPConnectionHandler(udpHandler)

    go dev.Read(t2s.InputPacket)
    t2s.SetDefaultDevice(dev)

    started = true
    return 0
}

//export tun2socks_stop
func tun2socks_stop() C.int {
    if !started {
        return 0
    }
    t2s.Close()
    started = false
    return 0
}

//export tun2socks_info
func tun2socks_info() *C.char {
    return C.CString(fmt.Sprintf("go-tun2socks: started=%v", started))
}

// Minimal file wrapper (placeholder to keep references explicit)
type fileFromFD struct{ Fd int }

func main() {}
EOF

# Cross-compile
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

# NDK build file
cat > tun2socks-android/src/main/cpp/Android.mk <<'EOF'
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE    := tun2socks_jni
LOCAL_SRC_FILES := tun2socks_jni.c
LOCAL_LDLIBS    := -llog -ldl
include $(BUILD_SHARED_LIBRARY)
EOF

# Gradle module
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

# Root Gradle setup (AGP 8.6 + Gradle 8.6)
echo "include ':tun2socks-android'" > settings.gradle
cat > build.gradle <<'EOF'
buildscript {
    repositories { google(); mavenCentral() }
    dependencies { classpath 'com.android.tools.build:gradle:8.6.0' }
}
allprojects { repositories { google(); mavenCentral() } }
EOF

# Wrapper and build
gradle wrapper --gradle-version 8.6
./gradlew :tun2socks-android:assembleRelease --stacktrace --no-daemon
