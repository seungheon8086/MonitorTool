#!/usr/bin/env python3
"""TickBook(Sources/Stage3.swift)의 1초 표본 짝 맞추기를 옮겨 시험한다.
hold는 추적을 잡았다 놓았다 한다(비켜주기·밀려남). 1초 경계마다 그때 추적 중인 엔진 번호(gen)를 적고,
엔진은 20 ms 늦게 그 시각의 누적값을 채운다. 해제할 때는 남은 것을 다 채우고, 밀려나면 못 채운 채 버린다.
- 모든 1초(경계 k → k+1)가 한 번씩, 차례대로 나오는가
- 같은 엔진이 앞뒤 경계를 다 채운 1초만 '추적', 나머지는 '추정'인가
- 나중에 채워질 1초를 미리 '추정'으로 내보내지 않는가
실행: python3 hold_test.py"""
import random

MS = 1_000_000


class TickBook:
    def __init__(self):
        self.ticks = []

    def add(self, t):
        self.ticks.append(t)

    def fill(self, gen, time, totals):
        for t in self.ticks:
            if t['gen'] == gen and t['time'] == time and t['totals'] is None:
                t['totals'] = totals
                return

    def ready(self, live):
        def settled(t):
            return t['gen'] is None or t['totals'] is not None or t['gen'] != live
        out = []
        while len(self.ticks) >= 2 and settled(self.ticks[0]) and settled(self.ticks[1]):
            out.append((self.ticks[0], self.ticks[1]))
            self.ticks.pop(0)
        return out


def traced(a, b):
    return a['gen'] is not None and a['gen'] == b['gen'] and a['totals'] is not None and b['totals'] is not None


random.seed(7)
LIMIT = 40
for trial in range(2000):
    # 추적을 잡고 놓는 때: (잡을 수 있는 때, 놓는 때, 'release' 해제 | 'lose' 밀려남)
    plan, t = [], random.randint(0, 3000) * MS
    while t < LIMIT * 1000 * MS:
        length = random.choice([50, 300, 900, 2500, 7000, 20000]) * MS
        plan.append((t, t + length, random.choice(['release', 'lose'])))
        t += length + random.choice([0, 100, 1000, 4000]) * MS
    book = TickBook()
    emitted = []
    filled = {}                     # (gen, time) → 채웠는지 (끝난 뒤 정답 확인용)
    engine, gen, engine_ticks, step = None, 0, [], 0
    now, next_tick, k = 0, 0, 0
    while True:
        if now >= next_tick:
            g = gen if engine is not None else None
            book.add(dict(k=k, time=now, gen=g, totals=None))
            if engine is not None:
                engine_ticks.append(now)
            if k >= LIMIT:
                break
            k += 1
            next_tick = k * 1000 * MS
        # 놓기 (Holder.yieldNow·lose와 같은 차례: 해제면 남은 경계를 다 채운다)
        if engine is not None and now >= plan[step][1]:
            if plan[step][2] == 'release':
                for tt in engine_ticks:
                    book.fill(gen, tt, 'T')
                    filled[(gen, tt)] = True
            engine, engine_ticks = None, []
            step += 1
        # 읽고 처리 (20 ms 늦춤) 또는 잡기
        if engine is not None:
            done = [tt for tt in engine_ticks if tt <= now - 20 * MS]
            for tt in done:
                book.fill(gen, tt, 'T')
                filled[(gen, tt)] = True
            engine_ticks = [tt for tt in engine_ticks if tt > now - 20 * MS]
        elif step < len(plan) and now >= plan[step][0]:
            gen += 1
            engine, engine_ticks = gen, []
        # Swift의 HoldTick은 값이라 내보낸 때의 모습으로 판정한다 (나중에 채워져도 바뀌지 않음)
        emitted += [(a, b, traced(a, b)) for a, b in book.ready(gen if engine is not None else None)]
        now += random.randint(80, 120) * MS
    # 끝: 쥐고 있으면 해제(다 채움)
    if engine is not None:
        for tt in engine_ticks:
            book.fill(gen, tt, 'T')
            filled[(gen, tt)] = True
        engine = None
    emitted += [(a, b, traced(a, b)) for a, b in book.ready(None)]

    ks = [(a['k'], b['k']) for a, b, _ in emitted]
    assert ks == [(i, i + 1) for i in range(LIMIT)], f'시험 {trial}: 1초 차례가 다름 {ks[:5]}…'
    for a, b, was_traced in emitted:
        truth = (a['gen'] is not None and a['gen'] == b['gen']
                 and filled.get((a['gen'], a['time'])) and filled.get((b['gen'], b['time'])))
        if was_traced != bool(truth):
            raise SystemExit(f'실패: 시험 {trial} {a["k"]}→{b["k"]}초: 추적 {was_traced} != 정답 {bool(truth)}')
print('통과: hold 1초 표본 짝 맞추기 2000회 (잡기·해제·밀려남이 섞여도 모든 1초가 한 번씩, 추적·추정 구분이 정답과 같음)')
