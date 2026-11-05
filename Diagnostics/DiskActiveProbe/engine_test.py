#!/usr/bin/env python3
"""Engine.process(Sources/Engine.swift)의 표본 시각 처리와 바쁜 시간 세 가지를 옮겨 시험한다.
이벤트는 0.1초마다 읽히고(읽는 순간까지 찍힌 것), 처리는 읽은 시각 - 20 ms까지, 표본 시각은 1초마다 잠에서 깬 시각.
4단계 가볍게 하기: 계산기는 LayeredMeter 하나(layered_meter_test.py), 읽은 이벤트는 대기열에 바로 붙이고
앞선 시각의 이벤트가 늦게 오면(이벤트의 3%를 15 ms까지 늦게 보냄) 뒤쪽만 다시 줄 세운다. 그 결과가 통째 정렬과 같은지도 본다.
바쁜 시간 세 가지 (Engine.handle과 같은 규칙):
  디스크 I/O만 = 디스크 I/O 구간의 합집합
  + 캐시 비우기 = 디스크 I/O ∪ 캐시 비우기 구간 (캐시 비우기는 내장 SSD 'A'에만, 스레드마다 하나씩)
  + TRIM = 디스크 I/O ∪ 캐시 비우기 ∪ TRIM 구간
각 표본 구간의 값이 그 구간으로 자른 합집합 길이인지 본다.
실행: python3 engine_test.py"""
import random
import pathlib

src = pathlib.Path(__file__).with_name('busy_meter_test.py').read_text()
# busy_meter_test.py의 BusyMeter·union_length만 가져온다 (시험 본문은 돌리지 않음)
ns = {}
exec(src.split('def check(')[0], ns)
BusyMeter, union_length = ns['BusyMeter'], ns['union_length']
# layered_meter_test.py의 LayeredMeter만 가져온다
lsrc = pathlib.Path(__file__).with_name('layered_meter_test.py').read_text()
lns = {'random': random, 'pathlib': pathlib, '__file__': __file__}
exec(lsrc.split('class Old:')[0], lns)
LayeredMeter = lns['LayeredMeter']

FLUSH_KEY = 1 << 63
TRIM_KEY = 1 << 62
SSD = 'A'                 # 내장 SSD


class Engine:
    def __init__(self):
        self.meter = LayeredMeter()       # 계산기 0 디스크 I/O만 · 1 + 캐시 비우기 · 2 + TRIM
        self.pending = []                 # (time, kind, phase, key, disk) 시각 순. phase 0 시작, 1 끝
        self.ticks = []
        self.reorders = 0

    def add_tick(self, t):
        self.ticks.append(t)

    def append(self, batch):
        """Engine.read + reorder: 바로 붙이고, 순서가 섞였으면 oldest보다 늦은 첫 자리부터만 안정 정렬"""
        expected = sorted(self.pending + batch, key=lambda e: e[0])     # 통째 안정 정렬 (4단계 전의 방식)
        start = len(self.pending)
        last = self.pending[-1][0] if self.pending else 0
        in_order, oldest = True, None
        for e in batch:
            if e[0] < last:
                in_order = False
            else:
                last = e[0]
            if oldest is None or e[0] < oldest:
                oldest = e[0]
            self.pending.append(e)
        if not in_order:
            self.reorders += 1
            lo, hi = 0, start
            while lo < hi:
                mid = (lo + hi) // 2
                if self.pending[mid][0] <= oldest:
                    lo = mid + 1
                else:
                    hi = mid
            tail = sorted(enumerate(self.pending[lo:]), key=lambda x: (x[1][0], x[0]))
            self.pending[lo:] = [e for _, e in tail]
        assert self.pending == expected, '뒤쪽만 다시 줄 세운 결과 = 통째 정렬'

    def snapshot(self, t):
        return {d: tuple(self.meter.busy_ns(s, m, t) for m in range(3)) for s, d in enumerate(self.meter.ids)}

    def handle(self, e):
        t, kind, phase, key, disk = e
        if kind == 'io':
            if phase == 0:
                self.meter.start_io(key, self.meter.slot(disk), 1, t)
            else:
                self.meter.done_io(key, t)
            return
        level, key = (1, FLUSH_KEY | key) if kind == 'flush' else (2, TRIM_KEY | key)
        if phase == 0:
            self.meter.start_command(key, self.meter.slot(SSD), level, t)
        else:
            self.meter.done_command(key, t)

    def process(self, cutoff):
        out, used = [], 0
        for e in self.pending:
            if e[0] > cutoff:
                break
            while self.ticks and self.ticks[0] < e[0]:
                t = self.ticks.pop(0)
                out.append((t, self.snapshot(t)))
            self.handle(e)
            used += 1
        self.pending = self.pending[used:]
        while self.ticks and self.ticks[0] <= cutoff:
            t = self.ticks.pop(0)
            out.append((t, self.snapshot(t)))
        return out


