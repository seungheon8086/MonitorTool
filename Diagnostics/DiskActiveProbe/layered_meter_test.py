#!/usr/bin/env python3
"""LayeredMeter(Sources/BusyMeter.swift)를 그대로 옮겨, BusyMeter 셋(디스크 I/O만 · +캐시 비우기 · +TRIM)과
모든 값이 같은지 무작위로 시험한다. 같은 열쇠로 다시 시작·짝 없는 끝·잃은 이벤트·기한 초과가 섞인다.
BusyMeter 셋은 busy_meter_test.py에서 따로 검산했으므로(합집합 길이), 여기서는 같음만 보면 된다.
실행: python3 layered_meter_test.py"""
import random
import pathlib

src = pathlib.Path(__file__).with_name('busy_meter_test.py').read_text()
ns = {}
exec(src.split('def check(')[0], ns)
BusyMeter, union_length = ns['BusyMeter'], ns['union_length']

LEVELS = 3
FLUSH_KEY = 1 << 63
TRIM_KEY = 1 << 62


class LayeredMeter:
    def __init__(self):
        self.ids = []                 # 자리 → 디스크
        self.slots = {}               # 디스크 → 자리
        self.in_flight = []           # 자리 × 층
        self.busy_since = []
        self.accumulated = []
        self.completed = []
        self.bytes = []
        self.io = {}                  # 열쇠 → (자리, 시작, 바이트)
        self.commands = {}            # 열쇠 → (자리, 시작, 층)
        self.unmatched_done = 0
        self.replaced_start = 0
        self.dropped = 0
        self.loss_count = 0

    def slot(self, disk):
        if disk in self.slots:
            return self.slots[disk]
        s = len(self.ids)
        self.ids.append(disk)
        self.slots[disk] = s
        self.in_flight += [0, 0, 0]
        self.busy_since += [0, 0, 0]
        self.accumulated += [0, 0, 0]
        self.completed.append(0)
        self.bytes.append(0)
        return s

    def _acquire(self, s, level, t):
        for m in range(level, LEVELS):
            i = s * LEVELS + m
            if self.in_flight[i] == 0:
                self.busy_since[i] = t
            self.in_flight[i] += 1

    def _release(self, s, level, t):
        for m in range(level, LEVELS):
            i = s * LEVELS + m
            if self.in_flight[i] == 0:
                continue
            self.in_flight[i] -= 1
            if self.in_flight[i] == 0 and t > self.busy_since[i]:
                self.accumulated[i] += t - self.busy_since[i]

    def start_io(self, key, s, nbytes, t):
        old = self.io.get(key)
        self.io[key] = (s, t, nbytes)          # updateValue: 새 값을 넣고 옛 값을 돌려받음
        if old is not None:
            self.replaced_start += 1
            self._release(old[0], 0, t)
        self._acquire(s, 0, t)

    def done_io(self, key, t):
        p = self.io.pop(key, None)
        if p is None:
            self.unmatched_done += 1
            return
        self._release(p[0], 0, t)
        self.completed[p[0]] += 1
        self.bytes[p[0]] += p[2]

    def start_command(self, key, s, level, t):
        old = self.commands.get(key)
        self.commands[key] = (s, t, level)
        if old is not None:
            self._release(old[0], old[2], t)
        self._acquire(s, level, t)

    def done_command(self, key, t):
        p = self.commands.pop(key, None)
        if p is None:
            return
        self._release(p[0], p[2], t)

    def lose(self, t):
        self.loss_count += 1
        self.dropped += len(self.io)
        self.io.clear()
        self.commands.clear()
        for i in range(len(self.in_flight)):
            if self.in_flight[i] > 0:
                if t > self.busy_since[i]:
                    self.accumulated[i] += t - self.busy_since[i]
                self.in_flight[i] = 0

    def expire(self, limit, t):
        for key, (s, st, nb) in [(k, v) for k, v in self.io.items() if t > v[1] and t - v[1] > limit]:
            del self.io[key]
            self.dropped += 1
            self._release(s, 0, t)
        for key, (s, st, level) in [(k, v) for k, v in self.commands.items() if t > v[1] and t - v[1] > limit]:
            del self.commands[key]
            self._release(s, level, t)

    def busy_ns(self, s, m, t):
        i = s * LEVELS + m
        extra = t - self.busy_since[i] if self.in_flight[i] > 0 and t > self.busy_since[i] else 0
        return self.accumulated[i] + extra


class Old:
    """Engine이 4단계 전까지 쓰던 BusyMeter 셋"""
    def __init__(self):
        self.m = [BusyMeter(), BusyMeter(), BusyMeter()]

    def start(self, key, disk, nbytes, level, t):
        for m in self.m[level:]:
            m.start(key, disk, nbytes, t)

    def done(self, key, level, t):
        for m in self.m[level:]:
            m.done(key, t)

    def snapshot(self, t):
        disks = set(self.m[0].disks) | set(self.m[2].disks)
        return {d: (self.m[0].busy_ns(d, t), self.m[1].busy_ns(d, t), self.m[2].busy_ns(d, t),
                    self.m[0].disks[d]['completed'] if d in self.m[0].disks else 0,
                    self.m[0].disks[d]['bytes'] if d in self.m[0].disks else 0) for d in disks}


