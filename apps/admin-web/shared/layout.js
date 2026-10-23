// Adopted drawing centers, not verified hardware placement or physical pressure calibration.
export const LAYOUT_ID='seat-care-drawing-20261007-v2';
export const CHANNEL_IDS=Object.freeze(['L1','R1','L2','R2','C1']);
export const CHANNELS=Object.freeze({
 L1:Object.freeze({x:0.30,y:0.30,label:'왼쪽 앞',drawingX:12,drawingY:12}),
 R1:Object.freeze({x:0.70,y:0.30,label:'오른쪽 앞',drawingX:28,drawingY:12}),
 L2:Object.freeze({x:0.325,y:0.675,label:'왼쪽 뒤',drawingX:13,drawingY:27}),
 R2:Object.freeze({x:0.675,y:0.675,label:'오른쪽 뒤',drawingX:27,drawingY:27}),
 C1:Object.freeze({x:0.50,y:0.85,label:'중앙후방',drawingX:20,drawingY:34})
});
export const GEOMETRY=Object.freeze({id:LAYOUT_ID,channelIds:CHANNEL_IDS,points:CHANNELS,referenceSize:40,unit:null,orientation:'seated-person-top-view',designAdopted:true,hardwareVerified:false});
export function namedChannelsValid(ids){return Array.isArray(ids)&&ids.length===5&&new Set(ids).size===5&&Array.from(ids).every(id=>CHANNEL_IDS.includes(id));}
export function geometryValid(layout){return !!layout&&layout.id===LAYOUT_ID&&namedChannelsValid(layout.channelIds)&&CHANNEL_IDS.every(id=>layout.points?.[id]?.x===CHANNELS[id].x&&layout.points?.[id]?.y===CHANNELS[id].y);}
export function geometrySignature(layout){return JSON.stringify([layout.id,...CHANNEL_IDS.map(id=>[id,layout.points[id].x,layout.points[id].y])]);}
export function namedValues(values,ids=CHANNEL_IDS){if(!Array.isArray(values)||values.length!==5||!namedChannelsValid(ids))throw Error('명명된 5채널 매핑이 필요합니다.');return Object.fromEntries(ids.map((id,i)=>[id,values[i]]));}
export function orderedValues(values,ids,order=CHANNEL_IDS){const named=namedValues(values,ids);return order.map(id=>named[id]);}
export function recordingGeometry(layout){if(!geometryValid(layout))throw Error('기록 배치 버전이 현재 도면과 다릅니다.');return {id:layout.id,channelIds:[...layout.channelIds],points:Object.fromEntries(CHANNEL_IDS.map(id=>[id,{x:layout.points[id].x,y:layout.points[id].y}]))};}
