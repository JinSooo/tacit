#!/usr/bin/env python3
"""仅输出文件名、数字和统计，不输出参考文本或转写内容。"""
import argparse
import itertools
import json
import math
from pathlib import Path
import random
import statistics
import sys
import unicodedata


def normalize(text):
    # 只去标点和空白：保留数字、大小写、简繁和符号，不隐式改写参考答案。
    return ''.join(c for c in text if not c.isspace() and not unicodedata.category(c).startswith('P'))


def distance(reference, hypothesis):
    """按 Unicode 字符计算精确编辑距离，位向量避免长日记的二维 DP。"""
    if not reference:
        return len(hypothesis)
    masks = {}
    for i, char in enumerate(reference):
        masks[char] = masks.get(char, 0) | (1 << i)
    positive, negative, score = ~0, 0, len(reference)
    top = 1 << (len(reference) - 1)
    for char in hypothesis:
        equal = masks.get(char, 0)
        vertical = equal | negative
        horizontal = (((equal & positive) + positive) ^ positive) | equal
        plus = negative | ~(horizontal | positive)
        minus = positive & horizontal
        score += bool(plus & top) - bool(minus & top)
        plus = (plus << 1) | 1
        minus <<= 1
        positive = minus | ~(vertical | plus)
        negative = plus & vertical
    return score


def cosine(a, b):
    if not a or len(a) != len(b) or not all(math.isfinite(x) for x in a + b):
        raise ValueError('声纹维度或数值无效')
    denominator = math.sqrt(sum(x*x for x in a) * sum(x*x for x in b))
    if denominator == 0:
        raise ValueError('声纹范数为零')
    return max(-1.0, min(1.0, sum(x*y for x, y in zip(a, b)) / denominator))


def distribution(values):
    if not values:
        raise ValueError('相似度样本为空')
    return f'{len(values)} | {min(values):.4f} | {statistics.median(values):.4f} | {max(values):.4f}'


def sample_pairs(groups, limit=200, seed=20261109):
    # 只比较不同日记的段，排除同一录音环境造成的偏高；对全部合格段对等概率抽样。
    rng = random.Random(seed)
    reservoir, seen = [], 0
    for a, b in itertools.combinations(groups, 2):
        for left in a:
            for right in b:
                seen += 1
                if len(reservoir) < limit:
                    reservoir.append((left, right))
                else:
                    i = rng.randrange(seen)
                    if i < limit:
                        reservoir[i] = (left, right)
    return reservoir, seen