def new_snapshot(lm, t):
    return {d: (lm.busy_ns(s, 0, t), lm.busy_ns(s, 1, t), lm.busy_ns(s, 2, t), lm.completed[s], lm.bytes[s])
            for s, d in enumerate(lm.ids)}


random.seed(23)
trials, compared = 2000, 0
for trial in range(trials):
    old, new = Old(), LayeredMeter()
    t = 0
    open_io = []                      # 끝을 아직 안 넣은 디스크 I/O 열쇠
    for step in range(random.randint(1, 300)):
        t += random.choice([0, 0, 1, 2, 5, 40, 300])
        r = random.random()
        if r < 0.36:
            key = random.randint(0, random.choice([5, 50, 10_000]))     # 작은 풀이면 같은 열쇠 다시 시작이 잦다
            disk = random.choice(['A', 'A', 'B', 0])
            nb = random.randint(0, 1 << 20)
            old.start(key, disk, nb, 0, t)
            new.start_io(key, new.slot(disk), nb, t)
            open_io.append(key)
        elif r < 0.70:
            key = open_io.pop(random.randrange(len(open_io))) if open_io and random.random() < 0.9 \
                else random.randint(0, 10_000)                              # 가끔 짝 없는 끝
            old.done(key, 0, t)
            new.done_io(key, t)
        elif r < 0.84:
            level = random.choice([1, 2])
            key = (FLUSH_KEY if level == 1 else TRIM_KEY) | random.randint(0, 3)
            if random.random() < 0.55:
                old.start(key, 'A', 0, level, t)
                new.start_command(key, new.slot('A'), level, t)
            else:
                old.done(key, level, t)
                new.done_command(key, t)
        elif r < 0.86:
            for m in old.m:
                m.lose(t)
            new.lose(t)
            open_io.clear()
        else:
            # 표본: 기한 초과를 같은 기준으로 지운 뒤 비교
            limit = random.choice([10, 200, 30_000])
            for m in old.m:
                m.expire(limit, t)
            new.expire(limit, t)
            a, b = old.snapshot(t), new_snapshot(new, t)
            if a != b:
                raise SystemExit(f'실패: 시험 {trial} 단계 {step} 시각 {t}: BusyMeter 셋 {a} != LayeredMeter {b}')
            m0 = old.m[0]
            got = (new.unmatched_done, new.replaced_start, new.dropped, new.loss_count)
            want = (m0.unmatched_done, m0.replaced_start, m0.dropped, m0.loss_count)
            if got != want:
                raise SystemExit(f'실패: 시험 {trial} 단계 {step}: 셈 {got} != {want}')
            compared += 1
    a, b = old.snapshot(t + 1), new_snapshot(new, t + 1)
    if a != b:
        raise SystemExit(f'실패: 시험 {trial} 끝: {a} != {b}')
    compared += 1

# 겹치는 층의 합집합 길이도 직접 본다 (디스크 I/O ⊂ +캐시 비우기 ⊂ +TRIM)
random.seed(5)
for trial in range(300):
    lm = LayeredMeter()
    io_iv, fl_iv, tr_iv, events = [], [], [], []
    for key in range(random.randint(1, 80)):
        a = random.randint(0, 10_000); b = a + random.randint(1, 900)      # 길이 0이면 같은 시각의 끝이 시작보다 앞에 놓여 시험이 틀어진다
        io_iv.append((a, b)); events += [(a, 1, 0, key), (b, 0, 0, key)]
    for th in range(3):
        cur = random.randint(0, 2000)
        while cur < 9000:
            a = cur + random.randint(0, 700); b = a + random.randint(1, 400)
            level = random.choice([1, 2])
            (fl_iv if level == 1 else tr_iv).append((a, b))
            key = (FLUSH_KEY if level == 1 else TRIM_KEY) | th
            events += [(a, 1, level, key), (b, 0, level, key)]
            cur = b + 1
    events.sort()                                  # 같은 시각이면 끝(0)을 먼저
    marks = sorted(random.sample(range(0, 11_000), 5))
    snaps, i, s = [], 0, lm.slot('A')
    for mark in marks:
        while i < len(events) and events[i][0] <= mark:
            et, start, kind, key = events[i]
            if kind == 0:
                lm.start_io(key, s, 1, et) if start else lm.done_io(key, et)
            else:
                lm.start_command(key, s, kind, et) if start else lm.done_command(key, et)
            i += 1
        snaps.append((mark, [lm.busy_ns(s, m, mark) for m in range(3)]))
    for (t0, b0), (t1, b1) in zip(snaps, snaps[1:]):
        want = [union_length(io_iv, t0, t1), union_length(io_iv + fl_iv, t0, t1), union_length(io_iv + fl_iv + tr_iv, t0, t1)]
        got = [y - x for x, y in zip(b0, b1)]
        if got != want:
            raise SystemExit(f'실패: 합집합 시험 {trial} 구간 {t0}~{t1}: {got} != {want}')

print(f'통과: LayeredMeter = BusyMeter 셋 ({trials}회, 비교 {compared}번: 다시 시작·짝 없는 끝·잃음·기한 초과 섞음)')
print('통과: LayeredMeter 층별 합집합 길이 300회 (디스크 I/O만 · +캐시 비우기 · +TRIM)')
