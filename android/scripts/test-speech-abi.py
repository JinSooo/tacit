#!/usr/bin/env python3
"""Regression for version-labelled-but-ABI-incompatible official CPU/QNN releases.
Run prepare-speech.sh first. This compares real cached release artifacts, not stubs.
"""
import io
import os
import runpy
from pathlib import Path
import unittest
import zipfile
from speech_abi import check_api

BASE = Path(__file__).resolve().parent.parent
DEFAULT_APK = BASE / ".gradle/speech-artifacts" / runpy.run_path(str(BASE / "scripts/prepare-speech.py"))["APK_NAME"]
APK = Path(os.environ.get("TACIT_SPEECH_ABI_APK", DEFAULT_APK))


def classes(name):
    with zipfile.ZipFile(BASE / "app/libs" / name) as archive:
        return archive.read("classes.jar")


@unittest.skipUnless(APK.is_file(), "upstream APK fixture is absent; JVM AAR checks still run")
class SpeechAbiRegression(unittest.TestCase):
    def test_original_cpu_api_is_rejected_for_all_four_changed_classes(self):
        with self.assertRaises(ValueError) as failure:
            check_api(classes("sherpa-onnx-2.0.1.aar"), APK)
        for name in ("QnnConfig", "OfflineWhisperModelConfig", "OfflineMoonshineModelConfig", "OfflineNemoEncDecCtcModelConfig"):
            self.assertIn(name + "; fields", str(failure.exception))
            self.assertIn(name + "; constructors", str(failure.exception))

    def test_complete_matching_api_passes(self):
        self.assertEqual(37, check_api(classes("sherpa-onnx-2.0.1-qnn-arm64.aar"), APK))

    def test_single_class_replacement_still_fails(self):
        original = classes("sherpa-onnx-2.0.1.aar")
        matching = classes("sherpa-onnx-2.0.1-qnn-arm64.aar")
        result = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(original)) as old, zipfile.ZipFile(io.BytesIO(matching)) as new, zipfile.ZipFile(result,"w") as out:
            for name in old.namelist():
                out.writestr(name, new.read(name) if name == "com/k2fsa/sherpa/onnx/QnnConfig.class" else old.read(name))
        with self.assertRaisesRegex(ValueError, "OfflineWhisperModelConfig; constructors"):
            check_api(result.getvalue(), APK)


if __name__ == "__main__":
    unittest.main()