def report(directory):
    wavs = sorted(directory.glob('*.wav'))
    if len(wavs) < 2:
        raise ValueError('至少需要两个日记 WAV')
    rows, diaries = [], []
    for wav in wavs:
        ref = normalize(wav.with_suffix('.apple.txt').read_text(encoding='utf-8'))
        hyp = normalize(wav.with_suffix('.sv.txt').read_text(encoding='utf-8'))
        if not ref:
            raise ValueError('参考文本去标点及空白后为空')
        data = json.loads(wav.with_suffix('.emb.json').read_text(encoding='utf-8'))
        if data['model'] != 'int8' or data['num_threads'] != 4 or not data['segments']:
            raise ValueError('日记模型配置或语音段无效')
        metrics = data['metrics']
        if metrics['audio_seconds'] <= 0 or metrics['processing_seconds'] < 0:
            raise ValueError('音频计时无效')
        rows.append((wav.name, len(ref), len(hyp), distance(ref, hyp), metrics))
        diaries.append(data)
    vendor_data = json.loads((directory / 'vendor-embeddings.json').read_text(encoding='utf-8'))
    vendors = vendor_data['files']
    if vendor_data['model'] != 'int8' or vendor_data['num_threads'] != 4 or len(vendors) != 5:
        raise ValueError('vendor 配置或样本数无效')
    same = [cosine(a['mean_embedding'], b['mean_embedding']) for a, b in itertools.combinations(diaries, 2)]
    pairs, population = sample_pairs([[s['embedding'] for s in d['segments']] for d in diaries])
    same_segments = [cosine(a, b) for a, b in pairs]
    different = [cosine(a['mean_embedding'], b['mean_embedding']) for a in diaries for b in vendors]
    different_segments = [cosine(s['embedding'], v['embedding'])
                          for d in diaries for s in d['segments'] for b in vendors for v in b['segments']]
    total_ref = sum(row[1] for row in rows)
    total_error = sum(row[3] for row in rows)
    audio = sum(row[4]['audio_seconds'] for row in rows)
    elapsed = sum(row[4]['processing_seconds'] for row in rows)
    print('## 2-C 真实语音日记\n')
    print('配置：int8，4 线程，16,000 Hz，512 维；VAD 最长 20 秒。')
    print('CER 仅去掉 Unicode 标点和空白，按字编辑距离 / Apple 参考字数；整体按参考字数加权。')
    print('Apple 为自动转写，未经人工标注；此处是相对差异率，不能视为真实识别错误率。\n')
    print('| 文件 | 参考字数 | 转写字数 | 编辑距离 | CER | 音频 s | 处理 s | RTF | VAD 段数 |')
    print('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for name, nr, nh, error, m in rows:
        print(f'| {name} | {nr} | {nh} | {error} | {error/nr:.2%} | {m["audio_seconds"]:.3f} | {m["processing_seconds"]:.3f} | {m["processing_seconds"]/m["audio_seconds"]:.4f} | {m["vad_segments"]} |')
    print(f'| 整体 | {total_ref} | {sum(r[2] for r in rows)} | {total_error} | {total_error/total_ref:.2%} | {audio:.3f} | {elapsed:.3f} | {elapsed/audio:.4f} | {sum(r[4]["vad_segments"] for r in rows)} |\n')
    print(f'RTF 包含读入、VAD、逐段转写和声纹，不含模型加载 {vendor_data["load_seconds"]:.3f} 秒、结果序列化和 vendor 推理。单进程顺序执行，每个文件测 1 次。\n')
    print('| 声纹比较 | 对数 | 最小 | 中位 | 最大 |')
    print('|---|---:|---:|---:|---:|')
    for label, values in [('同人：日记平均向量', same), ('同人：跨日记段向量抽样', same_segments),
                          ('异人代理：日记 / vendor 平均向量', different), ('异人代理：日记 / vendor 段向量', different_segments)]:
        print(f'| {label} | {distribution(values)} |')
    print(f'\n段对抽样：总体 {population} 对，无放回最多 200 对，固定种子 20261109。段向量先 L2 归一化，等权平均后再次归一化。')
    for label, positives, negatives in [('平均向量', same, different), ('段向量', same_segments, different_segments)]:
        low, high = max(negatives), min(positives)
        if low < high:
            threshold = (low + high) / 2
            print(f'{label}候选阈值：{threshold:.4f}（≥ 判同人）；样本间隔 ({low:.4f}, {high:.4f})，观测假接受 0/{len(negatives)}，假拒绝 0/{len(positives)}。')
        else:
            print(f'{label}无完全分离阈值：异人最大 {low:.4f} ≥ 同人最小 {high:.4f}，重叠 {low-high:.4f}；不建议据此设生产阈值。')
    print('\n样本局限：同人仅 1 人、10 段日记；异人仅 5 个 vendor 文件，身份未人工核验，语言与录音条件存在混杂。段对及文件对非独立样本，阈值在同一批数据上选择，无留出验证；不能外推多人、噪声、设备变化或生产误判率。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    # 先完整生成再打印，缺文件或无效数据时不留下部分报告。
    import contextlib
    import io
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output):
            report(args.directory)
    except (OSError, ValueError, KeyError, TypeError):
        print('分析失败：输入文件缺失、格式或数值无效；未输出文本内容。', file=sys.stderr)
        return 1
    print(output.getvalue(), end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
