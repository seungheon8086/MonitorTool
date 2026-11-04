"""DiskActiveProbe 1단계 원본(events.tsv) 분석: SSD 드라이버 이벤트(DBG_SSD 0x0615)와 디스크 명령(DBG_IOCTL).
실행: python3 -I analyze_ssd.py results/<시각>/events.tsv
- NVMe 명령: 제출 0x0615002c, 완료 0x06150028, 인자 1 = 태그, 인자 2 = 큐 (관찰로 정한 뜻)
- 캐시 비우기 0x06154009(시작)·0x0615400a(끝), TRIM 0x0615400d·0x0615400e (관찰로 정한 뜻)
- 디스크 I/O(DBG_DKRW) 바쁜 시간과 NVMe 명령 바쁜 시간을 합집합으로 비교한다"""
import sys, collections

rows = []
with open(sys.argv[1]) as f:
    next(f)
    for line in f:
        t, cpu, did, a1, a2, a3, a4, th = line.rstrip('\n').split('\t')
        rows.append((int(t), int(did, 16), int(a1, 16), int(a2), int(a3), int(a4), int(th)))

def union(intervals):
    total, a0, b0 = 0, None, None
    for a, b in sorted(intervals):
        if b0 is None or a > b0:
            if b0 is not None:
                total += b0 - a0
            a0, b0 = a, b
        else:
            b0 = max(b0, b)
    return total + (b0 - a0 if b0 is not None else 0)

def ms(ns):
    return f'{ns / 1e6:.3f}'

disk_io, starts = [], {}
nvme, submitted = [], {}
spans = {0x06154009: ('캐시 비우기', 0x0615400a), 0x0615400d: ('TRIM', 0x0615400e)}
open_spans, span_len = {}, collections.defaultdict(list)
sync_options = collections.Counter()
trim_ranges, trim_bytes = 0, 0
for t, did, a1, a2, a3, a4, th in rows:
    csc = did >> 16
    if csc == 0x0302:                         # 디스크 I/O: 인자 1로 짝, 인자 2 = 장치 (주번호 1 = 디스크)
        if (did >> 2) & 1 == 0:
            starts[a1] = (t, a2)
        else:
            s = starts.pop(a1, None)
            if s and s[1] >> 24 == 1:
                disk_io.append((s[0], t))
    elif did == 0x0615002c:
        submitted[(a1, a2)] = t
    elif did == 0x06150028:
        s = submitted.pop((a1, a2), None)
        if s is not None:
            nvme.append((s, t))
    elif did in spans:
        open_spans[(did, th)] = t
    elif did in (0x0615400a, 0x0615400e):
        start_id = did - 1
        s = open_spans.pop((start_id, th), None)
        if s is not None:
            span_len[spans[start_id][0]].append(t - s)
    elif did == 0x03060000:                   # 동기화 요청: 인자 2 = 명령, 인자 3 = 옵션
        sync_options[a3] += 1
    elif did == 0x03060004:                   # TRIM 범위: 인자 3 = 바이트
        trim_ranges += 1
        trim_bytes += a3

span = rows[-1][0] - rows[0][0]
lat = sorted(b - a for a, b in nvme)
print(f'구간 {span / 1e9:.2f}초 · 이벤트 {len(rows):,}')
print(f'NVMe 명령 {len(nvme):,} (짝 못 맞춘 제출 {len(submitted)}) · 명령 시간 중앙 {ms(lat[len(lat)//2])} ms · 90% {ms(lat[len(lat)*9//10])} · 최장 {ms(lat[-1])}')
for name, v in span_len.items():
    v.sort()
    print(f'{name} {len(v)}번 · 중앙 {ms(v[len(v)//2])} ms · 최장 {ms(v[-1])} · 합 {ms(sum(v))}')
print(f'동기화 요청 {sum(sync_options.values())}개 (옵션별 {dict(sync_options)}) · TRIM 범위 {trim_ranges}개 {trim_bytes / 1e6:.2f} MB')
print(f'바쁜 시간: 디스크 I/O {ms(union(disk_io))} ms · NVMe 명령 {ms(union(nvme))} ms · 합집합 {ms(union(disk_io + nvme))} ms')
