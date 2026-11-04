import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('topic_version_report', ROOT / 'tools/sensitive_topic_version_report.py')
REPORT = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REPORT)


def output(model, spans, rendered, status='ok'):
    return {'model': model, 'status': status, 'output': rendered if status == 'ok' else None,
            'spans': [{'location': x, 'length': n} for x, n in spans], 'warmMilliseconds': [.5] if status == 'ok' else []}


class TopicVersionReportTests(unittest.TestCase):
    def test_wrong_sentence_is_not_a_true_positive_and_errors_are_separate(self):
        text = '🙂 Секрет. Обычный.'
        secret = REPORT.utf16_length(text[:text.index('Секрет.')])
        normal = REPORT.utf16_length(text[:text.index('Обычный.')])
        positive = {'input': {'id': 'p', 'text': text, 'label': 'positive', 'goldMaskSubstrings': ['Секрет.']},
                    'results': [output('old', [(normal, 8)], 'wrong'), output('new', [(secret, 7)], 'right')]}
        error = {'input': {'id': 'e', 'text': 'Секрет.', 'label': 'positive', 'goldMaskSubstrings': ['Секрет.']},
                 'results': [output('old', [], None, 'error'), output('new', [], None, 'error')]}
        negative = {'input': {'id': 'n', 'text': 'Привет.', 'label': 'negative', 'goldMaskSubstrings': []},
                    'results': [output('old', [], 'Привет.'), output('new', [(0, 7)], '[СКРЫТО]')]}
        ambiguous = {'input': {'id': 'a', 'text': 'Не знаю.', 'label': 'ambiguous', 'goldMaskSubstrings': []},
                     'results': [output('old', [(0, 8)], '[СКРЫТО]'), output('new', [], 'Не знаю.')]}
        result = REPORT.summarize([positive, error, negative, ambiguous])
        self.assertEqual((result['old']['tp'], result['old']['fn'], result['old']['errors']), (0, 1, 1))
        self.assertEqual((result['new']['tp'], result['new']['fp'], result['new']['errors']), (1, 1, 1))
        self.assertEqual(result['old']['ambiguousMaskRate'], 1.0)
        self.assertEqual(result['new']['ambiguousMaskRate'], 0.0)
        self.assertEqual(result['new']['fullSensitiveSentenceCoverage'], 1.0)
        self.assertAlmostEqual(result['new']['f1'], 2 / 3)
        self.assertGreater(result['old']['unrelatedUTF16MaskRate'], 0)
        self.assertEqual(REPORT.paired([positive, error, negative, ambiguous])['transitionCounts']['positive']['miss -> full'], 1)

    def test_jury_is_deterministic_balanced_and_does_not_leak_labels(self):
        rows = []
        for topic in REPORT.TOPICS:
            for label, count in [('positive', 6), ('negative', 4), ('ambiguous', 2)]:
                for i in range(count):
                    item = {'id': f'{topic}-{label}-{i}', 'selectedTopicIDs': [topic], 'text': f'Case {i}.',
                            'label': label, 'goldMaskSubstrings': [], 'rationale': 'private annotation',
                            'scenarioFamily': 'private family', 'tags': ['private tag']}
                    rows.append({'input': item, 'results': [output('old', [], item['text']),
                                                            output('new', [], '[СКРЫТО]' if i % 2 else item['text'])]})
        data = {'policyDefinition': 'Hide selected topic sentences.', 'rows': rows}
        blind, mapping = REPORT.jury_export(data)
        self.assertEqual((len(blind['cases']), len(mapping)), (36, 72))
        self.assertEqual((blind, mapping), REPORT.jury_export(data))
        self.assertEqual({x['option'] for x in mapping}, {'A', 'B'})
        self.assertTrue(all(set(case) == {'caseID', 'selectedTopics', 'input', 'options'} for case in blind['cases']))
        self.assertTrue(all(set(option) == {'option', 'status', 'output'} for case in blind['cases'] for option in case['options']))
        self.assertNotIn('private annotation', str(blind))
        self.assertNotIn('private family', str(blind))
        self.assertNotIn('private tag', str(blind))


if __name__ == '__main__':
    unittest.main()
