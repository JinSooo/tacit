#!/usr/bin/env python3
"""Reproducible local AAR: upstream Java API + matching official QNN JNI/runtime.

No Qualcomm binary is committed or published standalone. Third-party terms are
packaged in the application assets. A failed fetch never replaces a valid cache.
"""
import hashlib
import os
import subprocess
import tarfile
from pathlib import Path
import tempfile
import urllib.request
import zipfile

from speech_abi import check_api

BASE = Path(__file__).resolve().parent.parent
VERSION = "2.0.1"
# The published QNN APK reports this SHA through VersionInfo.getGitSha1().
# The v2.0.1 tag's CPU AAR predates these Kotlin/JNI changes despite sharing its version label.
API_REVISION = "935e5ded3d949a8b557ac44ef4dad03a7d2038e7"
API_SHA = "34dac2067eef100802eb748622b458051e52559a6113ff327825ac6ca523e600"
CPU_SHA = "a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7"
APK_NAME = "sherpa-onnx-2.0.1-qnn-arm64-v8a-simulated_streaming_asr-zh-30-seconds-zipformer_ctc_2025_07_03_int8.apk"
APK_URL = ("https://huggingface.co/csukuangfj2/sherpa-onnx-apk/resolve/"
           "dc89924cb00d3a284c0eeb231247cd306bcad1fb/qnn-vad-asr-simulated-streaming/2.0.1/" + APK_NAME)
APK_SHA = "0fe68096df4a5013a4bb207a45ba659bc6830846e01c893a46d826445d83e8b9"
# AArch64 host/runtime plus the SM8650 Hexagon v75 DSP skeleton. No graph compiler is needed
# for the existing context binary. VAD and speaker extraction remain available on CPU.
LIBRARIES = {
    "libsherpa-onnx-jni.so": "4d2a3062c75fa0e2b1821d144163cec283f80313574e75bd5d4fb8e72504d722",
    "libonnxruntime.so": "33847ad43bffe204699fd4a27f7f3603452a8cdaf2f9a44983a0bc31ffcf2da1",
    "libQnnHtp.so": "328cf737ca8942c2dde5c6f3e32a113378df2750afb9af1aafdd1775bef59875",
    "libQnnSystem.so": "2d42b6bb2710155fa963ee623ce3c320f8a9896b9cfd8dcc25506affb41ab8ab",
    "libQnnHtpV75Stub.so": "29071105df405c8af5c41b9b7a56412ac5eeab859214264be19cddb2681d2705",
    "libQnnHtpV75Skel.so": "747707fca10308a018465e5d1590c4ec41ab3388ca8a6649eceb1f5e0be4a29b",
}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def fetch(path, url, size, sha):
    if path.is_file() and path.stat().st_size == size and digest(path) == sha:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    tmp = Path(name)
    try:
        with os.fdopen(fd, "wb") as output, urllib.request.urlopen(url, timeout=45) as response:
            if not response.url.startswith("https://"):
                raise ValueError("HTTPS required")
            count = 0
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                count += len(block)
                if count > size:
                    raise ValueError("Artifact exceeds pinned size")
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        if count != size or digest(tmp) != sha:
            raise ValueError("Artifact size/SHA-256 mismatch: " + path.name)
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def matched_api():
    root = BASE / ".gradle/speech-api"
    root.mkdir(parents=True, exist_ok=True)
    source = root / "source.tar.gz"
    fetch(source, "https://codeload.github.com/k2-fsa/sherpa-onnx/tar.gz/" + API_REVISION,
          11959481, API_SHA)
    prefix = f"sherpa-onnx-{API_REVISION}/sherpa-onnx/kotlin-api/"
    sources = root / "src/main/kotlin"
    sources.mkdir(parents=True, exist_ok=True)
    def write(path, data):
        if not path.exists() or path.read_bytes() != data:
            path.write_bytes(data)
    names = set()
    with tarfile.open(source) as archive:
        for item in archive:
            if item.name.startswith(prefix):
                name = item.name[len(prefix):]
                if "/" not in name and name.endswith(".kt") and item.isfile():
                    names.add(name)
                    write(sources / name, archive.extractfile(item).read())
    if len(names) != 23:
        raise ValueError("Pinned Kotlin API source set is incomplete")
    for old in sources.glob("*.kt"):
        if old.name not in names:
            old.unlink()
    write(root / "settings.gradle.kts", b'pluginManagement { repositories { gradlePluginPortal(); mavenCentral() } }\nrootProject.name = "sherpa-qnn-api"\n')
    write(root / "build.gradle.kts", b'''plugins { kotlin("jvm") version "2.1.20" }
repositories { mavenCentral() }
dependencies { compileOnly(files(providers.gradleProperty("androidJar").get())) }
kotlin { jvmToolchain(17) }
tasks.jar {
    archiveFileName.set("classes.jar")
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}
''')
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    properties = BASE / "local.properties"
    if properties.exists():
        for line in properties.read_text().splitlines():
            if line.startswith("sdk.dir="):
                sdk = line.split("=", 1)[1].replace("\\:", ":").replace("\\ ", " ").replace("\\\\", "\\")
    if not sdk:
        raise ValueError("Set sdk.dir in android/local.properties or ANDROID_HOME")
    android_jar = Path(sdk) / "platforms/android-35/android.jar"
    if not android_jar.is_file():
        raise ValueError("Android SDK 35 is required to compile the paired speech API")
    subprocess.run([str(BASE / "gradlew"), "-p", str(root), "jar", "--offline", "--console=plain",
                    "-PandroidJar=" + str(android_jar)], check=True)
    return (root / "build/libs/classes.jar").read_bytes()


