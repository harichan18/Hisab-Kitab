import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ShareReceiverService {
  ShareReceiverService._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final ShareReceiverService instance = ShareReceiverService._();

  static const MethodChannel _channel = MethodChannel('hisab_kitab/share_receiver');

  final StreamController<String> _sharedImageController =
      StreamController<String>.broadcast();

  Stream<String> get sharedImageStream => _sharedImageController.stream;

  String? _pendingImagePath;
  String? get pendingImagePath => _pendingImagePath;

  String? _lastHandledPath;
  DateTime? _lastHandledTime;

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onImageShared') {
      final path = call.arguments as String?;
      if (path != null && path.isNotEmpty) {
        _dispatchSharedImage(path);
      }
    }
  }

  /// Checks for any shared image that triggered app launch (cold-start).
  Future<String?> checkInitialSharedImage() async {
    try {
      final initialPath = await _channel.invokeMethod<String>('getInitialSharedImage');
      if (initialPath != null && initialPath.isNotEmpty) {
        _dispatchSharedImage(initialPath);
        return initialPath;
      }
    } catch (e) {
      debugPrint('[ShareReceiverService] Error checking initial shared image: $e');
    }
    return null;
  }

  void _dispatchSharedImage(String path) {
    // Prevent duplicate processing within 3 seconds for the exact same file path
    final now = DateTime.now();
    if (_lastHandledPath == path &&
        _lastHandledTime != null &&
        now.difference(_lastHandledTime!) < const Duration(seconds: 3)) {
      debugPrint('[ShareReceiverService] Skipping duplicate share event for: $path');
      return;
    }

    _lastHandledPath = path;
    _lastHandledTime = now;
    _pendingImagePath = path;
    _sharedImageController.add(path);
    debugPrint('[ShareReceiverService] Dispatched shared image: $path');
  }

  /// Clears the pending image once consumed by the UI.
  void clearPendingImage() {
    _pendingImagePath = null;
    _channel.invokeMethod('clearSharedImage').catchError((e) {
      debugPrint('[ShareReceiverService] clearSharedImage error: $e');
    });
  }

  void dispose() {
    _sharedImageController.close();
  }
}
