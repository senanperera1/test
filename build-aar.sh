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

# Build tun2socks .so (simplified)
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
mkdir -p tun2socks-android/src/main/jniLibs/arm64-v8a
cp core/libtun2socks.so tun2socks-android/src/main/jniLibs/arm64-v8a/

cat > tun2socks-android/src/main/java/com/example/tun2socks/Tun2Socks.java <<'EOF'
package com.example.tun2socks;
public class Tun2Socks {
    static { System.loadLibrary("tun2socks"); }
}
EOF

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