def spans_per_thread(count, threads, longest):
    """스레드마다 겹치지 않는 구간들 (캐시 비우기·TRIM은 한 스레드가 한 번에 하나)"""
    out = []
    for th in range(threads):
        t = random.randint(0, 2_000 * MS)
        for _ in range(count):
            a = t + random.randint(0, 700 * MS)
            b = a + random.randint(0, longest)
            out.append((th, a, b))
            t = b + 1
            if t > 9_000 * MS:
                break
    return out


MS = 1_000_000
random.seed(11)
reorder_total = 0
for trial in range(300):
    events = []
    io = {'A': [], 'B': []}
    flush, trim = [], []
    key = 0
    for _ in range(random.randint(5, 400)):
        disk = random.choice('AB')
        a = random.randint(0, 9_000 * MS)
        b = a + random.randint(0, random.choice([1, 5, 50, 900, 2500]) * MS)
        io[disk].append((a, b))
        events.append((a, 'io', 0, key, disk))
        events.append((b, 'io', 1, key, disk))
        key += 1
    for th, a, b in spans_per_thread(random.randint(0, 30), random.randint(1, 4), random.choice([1, 20, 800]) * MS):
        flush.append((a, b))
        events.append((a, 'flush', 0, th, SSD))
        events.append((b, 'flush', 1, th, SSD))
    for th, a, b in spans_per_thread(random.randint(0, 20), random.randint(1, 2), random.choice([1, 5, 300]) * MS):
        trim.append((a, b))
        events.append((a, 'trim', 0, th, SSD))
        events.append((b, 'trim', 1, th, SSD))
    # 같은 시각이면 끝을 먼저 (커널 이벤트 순서와 상관없이 합집합 길이는 같다)
    events.sort(key=lambda e: (e[0], -e[2]))
    # 이벤트의 3%는 15 ms까지 늦게 읽힌다 (다른 CPU의 버퍼에 남아 있던 것처럼). 처리는 20 ms 늦으므로 순서는 맞아야 한다
    delivered = sorted(((e[0] + (random.randint(0, 15 * MS) if random.random() < 0.03 else 0), i, e)
                        for i, e in enumerate(events)), key=lambda x: (x[0], x[1]))
    eng = Engine()
    snaps = []
    now, next_tick, k, read_upto = 0, 0, 0, -1
    while now <= 12_000 * MS:
        if now >= next_tick:
            eng.add_tick(now)
            k += 1
            next_tick = k * 1000 * MS
        batch = [e for d, _, e in delivered if read_upto < d <= now]
        read_upto = now
        eng.append(batch)
        snaps += eng.process(now - 20 * MS)
        now += random.randint(80, 120) * MS      # 0.1초 안팎으로 깬다
    snaps += eng.process(1 << 64)
    times = [t for t, _ in snaps]
    assert times == sorted(times), '표본 시각 순서'
    for (t0, s0), (t1, s1) in zip(snaps, snaps[1:]):
        for d in 'AB':
            want = (union_length(io[d], t0, t1),
                    union_length(io[d] + (flush if d == SSD else []), t0, t1),
                    union_length(io[d] + (flush + trim if d == SSD else []), t0, t1))
            g0, g1 = s0.get(d, (0, 0, 0)), s1.get(d, (0, 0, 0))
            got = tuple(b - a for a, b in zip(g0, g1))
            if got != want:
                raise SystemExit(f'실패: 시험 {trial} 구간 {t0}~{t1} 디스크 {d}: {got} != {want}')
    reorder_total += eng.reorders
print('통과: 엔진 표본 처리 300회 (0.1초 읽기·20 ms 늦춰 처리·1초 표본, 디스크 I/O만·+캐시 비우기·+TRIM이 각각 합집합 길이)')
print(f'통과: 늦게 온 이벤트로 뒤쪽만 다시 줄 세우기 {reorder_total}번 = 통째 정렬과 같음')
