#!/usr/bin/env python3
"""编译已构建模块的隔离探针，验证两次强退之间的恢复与确认删除。只用合成记录/密钥。"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
products = root / 'collector/.build/out/Products/Debug'
with tempfile.TemporaryDirectory(prefix='ra-outbox-process-') as temporary:
    directory = Path(temporary)
    executable = directory / 'outbox-probe'
    subprocess.run(['xcrun', 'swiftc', '-I', str(products), str(root / 'scripts/outbox-crash-probe.swift'),
                    str(products / 'AudioStore.o'), str(products / 'CollectorCore.o'), '-o', str(executable)], check=True)
    data = directory / 'data'
    for action, expected in [('write', 37), ('ack', 38), ('empty', 0)]:
        result = subprocess.run([str(executable), action, str(data)], check=False)
        if result.returncode != expected:
            raise SystemExit(f'{action}: expected {expected}, got {result.returncode}')
