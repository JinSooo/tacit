#!/usr/bin/env python3
"""Pin actual AndroidJUnitRunner failure/assumption behavior: adb exit 0 is insufficient."""
import runpy
from pathlib import Path
import unittest

results = runpy.run_path(str(Path(__file__).with_name('verify-device.py')))['results']


def outcome(test, code, stack='', total=1):
    return (f'INSTRUMENTATION_STATUS: class=top.jinso.tacit.audio.QnnDeviceTest\n'
            f'INSTRUMENTATION_STATUS: test={test}\nINSTRUMENTATION_STATUS: numtests={total}\n'
            f'INSTRUMENTATION_STATUS: stack={stack}\nINSTRUMENTATION_STATUS_CODE: {code}\n')


class RunnerRegression(unittest.TestCase):
    def test_native_failure_is_rejected_even_when_runner_exits_normally(self):
        text = outcome('unsupportedSocKeepsCpuSpeechWorking', -2,
                       'java.lang.RuntimeException: Failed to get field ID for htpPerfMode') + 'INSTRUMENTATION_CODE: -1\n'
        self.assertTrue(results(text)[2])
        self.assertEqual((1, 0, []), results(outcome('working', 0) + 'INSTRUMENTATION_CODE: -1\n'))

    def test_missing_models_are_not_a_pass(self):
        text = outcome('unsupportedSocKeepsCpuSpeechWorking', -4,
                       'org.junit.AssumptionViolatedException: Stage the approved CPU models first') + 'INSTRUMENTATION_CODE: -1\n'
        self.assertTrue(results(text)[2])

    def test_hardware_skip_is_explicit_and_counted(self):
        text = outcome('sm8650ActuallyExecutesHtpAndRecognizesTailBeyondThirtySeconds', -4,
                       'org.junit.AssumptionViolatedException: HTP evidence requires the exact SM8650 phone') + 'INSTRUMENTATION_CODE: -1\n'
        self.assertEqual((0, 1, []), results(text))

    def test_crash_or_truncated_run_fails(self):
        self.assertTrue(results(outcome('working', 0, total=2) + 'INSTRUMENTATION_CODE: -1\n')[2])
        self.assertTrue(results('INSTRUMENTATION_RESULT: shortMsg=Process crashed.\nINSTRUMENTATION_CODE: 0\n')[2])


if __name__ == '__main__':
    unittest.main()
