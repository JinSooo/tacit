#!/usr/bin/env python3
"""Run Android tests with install -r; never uninstall or clear the user's application."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

BASE = Path(__file__).resolve().parents[1]
# These tests deliberately target mutually exclusive hardware. Missing model/fixture skips fail.
HARDWARE_SKIPS = {
    'qnnProcessDeathFallsBackToCpuWithoutLosingSpeech': 'HTP evidence requires the exact SM8650 phone',
    'sm8650ActuallyExecutesHtpAndRecognizesTailBeyondThirtySeconds': 'HTP evidence requires the exact SM8650 phone',
    'unsupportedSocKeepsCpuSpeechWorking': 'This check is for a non-SM8650 device',
}


def results(output):
    current = {}
    outcomes = []
    total = None
    for line in output.splitlines():
        if line.startswith('INSTRUMENTATION_STATUS: '):
            key, separator, value = line.removeprefix('INSTRUMENTATION_STATUS: ').partition('=')
            if separator:
                current[key] = value
                if key == 'numtests':
                    total = int(value)
        elif line.startswith('INSTRUMENTATION_STATUS_CODE: '):
            code = int(line.rsplit(': ', 1)[1])
            if code != 1:
                outcomes.append((code, current))
            current = {}
    errors = []
    passed = sum(code == 0 for code, _ in outcomes)
    skipped = 0
    for code, data in outcomes:
        if code == 0:
            continue
        expected = HARDWARE_SKIPS.get(data.get('test'))
        if code == -4 and expected and data.get('stack', '').endswith(': ' + expected):
            skipped += 1
        else:
            errors.append(f"{data.get('class', '?')}#{data.get('test', '?')}: status {code}; {data.get('stack', 'not completed')}")
    if not total or len(outcomes) != total or not re.search(r'^INSTRUMENTATION_CODE: -1\s*$', output, re.M):
        errors.append('Test runner did not complete every declared test')
    if 'INSTRUMENTATION_FAILED:' in output or 'INSTRUMENTATION_RESULT: shortMsg=' in output:
        errors.append('Test runner failed or crashed')
    return passed, skipped, errors


def adb_path():
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    properties = BASE / 'local.properties'
    if properties.exists():
        for line in properties.read_text().splitlines():
            if line.startswith('sdk.dir='):
                sdk = line.split('=', 1)[1].replace('\\:', ':').replace('\\ ', ' ').replace('\\\\', '\\')
    candidate = Path(sdk) / 'platform-tools/adb' if sdk else None
    if candidate and candidate.is_file():
        return str(candidate)
    found = shutil.which('adb')
    if not found:
        raise RuntimeError('Android platform-tools/adb is required')
    return found


def main():
    adb = adb_path()
    listing = subprocess.check_output([adb, 'devices'], text=True)
    available = [line.split()[0] for line in listing.splitlines()[1:] if len(line.split()) >= 2 and line.split()[1] == 'device']
    serial = os.environ.get('ANDROID_SERIAL')
    if serial:
        if serial not in available:
            raise RuntimeError('ANDROID_SERIAL is not connected and authorized')
    elif len(available) == 1:
        serial = available[0]
    else:
        raise RuntimeError('Connect exactly one device, or select the intended device with ANDROID_SERIAL')
    command = [adb, '-s', serial]
    for relative in ['app/build/outputs/apk/debug/app-debug.apk', 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
        subprocess.run(command + ['install', '-r', str(BASE / relative)], check=True)
    run = subprocess.run(command + ['shell', 'am', 'instrument', '-w', '-r',
                                    'top.jinso.tacit.test/androidx.test.runner.AndroidJUnitRunner'],
                         text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(run.stdout)
    passed, skipped, errors = results(run.stdout)
    if run.returncode:
        errors.append(f'adb exited {run.returncode}')
    print(f'Device tests: {passed} passed; {skipped} hardware-only skips; {len(errors)} errors. Application data retained.')
    if errors:
        raise RuntimeError('\n'.join(errors))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
