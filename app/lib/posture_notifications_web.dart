import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<bool> requestPostureNotificationPermission() async {
  if (web.Notification.permission == 'granted') return true;
  final permission = await web.Notification.requestPermission().toDart;
  return permission.toDart == 'granted';
}

void showPostureNotification(String message) {
  if (web.Notification.permission != 'granted') return;
  unawaited(_showFromServiceWorker(message));
}

Future<void> _showFromServiceWorker(String message) async {
  final registration = await web.window.navigator.serviceWorker.ready.toDart;
  await registration
      .showNotification(
        'Seat Care 자세 알림',
        web.NotificationOptions(body: message, tag: 'seat-care-posture'),
      )
      .toDart;
}
