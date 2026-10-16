#!/usr/bin/env python3
"""Analytic weak-reference scoring oracles. No model, audio or personal text."""
import importlib.util
from pathlib import Path
import sys
import unittest
import tempfile
import json
SPEC=importlib.util.spec_from_file_location('native_weak_score',Path(__file__).with_name('score.py'))
M=importlib.util.module_from_spec(SPEC);sys.modules[SPEC.name]=M;SPEC.loader.exec_module(M)
S=M.S

def unit(name,start,end):
    return {'id':name,'analysisStart':start,'analysisEnd':end,'text':'private marker'}

class WeakScoreTests(unittest.TestCase):
    def setUp(self):
        self.reference=[S('r0',0,5),S('r1',5,10)]
        self.activity=[S('a',0,5),S('b',5,10)]
        self.mapping,_=M.frozen_mapping(self.reference,self.activity)

    def evaluate(self,units,selected):
        return M.evaluate_words(units,selected,['synthetic']*len(units),self.activity,self.reference,self.mapping)

    def test_perfect_assigned_unknown_denominators(self):
        p=self.evaluate([unit('a',2,3),unit('b',7,8),unit('u',3,4)],['a','b',None])['strictWeak']['counts']
        self.assertEqual((p['words'],p['assigned_words'],p['weak_agree_words'],p['unknown_words']),(3,2,2,1))
        self.assertAlmostEqual(p['assigned_coverage'],2/3)
        self.assertEqual(p['weak_selective_disagreement'],0)

    def test_wrong_known_not_hidden_as_unknown(self):
        p=self.evaluate([unit('w',2,3)],['b'])['strictWeak']['counts']
        self.assertEqual(p['weak_disagree_words'],1);self.assertEqual(p['weak_selective_disagreement'],1)

    def test_no_assigned_is_undefined_selective_error(self):
        p=self.evaluate([unit('u',2,3)],[None])['strictWeak']['counts']
        self.assertEqual(p['assigned_coverage'],0);self.assertIsNone(p['weak_selective_disagreement'])

    def test_exact_collar_and_crossed_word_exclusion(self):
        p=self.evaluate([unit('in',3.2,3.8),unit('edge',4.2,4.8),unit('cross',4.9,5.1)],['a','a','b'])
        self.assertEqual(p['strictWeak']['eligible_words'],2);self.assertEqual(p['interior1s']['eligible_words'],1)

    def test_mapping_is_activity_based_and_shared_by_policies(self):
        self.assertEqual(self.mapping,{'a':'r0','b':'r1'})
        p=self.evaluate([unit('wrong',2,3)],['b'])['strictWeak']['counts']
        self.assertEqual(p['weak_agree_words'],0)

    def test_reference_duplication_does_not_change_metrics(self):
        expected=self.evaluate([unit('a',2,3)],['a'])
        self.reference=M.TIMELINE.union_segments(self.reference*2)
        self.assertEqual(self.evaluate([unit('a',2,3)],['a']),expected)

    def test_report_has_no_transcript_text(self):
        report=self.evaluate([unit('wrong',2,3)],['b'])
        self.assertNotIn('private marker',repr(report))

    def test_aggregate_recomputes_counts_not_mean_rates(self):
        small=self.evaluate([unit('a',2,3)],['b'])['strictWeak']['counts']
        big=self.evaluate([unit(str(i),2,3) for i in range(9)],['a']*9)['strictWeak']['counts']
        combined=M.merge_metrics([small,big]);self.assertEqual(combined['weak_selective_disagreement'],.1)

class ExplicitLineageTests(unittest.TestCase):
    def test_historical_hash_accepted_only_for_exact_explicit_derivative(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'original.json';current=root/'derivative.json'
            value={'schemaVersion':2,'nativeProjectionPolicy':{'schemaVersion':1,'threshold':.08},'metadata':{'original':True},
                **{key:[] for key in M.MIGRATION.ARRAY_KEYS}}
            source.write_text(json.dumps(value,indent=2)+'\n')
            data,_=M.MIGRATION.derive(source.read_bytes(),{'schemaVersion':2,'threshold':.08},source,'a'*64)
            current.write_bytes(data)
            self.assertEqual(M.evidence_lineage_hashes(current,json.loads(data)),{M.sha(source),M.sha(current)})
            changed=json.loads(data);changed['units']=[{'tampered':True}];current.write_text(json.dumps(changed))
            with self.assertRaises(ValueError): M.evidence_lineage_hashes(current,changed)

if __name__=='__main__': unittest.main()
