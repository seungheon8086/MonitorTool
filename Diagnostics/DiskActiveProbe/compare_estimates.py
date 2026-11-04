#!/usr/bin/env python3
"""2단계 결론 검산: 권한 없이 만들 수 있는 값이 활성 %를 얼마나 대신하나 (내장 SSD disk0, 1초 표본).
- 어림값: 드라이버 통계의 1초 평균 동시 요청을 100%에서 자른 값 (samples.tsv의 clipped_pct)
- IOReport: ANS2 채널의 1초 증가량. 한 기록에서 일차식을 맞춰 다른 기록에 써 본다 (부하 → 실사용, 실사용 → 부하)
실행: python3 -I compare_estimates.py results/20261104-160555-load results/20261104-162116-record
(IOReport 원본은 ioreport.tsv 또는 ioreport.tsv.gz)"""
import csv
import gzip
import math
import pathlib
import sys
from collections import defaultdict


def opener(path):
    p = pathlib.Path(path)
    if p.exists():
        return open(p, newline='')
    return gzip.open(str(p) + '.gz', 'rt', newline='')


def load(directory):
    with opener(pathlib.Path(directory) / 'samples.tsv') as f:
        rows = [r for r in csv.DictReader(f, delimiter='\t') if r['disk'] == 'disk0']
    seconds = [int(r['second']) for r in rows]
    active = [float(r['active_pct']) for r in rows]
    clipped = [float(r['clipped_pct']) for r in rows]
    raw = defaultdict(dict)
    with opener(pathlib.Path(directory) / 'ioreport.tsv') as f:
        for r in csv.DictReader(f, delimiter='\t'):
            if r['group'] != 'ANS2':
                continue
            key = ' / '.join(x for x in (r['group'], r['subgroup'], r['channel'], r['state']) if x)
            raw[key][int(r['second'])] = float(r['delta'])
    series = {k: [v.get(s, 0.0) for s in seconds] for k, v in raw.items()}
    return active, clipped, series


def pearson(a, b):
    n = len(a)
    ma, mb = sum(a) / n, sum(b) / n
    sa = math.sqrt(sum((x - ma) ** 2 for x in a))
    sb = math.sqrt(sum((y - mb) ** 2 for y in b))
    if sa == 0 or sb == 0:
        return float('nan')
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (sa * sb)


def errors(pred, truth):
    e = sorted(abs(p - t) for p, t in zip(pred, truth))
    return sum(e) / len(e), e[int(len(e) * 0.9)], e[-1]


def fit(x, y):
    n = len(x)
    mx, my = sum(x) / n, sum(y) / n
    sxx = sum((a - mx) ** 2 for a in x)
    k = sum((a - mx) * (b - my) for a, b in zip(x, y)) / sxx
    return k, my - k * mx


sets = {'부하': load(sys.argv[1]), '실사용': load(sys.argv[2])}
for name, (active, clipped, _) in sets.items():
    m, p90, mx = errors(clipped, active)
    print(f'어림값 · {name} ({len(active)}초): r = {pearson(clipped, active):+.3f} · 절대 차이 평균 {m:.1f}%p · 90% {p90:.1f} · 최대 {mx:.1f}')

common = sorted(set(sets['부하'][2]) & set(sets['실사용'][2]))
ranked = []
for key in common:
    r1 = pearson(sets['부하'][2][key], sets['부하'][0])
    r2 = pearson(sets['실사용'][2][key], sets['실사용'][0])
    if not (math.isnan(r1) or math.isnan(r2)):
        ranked.append((min(abs(r1), abs(r2)), key, r1, r2))
ranked.sort(reverse=True)
print('\nIOReport ANS2 증가량과 활성의 상관 (두 기록 모두 큰 순): r(부하) · r(실사용)')
for _, key, r1, r2 in ranked[:8]:
    print(f'  {key}: {r1:+.3f} · {r2:+.3f}')
print('\n한 기록에서 맞춘 일차식(0~100%로 자름)을 다른 기록에 쓸 때: 절대 차이 평균 · 90% · 최대 (%p)')
for _, key, _, _ in ranked[:3]:
    for a, b in (('부하', '실사용'), ('실사용', '부하')):
        k, c = fit(sets[a][2][key], sets[a][0])
        pred = [min(100, max(0, k * v + c)) for v in sets[b][2][key]]
        m, p90, mx = errors(pred, sets[b][0])
        print(f'  {key} · {a} → {b}: {m:.1f} · {p90:.1f} · {mx:.1f}')
