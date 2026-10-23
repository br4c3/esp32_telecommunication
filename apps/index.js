import {initializeApp} from 'firebase-admin/app';
import {getFirestore} from 'firebase-admin/firestore';
import {onRequest} from 'firebase-functions/v2/https';
import {defineSecret} from 'firebase-functions/params';

import adminConnect from './api/admin-connect.js';
import {emptyTelemetry, createTelemetryHandler} from './api/telemetry.js';
import userConnect from './api/user-connect.js';

initializeApp();
const db = getFirestore();
const shareSecret = defineSecret('SENSOR_SHARE_SECRET');

async function read(room) {
  const snapshot = await db.collection('seatCareRooms').doc(room).get();
  return snapshot.exists
    ? {state: snapshot.data(), etag: snapshot.updateTime.toMillis().toString()}
    : {state: emptyTelemetry(), etag: null};
}

async function write(room, state, etag) {
  const ref = db.collection('seatCareRooms').doc(room);
  await db.runTransaction(async transaction => {
    const snapshot = await transaction.get(ref);
    const current = snapshot.exists ? snapshot.updateTime.toMillis().toString() : null;
    if (current !== etag) throw Error('precondition');
    transaction.set(ref, state);
  });
}

export const api = onRequest(
  {region: 'asia-northeast3', secrets: [shareSecret], cors: false},
  async (req, res) => {
    process.env.SENSOR_SHARE_SECRET = shareSecret.value();
    if (req.path.endsWith('/user-connect')) return userConnect(req, res);
    if (req.path.endsWith('/admin-connect')) return adminConnect(req, res);
    if (req.path.endsWith('/telemetry')) {
      return createTelemetryHandler({read, write, secret: shareSecret.value()})(req, res);
    }
    return res.status(404).json({error: 'API 경로를 찾을 수 없어요.'});
  },
);