def prepare():
    libs = BASE / "app/libs"
    libs.mkdir(parents=True, exist_ok=True)
    cpu = libs / f"sherpa-onnx-{VERSION}.aar"
    apk = BASE / ".gradle/speech-artifacts" / APK_NAME
    fetch(cpu, f"https://github.com/k2-fsa/sherpa-onnx/releases/download/v{VERSION}/{cpu.name}",
          49441341, CPU_SHA)
    fetch(apk, APK_URL, 113018665, APK_SHA)
    classes = matched_api()
    count = check_api(classes, apk)
    print(f"Verified {count} APK API classes: instance fields, Kotlin constructors and native methods")
    output = libs / f"sherpa-onnx-{VERSION}-qnn-arm64.aar"
    entries = {}
    with zipfile.ZipFile(cpu) as original, zipfile.ZipFile(apk) as demo:
        for info in original.infolist():
            if not info.is_dir() and not info.filename.startswith("jni/"):
                entries[info.filename] = original.read(info)
        # Replace the ENTIRE API, including callers of Kotlin default/mask constructors.
        entries["classes.jar"] = classes
        for name, sha in LIBRARIES.items():
            blob = demo.read("lib/arm64-v8a/" + name)
            if hashlib.sha256(blob).hexdigest() != sha:
                raise ValueError("Native library checksum mismatch: " + name)
            entries["jni/arm64-v8a/" + name] = blob
        # The app's existing VAD/speaker code can share this exact ORT; no pickFirst or binary patch.
        if original.read("jni/arm64-v8a/libonnxruntime.so") != entries["jni/arm64-v8a/libonnxruntime.so"]:
            raise ValueError("ORT mismatch: do not mix native runtimes")
    fd, name = tempfile.mkstemp(prefix=output.name + ".", dir=libs)
    os.close(fd)
    stage = Path(name)
    try:
        with zipfile.ZipFile(stage, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, data in sorted(entries.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data)
        if not output.exists() or digest(stage) != digest(output):
            stage.replace(output)
        print("Verified QNN AAR:", output, digest(output))
    finally:
        stage.unlink(missing_ok=True)


if __name__ == "__main__":
    prepare()
