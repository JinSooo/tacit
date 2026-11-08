"""使用合成文本和向量核对统计，绝不读取日记。"""
import itertools
from pathlib import Path
import random
import runpy
import unittest

report = runpy.run_path(str(Path(__file__).with_name('diary-report.py')))


def slow_distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(current[-1] + 1, row[j] + 1, row[j-1] + (x != y)))
        row = current
    return row[-1]


class StatisticsTests(unittest.TestCase):
    def test_normalization(self):
        self.assertEqual(report['normalize']('你好， 世界！\nＡa 12。'), '你好世界Ａa12')

    def test_edit_distance(self):
        rng = random.Random(7)
        examples = [('', ''), ('中文', ''), ('', '中文'), ('今天晴天', '今天阴天'), ('甲'*100, '甲'*99+'乙')]
        examples += [(''.join(rng.choices('甲乙丙丁', k=rng.randrange(70))),
                      ''.join(rng.choices('甲乙丙丁', k=rng.randrange(70)))) for _ in range(500)]
        for a, b in examples:
            self.assertEqual(report['distance'](a, b), slow_distance(a, b))

    def test_cosine(self):
        self.assertAlmostEqual(report['cosine']([1, 0], [3, 0]), 1)
        self.assertAlmostEqual(report['cosine']([1, 0], [0, 1]), 0)
        for a, b in [([0, 0], [1, 0]), ([1], [1, 0]), ([float('nan')], [1])]:
            with self.assertRaises(ValueError):
                report['cosine'](a, b)

    def test_sampling(self):
        groups = [list(range(0, 20)), list(range(20, 40)), list(range(40, 60))]
        pairs, count = report['sample_pairs'](groups)
        self.assertEqual(count, 1200)
        self.assertEqual(len(pairs), 200)
        self.assertEqual(len(set(pairs)), 200)
        self.assertTrue(all(a//20 != b//20 for a, b in pairs))
        self.assertEqual((pairs, count), report['sample_pairs'](groups))
        self.assertEqual(report['sample_pairs']([[1], [2], [3]])[0], list(itertools.combinations([1, 2, 3], 2)))


if __name__ == '__main__':
    unittest.main()
