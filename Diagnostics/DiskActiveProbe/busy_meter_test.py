#!/usr/bin/env python3
"""BusyMeter(Sources/BusyMeter.swift)의 규칙을 그대로 옮겨 경우별로 시험한다.
실행: python3 busy_meter_test.py"""
import random


class BusyMeter:
    def __init__(self):
        self.disks = {}      # 디스크 → 상태
        self.pending = {}    # 짝 열쇠(인자 1) → (디스크, 시작, 바이트)
        self.unmatched_done = 0
        self.replaced_start = 0
        self.dropped = 0
        self.loss_count = 0

    def _state(self, disk):
        return self.disks.setdefault(disk, dict(in_flight=0, busy_since=0, busy_ns=0, completed=0, bytes=0))

    def _release(self, disk, t):
        d = self.disks.get(disk)
        if d is None or d['in_flight'] == 0:
            return
        d['in_flight'] -= 1
        if d['in_flight'] == 0 and t > d['busy_since']:
            d['busy_ns'] += t - d['busy_since']

    def start(self, key, disk, nbytes, t):
        old = self.pending.pop(key, None)
        if old is not None:
            self.replaced_start += 1
            self._release(old[0], t)
        d = self._state(disk)
        if d['in_flight'] == 0:
            d['busy_since'] = t
        d['in_flight'] += 1
        self.pending[key] = (disk, t, nbytes)

    def done(self, key, t):
        p = self.pending.pop(key, None)
        if p is None:
            self.unmatched_done += 1
            return None
        disk, st, nbytes = p
        self._release(disk, t)
        d = self.disks[disk]
        d['completed'] += 1
        d['bytes'] += nbytes
        return disk, (t - st if t > st else 0)

    def lose(self, t):
        self.loss_count += 1
        self.dropped += len(self.pending)
        self.pending.clear()
        for d in self.disks.values():
            if d['in_flight'] > 0:
                if t > d['busy_since']:
                    d['busy_ns'] += t - d['busy_since']
                d['in_flight'] = 0

    def expire(self, limit, t):
        old = [k for k, (disk, st, nb) in self.pending.items() if t > st and t - st > limit]
        for k in old:
            disk, st, nb = self.pending.pop(k)
            self.dropped += 1
            self._release(disk, t)

    def busy_ns(self, disk, t):
        d = self.disks.get(disk)
        if d is None:
            return 0
        extra = t - d['busy_since'] if d['in_flight'] > 0 and t > d['busy_since'] else 0
        return d['busy_ns'] + extra


def union_length(intervals, lo, hi):
    """[lo, hi]로 자른 구간들의 합집합 길이 (검산용)"""
    cut = sorted((max(a, lo), min(b, hi)) for a, b in intervals if min(b, hi) > max(a, lo))
    total, cur_a, cur_b = 0, None, None
    for a, b in cut:
        if cur_b is None or a > cur_b:
            if cur_b is not None:
                total += cur_b - cur_a
            cur_a, cur_b = a, b
        else:
            cur_b = max(cur_b, b)
    if cur_b is not None:
        total += cur_b - cur_a
    return total


def check(name, got, want):
    if got != want:
        raise SystemExit(f'실패: {name}: {got} != {want}')
    print(f'통과: {name}')


m = BusyMeter(); m.start(1, 'A', 4096, 0); m.done(1, 10)
check('하나', m.busy_ns('A', 10), 10)

m = BusyMeter(); m.start(1, 'A', 1, 0); m.start(2, 'A', 1, 5); m.done(1, 10); m.done(2, 15)
check('겹친 둘 = 합집합', m.busy_ns('A', 15), 15)

m = BusyMeter(); m.start(1, 'A', 1, 0); m.done(1, 10); m.start(2, 'A', 1, 20); m.done(2, 25)
check('떨어진 둘', m.busy_ns('A', 30), 15)

m = BusyMeter(); m.start(1, 'A', 1, 0); m.start(2, 'B', 1, 5); m.done(1, 10); m.done(2, 15)
check('디스크 둘은 따로 A', m.busy_ns('A', 20), 10)
check('디스크 둘은 따로 B', m.busy_ns('B', 20), 10)

m = BusyMeter(); m.start(1, 'A', 1, 0)
check('진행 중 구간 포함', m.busy_ns('A', 7), 7)
m.done(1, 10)
check('끝난 뒤', m.busy_ns('A', 12), 10)

m = BusyMeter(); r = m.done(9, 3)
check('시작 못 본 끝은 세기만', (r, m.unmatched_done, m.busy_ns('A', 3)), (None, 1, 0))

m = BusyMeter(); m.start(1, 'A', 1, 0); m.start(1, 'A', 1, 5); m.done(1, 9)
check('같은 열쇠로 다시 시작 = 앞 요청을 그때 닫음', (m.busy_ns('A', 9), m.replaced_start), (9, 1))

m = BusyMeter(); m.start(1, 'A', 1, 0); m.start(2, 'A', 1, 2); m.lose(6)
check('잃은 이벤트 = 걸린 요청 버리고 그 시각에 닫음', (m.busy_ns('A', 6), m.dropped, m.loss_count), (6, 2, 1))
m.done(1, 8)
check('잃은 뒤 온 끝은 짝 없음', (m.unmatched_done, m.busy_ns('A', 8)), (1, 6))

m = BusyMeter(); m.start(1, 'A', 1, 0); m.expire(100, 50)
check('기한 안이면 그대로', (m.dropped, m.busy_ns('A', 50)), (0, 50))
m.expire(100, 150)
check('기한 넘으면 버리고 그 시각에 닫음', (m.dropped, m.busy_ns('A', 200)), (1, 150))

m = BusyMeter(); m.start(1, 'A', 1, 10); m.done(1, 5)
check('시각이 거꾸로면 음수 대신 0', m.busy_ns('A', 5), 0)

m = BusyMeter(); m.start(1, 'A', 100, 0); m.start(2, 'A', 50, 1); m.done(2, 3); m.done(1, 4)
check('작업 수·바이트', (m.disks['A']['completed'], m.disks['A']['bytes']), (2, 150))

# 무작위 검산: 디스크 둘, 겹치는 요청 수천 개, 구간마다 BusyMeter 차이 = 합집합 길이
random.seed(7)
for trial in range(300):
    events, intervals = [], {'A': [], 'B': []}
    for key in range(random.randint(1, 60)):
        disk = random.choice('AB')
        a = random.randint(0, 10_000)
        b = a + random.randint(0, 800)
        intervals[disk].append((a, b))
        events.append((a, 0, key, disk))   # 같은 시각이면 끝(1)보다 시작(0)을 먼저
        events.append((b, 1, key, disk))
    events.sort()
    marks = sorted(random.sample(range(0, 11_000), 6))
    m, snaps, i = BusyMeter(), [], 0
    for t, kind, key, disk in events:
        while i < len(marks) and marks[i] <= t:
            snaps.append({d: m.busy_ns(d, marks[i]) for d in 'AB'})
            i += 1
        if kind == 0:
            m.start(key, disk, 1, t)
        else:
            m.done(key, t)
    while i < len(marks):
        snaps.append({d: m.busy_ns(d, marks[i]) for d in 'AB'})
        i += 1
    for j in range(len(marks) - 1):
        for d in 'AB':
            want = union_length(intervals[d], marks[j], marks[j + 1])
            got = snaps[j + 1][d] - snaps[j][d]
            if got != want:
                raise SystemExit(f'실패: 무작위 {trial} 구간 {j} 디스크 {d}: {got} != {want}')
print('통과: 무작위 검산 300회 (구간별 차이 = 합집합 길이)')
