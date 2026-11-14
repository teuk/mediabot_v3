#!/usr/bin/env python3
"""Assess the fixed MB1302 300-cycle local endurance envelope, not production capacity."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics

CYCLES = 300
WARMUP = 10
RSS_GROWTH_KIB = 16 * 1024
SOURCE_PATHS = (
    't/lib/MB1300SaturationProbe.pm', 't/lib/MB881OutputFixture.pm',
    'Mediabot/Helpers.pm', 'Mediabot/IRC/Sender.pm',
    'Mediabot/IRC/DeferredOutput.pm', 'Mediabot/IRC/Transport.pm',
    'Mediabot/IRC/Timer.pm', 'tools/qualification/saturation.pl',
)


def number(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError('Missing or invalid nonnegative measurement')
    return value


def assess(report, repo):
    result = {'schema': 1, 'status': 'unavailable', 'scope': 'MB1302 local 300-cycle envelope',
              'budgets': {'cycles': CYCLES, 'warmup_cycles': WARMUP,
                          'rss_growth_kib': RSS_GROWTH_KIB, 'min_drain_s': 3.6,
                          'max_pong_s': 2}, 'failures': []}
    failures = result['failures']

    def check(condition, reason):
        if not condition:
            failures.append(reason)

    try:
        if report['schema'] != 1 or report['status'] != 'passed':
            raise ValueError('Input measurement did not pass or has an unsupported schema')
        for name in SOURCE_PATHS:
            path = repo / name
            if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != report['source_sha256'][name]:
                raise ValueError('Source fingerprint mismatch: ' + name)
        totals = report['totals']
        for key, expected in {'attempted': 150, 'accepted': 120, 'delivered': 90,
                              'rejected': 30, 'expired': 30, 'overflow_diagnostics': 30}.items():
            check(number(totals[key]) == expected, 'Burst accounting: ' + key)
        timed = report['timed_recovery']
        samples = timed['samples']
        check(number(timed['cycles']) == CYCLES and len(samples) == CYCLES,
              'Exactly 300 timed cycles required')
        if len(samples) != CYCLES:
            raise ValueError('Incomplete endurance samples')
        connected = timed['resources_connected']
        notifiers = number(connected['notifiers'])
        fds = number(connected['fds'])
        elapsed = 0
        rss = []
        delivered = 0
        for index, sample in enumerate(samples, 1):
            check(number(sample['cycle']) == index, 'Sample order at cycle ' + str(index))
            current = number(sample['elapsed_s'])
            check(current >= elapsed and number(sample['drain_s']) >= 3.6,
                  'Invalid timing at cycle ' + str(index))
            elapsed = current
            check(number(sample['pong_latency_s']) <= 2, 'PONG deadline at cycle ' + str(index))
            count = number(sample['delivered'])
            check(count == 4, 'Delivery accounting at cycle ' + str(index))
            delivered += count
            resource = sample['resources']
            check(number(resource['notifiers']) == notifiers, 'Notifier drift at cycle ' + str(index))
            check(number(resource['fds']) == fds, 'Descriptor drift at cycle ' + str(index))
            rss.append(number(resource['rss_kib']))
        duration = number(timed['elapsed_s'])
        check(duration >= elapsed >= CYCLES * 3.6, 'Insufficient elapsed endurance time')
        check(number(timed['resources_after_cleanup']['notifiers']) ==
              number(timed['resources_before']['notifiers']), 'Final notifier cleanup')
        baseline = statistics.median(rss[:WARMUP])
        growth = max(0, max(rss[WARMUP:]) - baseline)
        check(growth <= RSS_GROWTH_KIB, 'RSS envelope exceeded after warmup')
        result['measurements'] = {'elapsed_s': duration, 'delivered': delivered,
                                  'rss_warmup_median_kib': baseline,
                                  'rss_peak_growth_kib': growth,
                                  'connected_notifiers': notifiers, 'connected_fds': fds}
        result['status'] = 'failed' if failures else 'passed'
    except (KeyError, TypeError, ValueError, OSError, OverflowError) as exc:
        result['error'] = str(exc)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True, help='new assessment JSON')
    args = parser.parse_args()
    # Exclusive creation also refuses a symlink; never replace existing evidence.
    with args.output.open('x') as out:
        try:
            raw = args.report.read_bytes()
            result = assess(json.loads(raw), args.repo)
            result['input_sha256'] = hashlib.sha256(raw).hexdigest()
        except (OSError, ValueError) as exc:
            result = {'schema': 1, 'status': 'unavailable', 'error': str(exc)}
        result['assessor_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        json.dump(result, out, indent=2, allow_nan=False)
        out.write('\n')
    print('[ENDURANCE] ' + result['status'] + ' — ' + str(args.output), flush=True)
    if 'measurements' in result:
        print(json.dumps(result['measurements'], sort_keys=True), flush=True)
    return {'passed': 0, 'failed': 2, 'unavailable': 3}[result['status']]


if __name__ == '__main__':
    raise SystemExit(main())
