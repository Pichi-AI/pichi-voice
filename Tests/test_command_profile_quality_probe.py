"""Offline synthetic frame checks only; never connect to a model or run commands."""

import copy
import json
from pathlib import Path
import runpy
import unittest


PROBE = runpy.run_path(str(Path(__file__).with_name('probe_command_profile_quality.py')))
MODEL = 'synthetic-model:fixture'


class CommandProfileQualityProbeTests(unittest.TestCase):
    def setUp(self):
        self.frames = [
            {'model': MODEL, 'message': {'content': 'Ёж'}, 'done': False},
            {'model': MODEL, 'message': {'content': 'ик ✅'}, 'done': False},
            {'model': MODEL, 'message': {'content': ''}, 'done': True, 'done_reason': 'stop'},
        ]

    def evaluate(self, frames, expected='Ёжик ✅'):
        raw = b'\n'.join(json.dumps(frame, ensure_ascii=False).encode() for frame in frames)
        return PROBE['evaluate'](raw, expected, MODEL)

    def test_all_frames_match_requested_model(self):
        result = self.evaluate(self.frames)
        self.assertTrue(result['passed'])
        self.assertEqual(result['content'], 'Ёжик ✅')
        self.assertFalse(result['tools_executed'])

    def test_missing_or_wrong_model_on_each_frame_is_rejected(self):
        for index in range(len(self.frames)):
            for replacement in (None, 'different-model:fixture'):
                with self.subTest(frame=index, model=replacement):
                    frames = copy.deepcopy(self.frames)
                    if replacement is None:
                        frames[index].pop('model')
                    else:
                        frames[index]['model'] = replacement
                    with self.assertRaisesRegex(ValueError, 'Missing or mismatched model'):
                        self.evaluate(frames)

    def test_whole_stream_from_wrong_or_missing_model_is_rejected(self):
        for replacement in (None, 'different-model:fixture'):
            with self.subTest(model=replacement):
                frames = copy.deepcopy(self.frames)
                for frame in frames:
                    if replacement is None:
                        frame.pop('model')
                    else:
                        frame['model'] = replacement
                with self.assertRaisesRegex(ValueError, 'Missing or mismatched model'):
                    self.evaluate(frames)

    def test_matching_model_does_not_bypass_stream_validation(self):
        invalid_streams = [
            self.frames[:-1],
            [self.frames[-1], self.frames[-1]],
            [dict(self.frames[-1], done_reason='length')],
            [dict(self.frames[-1], error='synthetic failure')],
        ]
        for frames in invalid_streams:
            with self.subTest(frames=frames):
                with self.assertRaisesRegex(ValueError, 'Incomplete/error native stream'):
                    self.evaluate(frames)
        for raw in (b'', b'not json', b' ' * 131_073):
            with self.subTest(raw_length=len(raw)):
                with self.assertRaises((ValueError, json.JSONDecodeError)):
                    PROBE['evaluate'](raw, '4', MODEL)

    def test_tool_contract_still_requires_matching_model(self):
        frames = [{'model': MODEL, 'message': {'content': '', 'tool_calls': [{
            'function': {'name': 'execute_terminal_command', 'arguments': {
                'command': PROBE['PRINT_COMMAND'], 'purpose': 'executing - synthetic stdout',
            }},
        }]}, 'done': True, 'done_reason': 'stop'}]
        self.assertTrue(self.evaluate(frames, expected=None)['passed'])
        frames[0]['model'] = 'different-model:fixture'
        with self.assertRaisesRegex(ValueError, 'Missing or mismatched model'):
            self.evaluate(frames, expected=None)


if __name__ == '__main__':
    unittest.main()
