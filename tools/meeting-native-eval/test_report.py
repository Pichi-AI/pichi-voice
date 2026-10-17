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
        self.attack = '</script><script>fetch("https://example.invalid")</script>\u2028 @@CSP@@ @@CSS@@ @@DATA@@ @@JS@@'
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
                   'frozen_native_to_weak_reference_mapping':{'0':'0'},'case_metrics':{'variants':{n:{'all_unknown_words':0,'profiles':{p:{'counts':{},'eligible_words':1,'excluded_words':0} for p in ['strictWeak','interior1s','interior2s']}} for n in ['baseline4484','v2']}}}
        manifest=self.write('manifest.json',{'clips':[self.case.copy()],'participant_disjoint':False})
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
        for token in ['@@CSP@@','@@CSS@@','@@DATA@@','@@JS@@']:
            self.assertIn(token, json.loads(embedded)['cases'][0]['reference']['turns'][0]['text'])
        self.assertEqual(report.digest(self.root/'output/audio/synthetic.wav'),report.digest(self.audio))
    def test_all_template_tokens_in_transcript_remain_literal(self):
        self.build()
        page=(self.root/'output/report.html').read_text()
        embedded=page.split('<script id="report-data" type="application/json">')[1].split('</script>')[0]
        data=json.loads(embedded)
        self.assertEqual(data['cases'][0]['words'][0]['text'],self.attack)
        self.assertEqual(data['cases'][0]['reference']['turns'][0]['text'],self.attack)
        self.assertEqual(page.count('<script'),2)

    def test_partial_cannot_be_final(self):
        with self.assertRaisesRegex(ValueError,'20 actual'):self.build('final')
    def test_digest_mismatch_is_not_silently_viewed(self):
        self.case['audio_sha256']='0'*64;self.write('index.json',self.index)
        with self.assertRaisesRegex(ValueError,'frozen corpus mismatch'):self.build()
    def test_duplicate_meeting_is_rejected(self):
        self.index['cases']*=2;self.write('index.json',self.index)
        with self.assertRaisesRegex(ValueError,'Duplicate clip'):self.build()
    def test_replay_must_bind_exact_evidence(self):
        p=Path(self.case['core_replay_paths']['v2']);r=json.loads(p.read_text());r['evidenceSHA256']='0'*64;p.write_text(json.dumps(r))
        with self.assertRaisesRegex(ValueError,'Replay/evidence'):self.build()
    def prepare_source_binding(self):
        binary=self.root/'native-runner';binary.write_bytes(b'synthetic executable bytes')
        core='a'*64
        build={'schema_version':1,'source_revision':'synthetic-revision','binary_sha256':report.digest(binary),
               'sources':{report.CORE_SOURCE_PATH:core}}
        build_path=self.write('build-manifest.json',build)
        ep=Path(self.case['native_evidence_path'])
        self.evidence['metadata']['nativeBuildManifestSHA256']=report.digest(build_path)
        ep.write_text(json.dumps(self.evidence))
        self.case['native_evidence_sha256']=report.digest(ep)
        rp=Path(self.case['core_replay_paths']['v2'])
        replay=json.loads(rp.read_text());replay['evidenceSHA256']=report.digest(ep);rp.write_text(json.dumps(replay))
        record={'clip_id':'synthetic','meeting_id':'meeting1','split':'development',
                'evidence_path':str(ep),'evidence_sha256':report.digest(ep),
                'result_path':str(rp),'result_sha256':report.digest(rp),'native_inference_seconds_this_pass':.1,
                'policy_fingerprint':'synthetic-v2'}
        run=self.write('run-manifest.json',{'status':'complete','corpus_manifest_sha256':self.index['corpus_manifest_sha256'],
                                          'build_manifest':build,'cases':[record]})
        self.case['native_evidence_build_manifest_path']=str(build_path)
        self.case['native_evidence_build_manifest_sha256']=report.digest(build_path)
        self.case['core_replay_provenance']={'v2':{'result_sha256':report.digest(rp),'build_manifest_path':str(build_path),
            'build_manifest_sha256':report.digest(build_path),'build_source_revision':'synthetic-revision','core_source_sha256':core,
            'native_runner_binary_path':str(binary),'native_runner_binary_sha256':report.digest(binary),
            'run_manifest_path':str(run),'run_manifest_sha256':report.digest(run),'execution_mode':'actual-native-fresh'}}
        self.index.update(native_source_commit='synthetic-revision',core_source_sha256=core)
        self.write('index.json',self.index)

    def test_verified_source_binding(self):
        self.prepare_source_binding()
        self.assertTrue(self.build()['source_verified'])

    def test_provisional_missing_binding_does_not_claim_source(self):
        self.index.update(native_source_commit='unverified-claim',core_source_sha256='b'*64)
        self.write('index.json',self.index)
        proof=self.build()
        self.assertFalse(proof['source_verified']);self.assertIsNone(proof['source_commit']);self.assertIsNone(proof['core_sha256'])

    def test_old_core_with_same_policy_fingerprint_rejected(self):
        self.prepare_source_binding()
        provenance=self.case['core_replay_provenance']['v2'];path=Path(provenance['build_manifest_path'])
        build=json.loads(path.read_text());build['sources'][report.CORE_SOURCE_PATH]='b'*64
        path.write_text(json.dumps(build));provenance['build_manifest_sha256']=report.digest(path)
        self.write('index.json',self.index)
        with self.assertRaisesRegex(ValueError,'core source SHA-256'):self.build()

    def test_changed_pinned_replay_bytes_rejected(self):
        self.prepare_source_binding()
        path=Path(self.case['core_replay_paths']['v2']);replay=json.loads(path.read_text());replay['replaySeconds']=99
        path.write_text(json.dumps(replay))
        with self.assertRaisesRegex(ValueError,'replay bytes changed'):self.build()

    def test_changed_run_record_rejected_even_if_manifest_repinned(self):
        self.prepare_source_binding()
        provenance=self.case['core_replay_provenance']['v2'];path=Path(provenance['run_manifest_path'])
        run=json.loads(path.read_text());run['cases'][0]['result_sha256']='c'*64;path.write_text(json.dumps(run))
        provenance['run_manifest_sha256']=report.digest(path);self.write('index.json',self.index)
        with self.assertRaisesRegex(ValueError,'pinned run manifest'):self.build()

    def test_changed_executable_rejected(self):
        self.prepare_source_binding()
        Path(self.case['core_replay_provenance']['v2']['native_runner_binary_path']).write_bytes(b'different build')
        with self.assertRaisesRegex(ValueError,'executable SHA-256'):self.build()

    def test_nonfinite_or_overflow_times_rejected(self):
        for a,b in [(0,float('nan')),(-1,1),(0,2),(1,1)]:
            with self.assertRaises(ValueError):report.timing(a,b,1)


if __name__=='__main__':unittest.main()
