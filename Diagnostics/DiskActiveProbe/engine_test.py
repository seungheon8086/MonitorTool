#!/usr/bin/env python3
"""Engine.process(Sources/Engine.swift)의 표본 시각 처리 규칙을 옮겨 시험한다.
이벤트는 0.1초마다 읽히고(읽는 순간까지 찍힌 것), 처리는 읽은 시각 - 20 ms까지, 표본 시각은 1초마다 잠에서 깬 시각.
각 표본 구간의 바쁜 시간 = 그 구간으로 자른 요청 구간들의 합집합 길이인지 본다.
실행: python3 engine_test.py"""
import random
import importlib.util, pathlib

spec = importlib.util.spec_from_file_location('bm', pathlib.Path(__file__).with_name('busy_meter_test.py'))
src = pathlib.Path(__file__).with_name('busy_meter_test.py').read_text()
# busy_meter_test.py의 BusyMeter·union_length만 가져온다 (시험 본문은 돌리지 않음)
ns = {}
exec(src.split('def check(')[0], ns)
BusyMeter, union_length = ns['BusyMeter'], ns['union_length']


class Engine:
    def __init__(self):
        self.meter = BusyMeter()
        self.pending = []      # (time, kind, key, disk) 시각 순
        self.ticks = []

    def add_tick(self, t):
        self.ticks.append(t)

    def append(self, batch):
        if batch and self.pending and batch[0][0] < self.pending[-1][0]:
            self.pending = sorted(self.pending + batch, key=lambda e: e[0])
        else:
            self.pending += batch

    def snapshot(self, t):
        return {d: self.meter.busy_ns(d, t) for d in 'AB'}

    def process(self, cutoff):
        out, used = [], 0
        for e in self.pending:
            if e[0] > cutoff:
                break
            while self.ticks and self.ticks[0] < e[0]:
                t = self.ticks.pop(0)
                out.append((t, self.snapshot(t)))
            t, kind, key, disk = e
            if kind == 0:
                self.meter.start(key, disk, 1, t)
            else:
                self.meter.done(key, t)
            used += 1
        self.pending = self.pending[used:]
        while self.ticks and self.ticks[0] <= cutoff:
            t = self.ticks.pop(0)
            out.append((t, self.snapshot(t)))
        return out


MS = 1_000_000
random.seed(11)
for trial in range(200):
    events, intervals = [], {'A': [], 'B': []}
    key = 0
    for _ in range(random.randint(5, 400)):
        disk = random.choice('AB')
        a = random.randint(0, 9_000 * MS)
        b = a + random.randint(0, random.choice([1, 5, 50, 900, 2500]) * MS)
        intervals[disk].append((a, b))
        events.append((a, 0, key, disk))
        events.append((b, 1, key, disk))
        key += 1
    events.sort(key=lambda e: (e[0], e[1]))
    eng = Engine()
    snaps = []
    now, next_tick, k, read_upto = 0, 0, 0, -1
    while now <= 12_000 * MS:
        if now >= next_tick:
            eng.add_tick(now)
            k += 1
            next_tick = k * 1000 * MS
        batch = [e for e in events if read_upto < e[0] <= now]
        read_upto = now
        eng.append(batch)
        snaps += eng.process(now - 20 * MS)
        now += random.randint(80, 120) * MS      # 0.1초 안팎으로 깬다
    snaps += eng.process(1 << 64)
    times = [t for t, _ in snaps]
    assert times == sorted(times), '표본 시각 순서'
    for (t0, s0), (t1, s1) in zip(snaps, snaps[1:]):
        for d in 'AB':
            want = union_length(intervals[d], t0, t1)
            got = s1[d] - s0[d]
            if got != want:
                raise SystemExit(f'실패: 시험 {trial} 구간 {t0}~{t1} 디스크 {d}: {got} != {want}')
print('통과: 엔진 표본 처리 200회 (0.1초 읽기·20 ms 늦춰 처리·1초 표본, 구간별 바쁜 시간 = 합집합 길이)')
