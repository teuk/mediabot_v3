"""Run the offline probe against installed Perl dependencies, without IRC access."""
import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / 'tools/dev/irc-keepalive-probe.pl'


class KeepaliveProbeTests(unittest.TestCase):
    def test_native_and_mediabot_receipts(self):
        for options, transport in (([], 'Net::Async::IRC'),
                                   (['--mediabot'], 'Mediabot::IRC::Transport')):
            with self.subTest(transport=transport):
                result = subprocess.run(['perl', '-I.', str(PROBE), *options],
                                        cwd=ROOT, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stderr, '')
                data = json.loads(result.stdout)
                self.assertEqual(data['transport'], transport)
                self.assertEqual(data['blocked_peer'], {
                    'ping_flush_complete_at_timeout': 0,
                    'payload_flush_complete_at_timeout': 0,
                    'ping_visible_at_timeout': 0,
                    'recovered_payload_frames': 256,
                    'recovered_write_receipts': 1,
                })
                self.assertEqual(data['responsive_peer'], {
                    'pings': 1, 'pong_received': 1, 'timeout_count': 0,
                })

    def test_invalid_arguments_are_refused(self):
        result = subprocess.run(['perl', '-I.', str(PROBE), 'unexpected'],
                                cwd=ROOT, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stderr)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
