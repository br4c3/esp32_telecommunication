// Shared wire contract for real sensor data. Rehearsal data never enters this store.
import {LAYOUT_ID} from './layout.js';
export const RETENTION_MS=90*86400000;
export const MAX_EVENTS=2000;
export const MAX_NOTIFICATIONS=100;
const id=v=>typeof v==='string'&&/^[a-zA-Z0-9_-]{8,80}$/.test(v);
const finite=(v,min,max)=>Number.isFinite(v)&&v>=min&&v<=max;
const values=v=>Array.isArray(v)&&v.length===5&&v.every(x=>finite(x,0,65535));
const types=new Set(['session_started','baseline_registered','baseline_failed','alert_created','alert_acknowledged','relief_armed','relief_completed','relief_interrupted','data_lost','help_requested','sharing_started','sharing_stopped']);
export function emptyTelemetry(){return {version:1,snapshot:null,events:[],acknowledgements:{},notifications:[],updatedAt:0};}
export function pruneTelemetry(state,now){
 const events=(state.events||[]).filter(e=>e.at>=now-RETENTION_MS).slice(-MAX_EVENTS);
 const notifications=(state.notifications||[]).filter(n=>n.at>=now-RETENTION_MS).slice(-MAX_NOTIFICATIONS);
 return {...state,events,notifications,acknowledgements:Object.fromEntries(Object.entries(state.acknowledgements||{}).filter(([key])=>events.some(e=>e.id===key)))};
}
export function validateUpload(input,now){
 if(input?.version!==1||!id(input.requestId)||!Array.isArray(input.events)||input.events.length>50)throw Error('전송 형식을 확인해 주세요.');
 const s=input.snapshot;
 if(!s||s.source!=='sensor'||s.layoutId!==LAYOUT_ID||!id(s.sessionId)||!Number.isSafeInteger(s.sequence)||s.sequence<0||!finite(s.at,now-RETENTION_MS,now+300000)||!['seated','unloaded','unavailable'].includes(s.quality)||typeof s.connected!=='boolean'||(s.values!==null&&!values(s.values))||(s.baseline!==null&&!values(s.baseline))||typeof s.device!=='string'||s.device.length>80||!Array.isArray(s.bias)||s.bias.some(x=>!['L1','R1','L2','R2','C1'].includes(x)))throw Error('센서 상태 형식이 잘못됐어요.');
 if(s.quality==='seated'&&(!s.connected||!values(s.values)))throw Error('유효한 센서값이 필요해요.');
 const events=input.events.map(e=>{
  if(!e||!id(e.id)||!id(e.sessionId)||e.source!=='sensor'||!types.has(e.type)||!finite(e.at,now-RETENTION_MS,now+300000)||typeof e.detail!=='string'||e.detail.length>500)throw Error('기록 형식이 잘못됐어요.');
  return {id:e.id,sessionId:e.sessionId,source:'sensor',type:e.type,at:e.at,detail:e.detail};
 });
 return {snapshot:{source:'sensor',layoutId:LAYOUT_ID,sessionId:s.sessionId,sequence:s.sequence,at:s.at,quality:s.quality,connected:s.connected,device:s.device,values:s.values,baseline:s.baseline,bias:s.bias},events};
}
export function mergeTelemetry(state,input,now){
 const clean=validateUpload(input,now),previous=state.snapshot,incoming=clean.snapshot;
 const newer=!previous||(incoming.sessionId===previous.sessionId?incoming.sequence>previous.sequence:incoming.at>previous.at);
 const events=new Map(state.events.map(e=>[e.id,e]));
 for(const event of clean.events)if(!events.has(event.id))events.set(event.id,event);
 return pruneTelemetry({...state,snapshot:newer?incoming:previous,events:[...events.values()].sort((a,b)=>a.at-b.at),updatedAt:now},now);
}
export function telemetryView(state,now){
 const current=pruneTelemetry(state,now),s=current.snapshot;
 return {...current,online:!!s&&s.connected&&s.quality!=='unavailable'&&now-s.at>=-300000&&now-s.at<15000};
}
