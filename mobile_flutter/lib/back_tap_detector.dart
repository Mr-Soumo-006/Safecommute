import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

class BackTapDetector {
  StreamSubscription<UserAccelerometerEvent>? _subscription;
  final VoidCallback onBackTapTriggered;

  bool _isEnabled = true;
  int _requiredTaps = 2; // 2 = Double Tap, 3 = Triple Tap

  final List<DateTime> _tapTimestamps = [];
  DateTime? _lastDetectedTapTime;
  DateTime? _lastTriggerTime;

  BackTapDetector({
    required this.onBackTapTriggered,
    bool enabled = true,
    int requiredTaps = 2,
  }) {
    _isEnabled = enabled;
    _requiredTaps = requiredTaps;
  }

  void start({bool? enabled, int? requiredTaps}) {
    if (enabled != null) _isEnabled = enabled;
    if (requiredTaps != null) _requiredTaps = requiredTaps;

    if (!_isEnabled) {
      stop();
      return;
    }

    _subscription?.cancel();
    _subscription = userAccelerometerEventStream().listen(_processEvent);
    debugPrint("[BackTapDetector] iPhone-style Back Tap detector active (Required taps: $_requiredTaps).");
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _tapTimestamps.clear();
  }

  void setConfig({required bool enabled, required int requiredTaps}) {
    _isEnabled = enabled;
    _requiredTaps = requiredTaps;
    if (!enabled) {
      stop();
    } else if (_subscription == null) {
      start();
    }
  }

  void _processEvent(UserAccelerometerEvent event) {
    if (!_isEnabled) return;

    final now = DateTime.now();

    // Prevent re-triggering within 4 seconds of a successful Back Tap trigger
    if (_lastTriggerTime != null && now.difference(_lastTriggerTime!).inSeconds < 4) {
      return;
    }

    // Back Tap primarily induces a sharp transient impulse on the Z-axis
    // (perpendicular to the phone back).
    final double zAcc = event.z.abs();
    final double lateralAcc = (event.x.abs() + event.y.abs());

    // Filter: Tap must have strong Z impulse with moderate lateral movement
    // (A finger tap on the back has high Z jerk and relatively low lateral sway)
    const double minZImpulse = 1.9; // m/s^2
    const double maxLateralSway = 4.0; // m/s^2

    if (zAcc >= minZImpulse && lateralAcc < maxLateralSway) {
      // Enforce a debounce between consecutive taps: at least 130ms apart
      // (prevents counting the mechanical recoil of a single tap as two taps)
      if (_lastDetectedTapTime != null && now.difference(_lastDetectedTapTime!).inMilliseconds < 130) {
        return;
      }

      _lastDetectedTapTime = now;
      _tapTimestamps.add(now);

      // Keep only taps within the valid tap window:
      // For double-tap: within 500ms
      // For triple-tap: within 850ms
      final int windowMs = _requiredTaps == 3 ? 850 : 500;
      _tapTimestamps.removeWhere((t) => now.difference(t).inMilliseconds > windowMs);

      if (_tapTimestamps.length >= _requiredTaps) {
        _tapTimestamps.clear();
        _lastTriggerTime = now;
        HapticFeedback.heavyImpact();
        debugPrint("[BackTapDetector]  iPhone Back Tap detected! ($_requiredTaps taps)");
        onBackTapTriggered();
      }
    }
  }
}
