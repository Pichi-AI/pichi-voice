"""Validate the staged native playback fixture's media and persisted references."""
import hashlib
import json
from pathlib import Path
import struct
import unittest
import wave


FIXTURES = Path(__file__).parent / 'MobileUITests' / 'Fixtures'


class SavedPlaybackFixtureTests(unittest.TestCase):
    def setUp(self):
        self.session = json.loads((FIXTURES / 'SavedPlaybackMeeting.json').read_text())
        self.audio = FIXTURES / 'SavedPlaybackTone.wav'

    def testRetainedCompletedGuestSessionHasOnePlayableTranscriptRange(self):
        session = self.session
        self.assertEqual(session['state'], 'completed')
        self.assertEqual(session['audioStorageMode'], 'retainedFiles')
        self.assertFalse(session['retention'].get('audioDeletedAt'))
        self.assertNotIn('profileOwnership', session)
        self.assertEqual(len(session['audioTracks']), 1)
        self.assertEqual(len(session['transcriptSegments']), 1)
        segment = session['transcriptSegments'][0]
        self.assertEqual(segment['sourceTrackID'], session['audioTracks'][0]['id'])
        self.assertEqual(segment['status'], 'final')
        self.assertTrue(segment['text'].startswith('Synthetic '))
        chunk = session['audioTracks'][0]['chunks'][0]
        self.assertEqual(segment['start'], chunk['presentationStart'])
        self.assertEqual(segment['end'], chunk['presentationEnd'])

    def testMediaBytesMatchPersistedChunkWithoutExternalOrPrivateInputs(self):
        chunk = self.session['audioTracks'][0]['chunks'][0]
        self.assertEqual(chunk['relativeFilePath'], 'tracks/SavedPlaybackTone.wav')
        self.assertEqual(chunk['finalizationState'], 'finalized')
        data = self.audio.read_bytes()
        self.assertEqual(chunk['byteCount'], len(data))
        self.assertEqual(chunk['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(chunk['discontinuities'], [])

    def testNativePCMFormatAndDurationSupportPauseAndNaturalCompletion(self):
        with wave.open(str(self.audio), 'rb') as audio:
            self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate()),
                             (1, 2, 16000))
            self.assertEqual(audio.getcomptype(), 'NONE')
            self.assertEqual(audio.getnframes() / audio.getframerate(), 12)
            pcm = audio.readframes(audio.getnframes())
        samples = struct.unpack('<' + 'h' * (len(pcm) // 2), pcm)
        self.assertGreater(max(samples), 0)
        self.assertLess(min(samples), 0)
        self.assertLessEqual(max(abs(sample) for sample in samples), 32)
        end = self.session['transcriptSegments'][0]['end']
        self.assertEqual(end['value'] / end['timescale'], 12)


if __name__ == '__main__':
    unittest.main()
