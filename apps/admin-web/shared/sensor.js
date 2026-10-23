// Port of br4c3/esp32_telecommunication (3ddc5ec), MIT © 2026 MinSup Kim.
// See vendor/esp32_telecommunication/LICENSE. Values are relative load, not Pa/mmHg.
import {CHANNEL_IDS, CHANNELS} from './layout.js';
export const BLE = Object.freeze({service:'6e400001-b5a3-f393-e0a9-e50e24dcca9e',rx:'6e400002-b5a3-f393-e0a9-e50e24dcca9e',tx:'6e400003-b5a3-f393-e0a9-e50e24dcca9e'});
export const STATES = Object.freeze({center:'기준 범위',left:'왼쪽 쏠림',right:'오른쪽 쏠림',front:'앞쪽 쏠림',back:'뒤쪽 쏠림',away:'미착석',unavailable:'미측정'});
export const GUIDANCE = Object.freeze({center:'개인 기준에 가까운 압력 분포예요.',left:'가능한 범위에서 몸을 중앙 쪽으로 옮겨 주세요.',right:'가능한 범위에서 몸을 중앙 쪽으로 옮겨 주세요.',front:'가능한 범위에서 엉덩이를 뒤로 옮겨 주세요.',back:'편안한 범위에서 상체를 세워 주세요.',away:'착석 압력이 감지되지 않았어요.',unavailable:'연결과 보정을 확인해 주세요.'});
export const COMMANDS = Object.freeze(['GET_CALIBRATION_STATUS','CALIBRATE_ZERO','CALIBRATE_BALANCE','CONTINUE_ZERO_CALIBRATION','CONTINUE_BALANCE_CALIBRATION']);
export function deviceCode(value='') { return String(value).trim().toUpperCase().match(/^(?:ESP32[:\-]P?[:\-]?)?([0-9A-F]{6})$/)?.[1]??null; }
export function parsePacket(input) {
 const text=String(input).trim();
 if(text.startsWith('P:')) {const parts=text.slice(2).split(',');if(parts.length!==5||parts.some(p=>!/^\d+(?:\.\d+)?$/.test(p.trim())))return null;const values=parts.map(Number);if(values.some(v=>!Number.isFinite(v)||v<0||v>65535))return null;return {type:'pressure',values};}
 const match=text.match(/^S:(SETUP_REQUIRED|ZERO_REQUIRED|ZERO_CALIBRATING|CALIBRATING|BALANCE_REQUIRED|BALANCE_CALIBRATING|READY|ZERO_FAILED|CALIBRATION_FAILED|ZERO_WARNING|BALANCE_WARNING)(?::([1-5](?:,[1-5])*))?$/);
 if(!match)return null;return {type:'status',status:match[1],warnings:match[2]?.split(',').map(Number)??[]};
}
export function assess(values) {
 if(!Array.isArray(values)||values.length!==5||values.some(v=>!Number.isFinite(v)||v<0||v>65535))return {lean:'unavailable',lateral:0,longitudinal:0};
 const total=values.reduce((s,v)=>s+v,0);if(total<125)return {lean:'away',lateral:0,longitudinal:0};
 const [a,b,c,d,e]=values,left=(a+c)/2,right=(b+d)/2,front=(a+b)/2,back=(c+d+e)/3;
 const lateral=(right-left)/Math.max(1,right+left),longitudinal=(front-back)/Math.max(1,front+back),ls=(a+c)/total,rs=(b+d)/total,edge=ls>=.5||rs>=.5;
 const side=Math.abs(lateral)>=.14||edge,fore=Math.abs(longitudinal)>=.20;
 const lean=!side&&!fore?'center':side&&(!fore||Math.abs(lateral)>=Math.abs(longitudinal))?((edge?rs>ls:lateral>0)?'right':'left'):(longitudinal>0?'front':'back');
 return {lean,lateral,longitudinal};
}
export class AlertTracker {
 constructor(){this.reset();this.sent={};}
 reset(){this.candidate=null;this.since=null;this.last=null;}
 update(lean,at,ready=true){
  if(!ready||['center','away','unavailable'].includes(lean)){this.reset();return false;}
  if(this.last!==null&&(at-this.last>=2000||at<this.last)){this.reset();}
  this.last=at;if(this.candidate!==lean){this.candidate=lean;this.since=at;return false;}
  if(at-this.since<3000||at-(this.sent[lean]??-Infinity)<60000)return false;
  this.sent[lean]=at;return true;
 }
}
// Current upstream compact cosine heat field (not the old Gaussian RBF in its README).
export function pressureField(values,rows=72,columns=48) {
 return Array.from({length:rows},(_,r)=>Array.from({length:columns},(_,c)=>{
  let remaining=1;for(let i=0;i<5;i++){const p=CHANNELS[CHANNEL_IDS[i]],distance=Math.hypot((c+.5)/columns-p.x,(r+.5)/rows-p.y);const influence=distance>=.48?0:.5*(1+Math.cos(Math.PI*distance/.48));remaining*=1-Math.max(0,Math.min(1,(values[i]??0)/3200))*influence;}return (1-remaining)*3200;
 }));
}
