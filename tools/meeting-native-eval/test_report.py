#!/usr/bin/env python3
"""Synthetic packaging/security checks; no private fixtures or model inference."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location('meeting_report', Path(__file__).with_name('report.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportPackaging(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.attack = '</script><script>fetch("https://example.invalid")</script>\u2028'
        self.audio = self.root/'audio.wav'
        with wave.open(str(self.audio),'wb') as f:
            f.setparams((1,2,16000,0,'NONE','not compressed'))
            f.writeframes(b'\0\0'*16000)
        token = {'label':'0','analysisEpochID':{'trackID':'synthetic-track','ordinal':0,'generation':0}}
        self.evidence = {'audioSHA256':report.digest(self.audio),'sampleCount':16000,'sampleRate':16000,
                         'units':[{'id':'word0','analysisStart':0,'analysisEnd':.5,'text':self.attack,'precision':'word','speaker':{'kind':'unassigned'}}],
                         'activity':[{'start':0,'end':.5,'token':token}],
                         'baselineAssignments':[{'kind':'assigned','token':token}],'metadata':{}}
        ep=self.write('evidence.json',self.evidence)
        rp=self.write('replay.json',{'evidenceSHA256':report.digest(ep),'deterministicRepeatEqual':True,'policy':{'schemaVersion':2},'policyFingerprint':'synthetic-v2',
                                    'resolution':{'decisions':[{'unitID':'word0','selectedToken':token,'rawAssignment':{'kind':'assigned','token':token},'backgroundTokens':[],
                                                               'policyFingerprint':'synthetic-v2','rule':'singleAcousticSupport','relation':'single','candidates':[]}]}})
        ref=self.write('ref.json',{'speaker_labels':{'0':'Synthetic'},'turns':[{'start':0,'end':1,'speaker':0,'text':self.attack}]})
        manifest=self.write('manifest.json',{'clips':[{'clip_id':'synthetic'}],'participant_disjoint':False})
        self.case={'clip_id':'synthetic','meeting_id':'meeting1','split':'development','language_condition':'Russian','weak_speaker_count':1,'duration_seconds':1,
                   'source_start_seconds':0,'source_end_seconds':1,'audio_path':str(self.audio),'audio_sha256':report.digest(self.audio),'native_evidence_path':str(ep),
                   'native_evidence_sha256':report.digest(ep),'weak_reference_path':str(ref),'weak_reference_sha256':report.digest(ref),'core_replay_paths':{'v2':str(rp)},
                   'frozen_native_to_weak_reference_mapping':{'0':'0'},'case_metrics':{}}
        self.index={'cases':[self.case],'aggregate':{},'corpus_manifest_path':str(manifest),'corpus_manifest_sha256':report.digest(manifest)}
        self.index_path=self.write('index.json',self.index)

    def tearDown(self): self.temp.cleanup()
    def write(self,name,value):
        p=self.root/name;p.write_text(json.dumps(value));return p
    def build(self,status='provisional'):
        return report.build(self.index_path,'v2',self.root/'output',status)

    def test_packaging_preserves_native_text_safely(self):
        proof=self.build();page=(self.root/'output/report.html').read_text()
        self.assertEqual(proof['cases'],1)
        self.assertNotIn(self.attack,page)
        self.assertIn('\\u003c/script\\u003e',page)
        self.assertIn("connect-src &#x27;none&#x27;",page)
        embedded=page.split('<script id="report-data" type="application/json">')[1].split('</script>')[0]
        self.assertEqual(json.loads(embedded)['cases'][0]['words'][0]['text'],self.attack)
        self.assertEqual(report.digest(self.root/'output/audio/synthetic.wav'),report.digest(self.audio))
    def test_partial_cannot_be_final(self):
        with self.assertRaisesRegex(ValueError,'20 actual'):self.build('final')
    def test_digest_mismatch_is_not_silently_viewed(self):
        self.case['audio_sha256']='0'*64;self.write('index.json',self.index)
        with self.assertRaisesRegex(ValueError,'Audio SHA'):self.build()
    def test_duplicate_meeting_is_rejected(self):
        self.index['cases']*=2;self.write('index.json',self.index)
        with self.assertRaisesRegex(ValueError,'different recordings'):self.build()
    def test_replay_must_bind_exact_evidence(self):
        p=Path(self.case['core_replay_paths']['v2']);r=json.loads(p.read_text());r['evidenceSHA256']='0'*64;p.write_text(json.dumps(r))
        with self.assertRaisesRegex(ValueError,'Replay/evidence'):self.build()
    def test_nonfinite_or_overflow_times_rejected(self):
        for a,b in [(0,float('nan')),(-1,1),(0,2),(1,1)]:
            with self.assertRaises(ValueError):report.timing(a,b,1)


if __name__=='__main__':unittest.main()
