#!/usr/bin/env python3
"""Offline derivative custody tests with synthetic JSON only, no model/runtime needed."""
from pathlib import Path
import importlib.util
import json
import sys
import unittest
SPEC=importlib.util.spec_from_file_location('offline_migration',Path(__file__).with_name('migrate_replay_v2.py'))
M=importlib.util.module_from_spec(SPEC);sys.modules[SPEC.name]=M;SPEC.loader.exec_module(M)

class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.policy={'schemaVersion':1,'threshold':.08,'enabled':True}
        self.new={**self.policy,'schemaVersion':2}
        self.source={'schemaVersion':2,'nativeProjectionPolicy':self.policy,'metadata':{'source':'original'},
            'units':[{'id':'x','text':'Синтетика: \\" } { Ёж','analysisStart':0.1,'analysisEnd':.3,'speaker':{'kind':'unassigned'}}],
            'activity':[{'token':{'label':'a'},'start':.1,'end':.3}],
            'baselineCoverageAssignments':[{'kind':'assigned'}],
            'baselineAssignments':[{'kind':'assigned'}],
            'initialAcousticAssignments':[{'kind':'assigned'}]}
        self.data=(json.dumps(self.source,ensure_ascii=False,indent=4)+'\n').encode()

    def derive(self): return M.derive(self.data,self.new,Path('/synthetic/source.json'),'a'*64)

    def test_only_explicit_policy_and_provenance_change(self):
        result,provenance=self.derive();value=json.loads(result)
        self.assertEqual(value['nativeProjectionPolicy']['schemaVersion'],2)
        self.assertEqual(value['offlineReplayMigration']['originalNativeProjectionPolicy'],self.policy)
        self.assertEqual(value['metadata'],self.source['metadata'])
        self.assertEqual(provenance['originalEvidenceSHA256'],M.sha(self.data))

    def test_all_native_arrays_byte_exact_with_quotes_braces_cyrillic(self):
        result,_=self.derive();before=self.data.decode();after=result.decode()
        original=M.top_level_spans(before);derivative=M.top_level_spans(after)
        for key in M.ARRAY_KEYS:
            self.assertEqual(before[slice(*original[key])].encode(),after[slice(*derivative[key])].encode())

    def test_numerical_policy_tuning_rejected(self):
        self.new['threshold']=.04
        with self.assertRaisesRegex(ValueError,'Numerical policy changed'): self.derive()

    def test_wrong_historical_or_future_version_rejected(self):
        self.new['schemaVersion']=3
        with self.assertRaisesRegex(ValueError,'only evidence2'): self.derive()

    def test_duplicate_top_level_key_rejected(self):
        with self.assertRaisesRegex(ValueError,'Duplicate'): M.top_level_spans('{"a":1,"a":2}')

    def test_migration_chaining_rejected(self):
        result,_=self.derive()
        with self.assertRaises(ValueError): M.derive(result,self.new,Path('/synthetic/derivative.json'),'b'*64)

if __name__=='__main__': unittest.main()
