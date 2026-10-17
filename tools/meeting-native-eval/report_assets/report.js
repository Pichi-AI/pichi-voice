'use strict';
const ReportMath = (() => {
  const active = (items, t) => items.filter(x => x.start <= t && t < x.end);
  const inferred = rule => ['incomingSpeaker','neighborAgreement','boundaryContinuation','residualSuppression','acousticDominance'].includes(rule);
  const scopedSource = token => JSON.stringify([token.analysisEpochID.trackID, token.analysisEpochID.ordinal, token.analysisEpochID.generation, token.label]);
  const unresolvedCandidates = word => word.selected ? [] : [...new Set((word.decision.candidates || []).map(candidate => scopedSource(candidate.token)))].sort();
  const key = word => JSON.stringify([word.selected, [...word.background].sort(), word.decision.relation, unresolvedCandidates(word), word.decision.rule === 'briefInterruption' ? 'interruption' : inferred(word.decision.rule) ? 'inferred' : 'direct']);
  function groups(words, mode = 'selected') {
    const result = [];
    for (const word of words) {
      const signature = mode === 'selected' ? key(word) : JSON.stringify(word[mode + 'Token'] ?? word[mode]);
      const last = result[result.length - 1];
      // Presentation-only merging. Preserve every original word and its exact time.
      if (last && last.signature === signature && word.start >= last.end && word.start - last.end <= .8) {
        last.end = word.end; last.words.push(word);
      } else result.push({start: word.start, end: word.end, signature, words: [word], token: mode === 'selected' ? word.selected : word.baselineToken});
    }
    return result;
  }
  function sumMetrics(cases, variant, profile) {
    const counts = {words:0, assigned_words:0, weak_agree_words:0, weak_disagree_words:0, eligible_words:0, excluded_words:0, all_native_words:0, all_unknown_words:0};
    for (const c of cases) {
      const v = c.metrics.variants[variant], p = v?.profiles?.[profile];
      if (!p) throw Error(`Missing metric ${variant}/${profile} in ${c.id}`);
      for (const k of ['words','assigned_words','weak_agree_words','weak_disagree_words']) counts[k] += p.counts[k];
      counts.eligible_words += p.eligible_words; counts.excluded_words += p.excluded_words;
      counts.all_native_words += c.words.length; counts.all_unknown_words += v.all_unknown_words;
    }
    return counts;
  }
  function sumTextQuality(profiles) {
    const keys = ['distance','substitutions','deletions','insertions','reference_tokens','char_distance','reference_characters','scored_seconds','native_units_included','native_units_total','eligible_turns','reference_turns_total'];
    const legacyZeroEvents = new Set(['distance','substitutions','deletions','insertions','char_distance']);
    const totals = Object.fromEntries(keys.map(key => [key, 0]));
    for (const profile of profiles) {
      const unscorable = profile.reference_tokens === 0 && profile.weak_wer === null;
      for (const key of keys) {
        const value = profile[key] === undefined && unscorable && legacyZeroEvents.has(key) ? 0 : profile[key];
        if (!Number.isFinite(value) || value < 0) throw Error(`Missing or invalid text-quality count: ${key}`);
        totals[key] += value;
      }
    }
    totals.weak_wer = totals.reference_tokens ? totals.distance / totals.reference_tokens : null;
    totals.weak_cer = totals.reference_characters ? totals.char_distance / totals.reference_characters : null;
    return totals;
  }
  const visible = (x, start, end) => x.start < end && x.end > start;
  return {active, groups, sumMetrics, sumTextQuality, visible};
})();
if (typeof module !== 'undefined') module.exports = ReportMath;
if (typeof document !== 'undefined') (() => {
  const data = JSON.parse(document.getElementById('report-data').textContent);
  const $ = id => document.getElementById(id);
  const node = (tag, text, cls) => { const n=document.createElement(tag); if(text !== undefined)n.textContent=text; if(cls)n.className=cls; return n; };
  const json = value => JSON.stringify(value, null, 2);
  const pct = (n,d) => d ? `${(100*n/d).toFixed(2)}%` : 'не определено';
  const time = t => `${Math.floor(t/60)}:${(t%60).toFixed(2).padStart(5,'0')}`;
  const palette = ['#246399','#8d348e','#147465','#a14b1b','#6350ae','#a62e58','#316c62','#66502c'];
  let current, windowStart=0, selectedID=null, timelineRows=[], transcripts=[], animation=null;
  const audio=$('audio');
  function label(token, short=false) {
    if (!token) return 'Спикер не определен';
    const source=current.tokens[token];
    if (!source) return 'Неизвестный исходный слот';
    const slot=`слот ${source.nativeLabel}`;
    return source.name ? `≈ ${source.name}${short?'':` (${slot})`}` : slot+' без сопоставления';
  }
  function color(token){const keys=Object.keys(current.tokens).sort();return token?palette[Math.max(0,keys.indexOf(token))%palette.length]:'#67758a';}
  function decisionLabel(word) {
    const d=word.decision;
    const name=label(word.selected, true);
    if(d.rule==='briefInterruption') return `${name} (перебивает; фон: ${word.background.map(x=>label(x,true)).join(' + ')})`;
    if(!word.selected && d.candidates.length>1) return `${d.relation==='simultaneous'?'Одновременная речь':'Несколько кандидатов'}: ${d.candidates.map(x=>labelToken(x.token)).join(' + ')}`;
    if(['incomingSpeaker','neighborAgreement','boundaryContinuation','residualSuppression','acousticDominance'].includes(d.rule)) return `Предположительно: ${name}`;
    return name;
  }
  function labelToken(t){return label(`${t.analysisEpochID.trackID}:${t.analysisEpochID.ordinal}:${t.analysisEpochID.generation}:${t.label}`,true);}
  function selectWord(word){selectedID=word.id;$('wordHint').textContent=`${time(word.start)} - ${time(word.end)} · ${word.text}`;$('wordEvidence').textContent=json({исходный_ID:word.id,точность:word.precision,исходное_время:{start:word.start,end:word.end},выбранный_для_показа:word.selected,исходное_поле_ASR:word.asrRaw,акустическое_назначение_до_контекста:word.decision.rawAssignment,историческое_назначение:word.baseline,решение_и_доказательства:word.decision});updatePlayback();}
  function seek(t){audio.currentTime=Math.max(0,Math.min(current.duration,t));if($('follow').checked)ensureWindow(audio.currentTime);drawTimeline();updatePlayback();}
  function ensureWindow(t){const width=Number($('zoom').value);if(t<windowStart||t>=windowStart+width)windowStart=Math.min(Math.max(0,Math.floor(t/width)*width),Math.max(0,current.duration-width));$('window').value=windowStart;}
  function makeSegments(){
    const ref=current.reference.turns.map(t=>({...t,token:Object.keys(current.tokens).find(k=>String(current.tokens[k].weakSlot)===String(t.speaker)),text:current.reference.speaker_labels[String(t.speaker)]+': '+t.text}));
    const tracks=[{name:'Fathom: автоматические реплики',segments:ref,isReference:true}];
    for(const token of Object.keys(current.tokens).sort())tracks.push({name:'fast32: '+label(token,true),segments:current.activity.filter(a=>a.token===token).map(a=>({...a,text:label(token,true)})),activity:true});
    tracks.push({name:'Исторический алгоритм: слова',segments:ReportMath.groups(current.words,'baseline').map(g=>({...g,text:label(g.token,true)+' · '+g.words.map(w=>w.text).join(' ')}))});
    tracks.push({name:'Финальная проекция: крупные реплики',segments:ReportMath.groups(current.words).map(g=>({...g,text:decisionLabel(g.words[0])+' · '+g.words.map(w=>w.text).join(' ')}))});
    return tracks;
  }
  function drawTimeline(){
    const root=$('timeline');root.replaceChildren();timelineRows=[];transcripts=[];
    const width=Math.min(Number($('zoom').value),current.duration),end=windowStart+width;
    $('position').textContent=`${time(windowStart)} - ${time(end)}`;$('window').max=Math.max(0,current.duration-width);$('window').value=windowStart;
    const makeRow=(name,wave=false)=>{const row=node('div',undefined,'timeline-row');row.append(node('div',name,'track-name'));const plot=node('div',undefined,'track-plot'+(wave?' wave':''));row.append(plot);root.append(row);const marker=node('div',undefined,'marker');plot.append(marker);timelineRows.push({plot,marker});plot.addEventListener('click',e=>{if(e.target===plot||e.target.tagName==='CANVAS'){const b=plot.getBoundingClientRect();seek(windowStart+width*(e.clientX-b.left)/b.width);}});return plot;};
    const wavePlot=makeRow('Исходное аудио · '+current.duration+' с',true);const canvas=node('canvas');canvas.width=1500;canvas.height=140;wavePlot.prepend(canvas);const ctx=canvas.getContext('2d');ctx.fillStyle='#3865b0';const peaks=current.waveform;for(let x=0;x<canvas.width;x++){const t=windowStart+width*x/canvas.width,i=Math.min(peaks.length-1,Math.floor(t/current.duration*peaks.length)),v=peaks[i]*63;ctx.fillRect(x,70-v,1,Math.max(1,v*2));}
    for(const track of makeSegments()){
      const plot=makeRow(track.name);
      for(const s of track.segments.filter(s=>ReportMath.visible(s,windowStart,end))){const b=node('button',s.text,'segment'+(!s.token?' unknown':''));b.type='button';b.style.left=`${100*(Math.max(s.start,windowStart)-windowStart)/width}%`;b.style.width=`${100*(Math.min(s.end,end)-Math.max(s.start,windowStart))/width}%`;if(s.token)b.style.backgroundColor=color(s.token);b.title=`${time(s.start)} - ${time(s.end)}\n${s.text}`;b.addEventListener('click',()=>{seek(s.start);if(s.words)selectWord(s.words[0]);});plot.append(b);timelineRows[timelineRows.length-1].segments??=[];timelineRows[timelineRows.length-1].segments.push({el:b,segment:s});}
      if(!track.activity){const text=node('div',undefined,'track-text');root.append(text);transcripts.push({track,text});}
    }
    renderTranscript();updatePlayback();
  }
  function renderTranscript(){
    const root=$('transcript');root.replaceChildren();
    const end=windowStart+Math.min(Number($('zoom').value),current.duration);
    for(const g of ReportMath.groups(current.words).filter(g=>ReportMath.visible(g,windowStart,end))){const p=node('div',undefined,'paragraph');p.append(node('div',decisionLabel(g.words[0]),'speaker'));for(const w of g.words){const b=node('button',w.text,'word');b.dataset.word=w.id;b.type='button';b.title=`${time(w.start)} - ${time(w.end)} · ${w.decision.rule}`;b.addEventListener('click',()=>{seek(w.start);selectWord(w);});p.append(b,document.createTextNode(' '));}root.append(p);}
  }
  function updatePlayback(){
    if(!current)return;const t=audio.currentTime||0,width=Math.min(Number($('zoom').value),current.duration);
    for(const r of timelineRows){r.marker.style.left=`${100*(t-windowStart)/width}%`;r.marker.hidden=t<windowStart||t>windowStart+width;for(const s of r.segments||[])s.el.classList.toggle('active',s.segment.start<=t&&t<s.segment.end);}
    for(const {track,text} of transcripts){const active=ReportMath.active(track.segments,t);text.textContent=active.length?active.map(s=>s.text).join(' + '):'Сейчас нет интервала этой дорожки';}
    for(const el of $('transcript').querySelectorAll('[data-word]')){const w=current.words.find(w=>w.id===el.dataset.word);el.classList.toggle('current',w.start<=t&&t<w.end);el.classList.toggle('chosen',w.id===selectedID);}
  }
  function chooseCase(id){current=data.cases.find(c=>c.id===id);$('case').value=id;audio.pause();audio.src=current.audio;windowStart=0;selectedID=null;$('wordEvidence').textContent='';$('wordHint').textContent='Нажмите слово или интервал.';$('caseMeta').textContent=`${current.id} · ${current.split} · ${current.language} · ${current.weakSpeakerCount} голосов Fathom, ${current.nativeSlotCount} исходных слотов · исходная встреча ${time(current.sourceStart)} - ${time(current.sourceEnd)} · ${current.words.length} исходных слов`;$('caseProof').textContent=json({proof:current.proof,policy:current.policy,policyFingerprint:current.policyFingerprint,metadata:current.metadata});drawTimeline();}
  function countRow(label,b,c){return [label,`${b.all_native_words} / ${c.all_native_words}`,`${b.all_unknown_words} → ${c.all_unknown_words}`,`${b.eligible_words} / ${c.eligible_words}`,`${b.excluded_words} / ${c.excluded_words}`,`${b.weak_disagree_words}/${b.assigned_words} (${pct(b.weak_disagree_words,b.assigned_words)}) → ${c.weak_disagree_words}/${c.assigned_words} (${pct(c.weak_disagree_words,c.assigned_words)})`,`${pct(b.all_native_words-b.all_unknown_words,b.all_native_words)} → ${pct(c.all_native_words-c.all_unknown_words,c.all_native_words)}`];}
  function table(headers,rows){const t=node('table'),head=node('thead'),hr=node('tr');for(const h of headers)hr.append(node('th',h));head.append(hr);t.append(head);const body=node('tbody');for(const cells of rows){const tr=node('tr');for(const x of cells)tr.append(node('td',x));body.append(tr);}t.append(body);const wrap=node('div',undefined,'scroll');wrap.append(t);return wrap;}
  function renderStats(){const cases=data.cases.filter(c=>$('split').value==='all'||c.split===$('split').value),profile=$('profile').value;const rows=[];for(const [name,filtered]of[['Выполненные тесты',cases],['2 спикера Fathom',cases.filter(c=>c.weakSpeakerCount===2)],['3 спикера Fathom',cases.filter(c=>c.weakSpeakerCount===3)],['4+ спикера Fathom',cases.filter(c=>c.weakSpeakerCount>=4)]])if(filtered.length)rows.push(countRow(`${name}: ${filtered.length}`,ReportMath.sumMetrics(filtered,'baseline4484',profile),ReportMath.sumMetrics(filtered,data.candidate,profile)));$('aggregate').replaceChildren(table(['Группа','Все слова: до / после','Не определены','Допустимы: до / после','Исключены: до / после','Конфликты / назначенные среди допустимых','Назначено из всех слов'],rows));const tbody=$('cases').querySelector('tbody');tbody.replaceChildren();for(const c of cases){const tr=node('tr'),td=node('td'),b=node('button',c.id);b.type='button';b.addEventListener('click',()=>{chooseCase(c.id);$('timeline').scrollIntoView({behavior:'smooth',block:'center'});});td.append(b);tr.append(td);const before=ReportMath.sumMetrics([c],'baseline4484',profile),after=ReportMath.sumMetrics([c],data.candidate,profile);for(const v of [`${c.split} / ${c.language}`,`${c.weakSpeakerCount} / ${c.nativeSlotCount}`,String(c.words.length),`${before.all_unknown_words} → ${after.all_unknown_words}`,`${before.weak_disagree_words}/${before.assigned_words} → ${after.weak_disagree_words}/${after.assigned_words}`])tr.append(node('td',v));tbody.append(tr);}const rules={};for(const c of cases)for(const w of c.words){const r=w.decision.rule;rules[r]??={count:0,selected:0,background:0};rules[r].count++;rules[r].selected+=!!w.selected;rules[r].background+=w.background.length>0;}$('rules').replaceChildren(table(['Правило','Все слова','С выбранным голосом','С фоновым голосом'],Object.entries(rules).sort((a,b)=>b[1].count-a[1].count).map(([r,v])=>[r,String(v.count),String(v.selected),String(v.background)])));
    const qrows=cases.map(c=>{const a=c.metrics.weak_activity_timeline_diagnostic?.[profile]||{};return [c.id,a.der===undefined||a.der===null?'не предоставлено':pct(a.der,1),a.jer===undefined||a.jer===null?'не предоставлено':pct(a.jer,1)];});
    $('quality').replaceChildren(table(['Фрагмент','Исходная активность: weak DER','Исходная активность: weak JER'],qrows));}
  function renderTextQuality(){
    const root=$('textQuality'),q=data.textQuality;
    if(!q){root.textContent='Отдельный проверенный расчет WER/CER к этой версии не приложен. Старые и приблизительные показатели не подставлены вместо него.';return;}
    const guard=Number($('textGuard').value),cases=data.cases.filter(c=>$('split').value==='all'||c.split===$('split').value);
    const rows=[],profiles=[];
    for(const c of cases){const qc=q.clips.find(x=>x.clip_id===c.id),p=qc.profiles.find(x=>x.guard_seconds===guard);profiles.push(p);rows.push([c.id,pct(p.distance,p.reference_tokens),pct(p.char_distance,p.reference_characters),`${p.substitutions ?? (p.weak_wer === null ? 0 : 'не предоставлено')} / ${p.deletions ?? (p.weak_wer === null ? 0 : 'не предоставлено')} / ${p.insertions ?? (p.weak_wer === null ? 0 : 'не предоставлено')}`,String(p.reference_tokens),`${p.eligible_turns}/${p.reference_turns_total}`,`${p.scored_seconds.toFixed(2)}/${c.duration}`,`${p.native_units_included}/${p.native_units_total}`]);}
    const t=ReportMath.sumTextQuality(profiles);rows.unshift(['Итого по выбранной группе',pct(t.distance,t.reference_tokens),pct(t.char_distance,t.reference_characters),`${t.substitutions} / ${t.deletions} / ${t.insertions}`,String(t.reference_tokens),`${t.eligible_turns}/${t.reference_turns_total}`,t.scored_seconds.toFixed(2),`${t.native_units_included}/${t.native_units_total}`]);
    root.replaceChildren(table(['Фрагмент','weak WER','weak CER','S / D / I','Слова ориентира','Реплики: допустимы / все','Скорируемое время, с','Исходные единицы: включены / все'],rows));
    const d=node('details'),s=node('summary','Нормализация, интерпретация и версия расчета');d.append(s,node('pre',json({metric_version:q.metric_version,primary_guard_seconds:q.primary_guard_seconds,normalization:q.normalization,interpretation:q.interpretation,sourceSHA256:data.textQualitySHA256})));root.append(d);
  }
  function renderPhysical(){const root=$('physical');if(!data.physical){root.textContent='Новые измерения на физическом iPad еще не приложены к этой версии отчета. Mac RSS и старые тесты не подставлены вместо них.';return;}const p=data.physical;root.append(node('p',p.status||'Предоставлены фактические данные родительской проверки.'));if(p.summary)root.append(node('p',typeof p.summary==='string'?p.summary:json(p.summary)));if(Array.isArray(p.runs)&&p.runs.length){const columns=[['id','Тест'],['fixture','Фрагмент'],['tested_revision','Ревизия'],['audio_seconds','Аудио, с'],['post_stop_seconds','После Stop, с'],['total_seconds','Всего, с'],['peak_footprint_mib','Пик footprint, МиБ'],['baseline_footprint_mib','Базовый footprint, МиБ'],['thermal_state','Тепловое состояние'],['quality_note','Качество / ограничения']];root.append(table(columns.map(c=>c[1]),p.runs.map(r=>columns.map(([k])=>r[k]===undefined?'не предоставлено':typeof r[k]==='object'?json(r[k]):String(r[k])))));}const d=node('details'),s=node('summary','Все исходные поля приложенного результата');d.append(s,node('pre',json(p)));root.append(d);root.append(node('p','Скорость, память и качество интерпретируются в пределах указанных в результате условий. Повтор в том же процессе сам по себе не доказывает теплую резидентность модели. Впрыск PCM не проверяет микрофон, фоновые прерывания или расход энергии.','muted'));}
  $('status').textContent=data.status==='final'?`Выполнено ${data.cases.length} отдельных фрагментов. Финальный набор результатов этой версии отчета.`:`Промежуточная версия: выполнено ${data.cases.length} из ${data.corpusCount} выбранных фрагментов. Результаты текущего кандидата не объявлены финальными.`;
  if(!data.sourceVerified)$('status').textContent+=' Привязка результата к исполняемому файлу и исходному коду не проверена; заявления ревизии из индекса не считаются подтвержденными.';
  const counts=[['Реальные встречи',data.cases.length],['Аудио, минут',data.cases.reduce((s,c)=>s+c.duration,0)/60],['Исходные слова',data.cases.reduce((s,c)=>s+c.words.length,0)],['HeldOut выполнено',data.cases.filter(c=>c.split==='heldOut').length]];for(const [name,value]of counts){const c=node('div',undefined,'card');c.append(node('strong',String(value)),node('span',name));$('headline').append(c);}
  const initialBefore=ReportMath.sumMetrics(data.cases,'baseline4484','interior1s'),initialAfter=ReportMath.sumMetrics(data.cases,data.candidate,'interior1s');
  $('measuredFinding').textContent=`На выполненных ${data.cases.length} фрагментах: неопределенных исходных слов ${initialBefore.all_unknown_words} → ${initialAfter.all_unknown_words} из ${initialAfter.all_native_words}. В профиле вне границ Fathom ±1 с конфликтов ${initialBefore.weak_disagree_words}/${initialBefore.assigned_words} → ${initialAfter.weak_disagree_words}/${initialAfter.assigned_words} среди назначенных допустимых слов. Эти два показателя следует читать вместе: рост покрытия не является автоматическим доказательством улучшения качества.`;
  $('notes').textContent=data.notes;$('notes').hidden=!data.notes;$('host').append(node('pre',json(data.host)));
  $('proof').textContent=json({reportStatus:data.status,indexStatus:data.indexStatus,indexSHA256:data.indexSHA256,corpusSHA256:data.corpusSHA256,sourceCommit:data.sourceCommit,coreSHA256:data.coreSHA256,sourceVerified:data.sourceVerified,unverifiedIndexSourceClaim:data.unverifiedIndexSourceClaim,candidate:data.candidate,policyFingerprint:data.cases[0].policyFingerprint,physicalSHA256:data.physicalSHA256,textQualitySHA256:data.textQualitySHA256,participantDisjoint:data.participantDisjoint,validation:'Static generation and hash checks. Browser rendering and listening not claimed.'});
  for(const c of data.cases){const option=node('option',`${c.id} · ${c.split} · ${c.weakSpeakerCount} голосов · ${c.language}`);option.value=c.id;$('case').append(option);}
  $('case').addEventListener('change',()=>chooseCase($('case').value));$('split').addEventListener('change',()=>{renderStats();renderTextQuality();});$('profile').addEventListener('change',renderStats);$('textGuard').addEventListener('change',renderTextQuality);$('zoom').addEventListener('change',()=>{windowStart=Math.min(windowStart,Math.max(0,current.duration-Number($('zoom').value)));drawTimeline();});$('window').addEventListener('input',()=>{windowStart=Number($('window').value);drawTimeline();});audio.addEventListener('timeupdate',()=>{const old=windowStart;if($('follow').checked)ensureWindow(audio.currentTime);if(old!==windowStart)drawTimeline();else updatePlayback();});audio.addEventListener('play',()=>{const tick=()=>{if(!audio.paused){updatePlayback();animation=requestAnimationFrame(tick);}};cancelAnimationFrame(animation);tick();});audio.addEventListener('pause',()=>cancelAnimationFrame(animation));$('timeline').addEventListener('keydown',e=>{if(['ArrowLeft','ArrowRight',' '].includes(e.key)){e.preventDefault();if(e.key===' ')audio.paused?audio.play():audio.pause();else seek(audio.currentTime+(e.key==='ArrowLeft'?-1:1));}});
  renderStats();renderTextQuality();renderPhysical();chooseCase(data.cases[0].id);
})();
