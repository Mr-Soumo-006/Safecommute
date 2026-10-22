import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

enum AccidentType {
  vehicleCrash,
  hardFall,
  physicalAssault,
  none,
}

extension AccidentTypeExt on AccidentType {
  String get displayName {
    switch (this) {
      case AccidentType.vehicleCrash:
        return "Vehicle Collision / Crash";
      case AccidentType.hardFall:
        return "Hard Fall / Pedestrian Impact";
      case AccidentType.physicalAssault:
        return "Physical Assault / Violent Struggle";
      case AccidentType.none:
        return "Unknown";
    }
  }

  String get code {
    switch (this) {
      case AccidentType.vehicleCrash:
        return "VEHICLE_CRASH";
      case AccidentType.hardFall:
        return "HARD_FALL";
      case AccidentType.physicalAssault:
        return "PHYSICAL_ASSAULT";
      case AccidentType.none:
        return "NONE";
    }
  }

  String get iconEmoji {
    switch (this) {
      case AccidentType.vehicleCrash:
        return "🚗💥";
      case AccidentType.hardFall:
        return "⚠️🤕";
      case AccidentType.physicalAssault:
        return "🚨🥊";
      case AccidentType.none:
        return "🆘";
    }
  }
}

class AccidentTelemetry {
  final AccidentType type;
  final double peakGForce;
  final double estimatedSpeedKmh;
  final DateTime timestamp;

  AccidentTelemetry({
    required this.type,
    required this.peakGForce,
    required this.estimatedSpeedKmh,
    required this.timestamp,
  });
}

class MobileAccidentDetector {
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  final void Function(AccidentTelemetry telemetry) onAccidentDetected;

  bool _isEnabled = false;
  double _currentSpeedKmh = 0.0;

  // Fall detection state machine
  bool _freeFallDetected = false;
  DateTime? _freeFallTime;

  // Assault / struggle detection state machine
  final List<DateTime> _violentJerkTimestamps = [];

  // Cooldown to prevent multi-triggering
  DateTime? _lastTriggerTime;

  MobileAccidentDetector({required this.onAccidentDetected});

  void updateSpeed(double speedMps) {
    if (speedMps >= 0) {
      _currentSpeedKmh = speedMps * 3.6; // convert m/s to km/h
    }
  }

  void start({bool enabled = false}) {
    _isEnabled = enabled;
    if (!_isEnabled) {
      stop();
      return;
    }

    _accelSubscription?.cancel();
    _accelSubscription = accelerometerEventStream().listen(_processAccelerometer);
    debugPrint("[AccidentDetector] Mobile sensor accident detection active.");
  }

  void stop() {
    _accelSubscription?.cancel();
    _accelSubscription = null;
  }

  void setEnabled(bool enabled) {
    _isEnabled = enabled;
    if (!enabled) {
      stop();
    } else {
      start(enabled: true);
    }
  }

  void _processAccelerometer(AccelerometerEvent event) {
    if (!_isEnabled) return;

    final now = DateTime.now();

    // Prevent re-trigger within 15 seconds of any accident event
    if (_lastTriggerTime != null && now.difference(_lastTriggerTime!).inSeconds < 15) {
      return;
    }

    // Magnitude in m/s^2, normalized to G-force (1 G ≈ 9.80665 m/s^2)
    final double magnitude = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    final double gForce = magnitude / 9.80665;

    // ---------------------------------------------------------
    // 1. VEHICLE CRASH DETECTION:
    // High pre-event travel speed (>22 km/h) + sudden violent impact (>4.2 G)
    // OR extreme catastrophic impact (>5.5 G) even if speed reading was lagged
    // ---------------------------------------------------------
    if ((_currentSpeedKmh > 22.0 && gForce > 4.0) || gForce > 5.5) {
      _lastTriggerTime = now;
      onAccidentDetected(AccidentTelemetry(
        type: AccidentType.vehicleCrash,
        peakGForce: gForce,
        estimatedSpeedKmh: _currentSpeedKmh,
        timestamp: now,
      ));
      return;
    }

    // ---------------------------------------------------------
    // 2. HARD FALL DETECTION:
    // Stage A: Freefall phase (Near 0 G, weightlessness for 75-400ms)
    // Stage B: Ground Impact phase (Sharp spike > 3.0 G within 500ms of freefall)
    // ---------------------------------------------------------
    if (gForce < 0.45) {
      // Body / phone is in free-fall
      _freeFallDetected = true;
      _freeFallTime = now;
    } else if (_freeFallDetected && _freeFallTime != null) {
      final int msSinceFreefall = now.difference(_freeFallTime!).inMilliseconds;
      if (msSinceFreefall < 500 && gForce > 3.0) {
        // Impact confirmed immediately following free-fall
        _freeFallDetected = false;
        _freeFallTime = null;
        _lastTriggerTime = now;

        onAccidentDetected(AccidentTelemetry(
          type: AccidentType.hardFall,
          peakGForce: gForce,
          estimatedSpeedKmh: _currentSpeedKmh,
          timestamp: now,
        ));
        return;
      } else if (msSinceFreefall >= 500) {
        // Expired free-fall without hard impact
        _freeFallDetected = false;
        _freeFallTime = null;
      }
    }

    // ---------------------------------------------------------
    // 3. PHYSICAL ASSAULT / VIOLENT STRUGGLE DETECTION:
    // Repeated erratic violent jerks (> 2.8 G) happening >= 4 times within 2 seconds
    // ---------------------------------------------------------
    if (gForce > 2.8) {
      _violentJerkTimestamps.add(now);
      _violentJerkTimestamps.removeWhere((t) => now.difference(t).inMilliseconds > 2000);

      if (_violentJerkTimestamps.length >= 4 && _currentSpeedKmh < 15.0) {
        _violentJerkTimestamps.clear();
        _lastTriggerTime = now;

        onAccidentDetected(AccidentTelemetry(
          type: AccidentType.physicalAssault,
          peakGForce: gForce,
          estimatedSpeedKmh: _currentSpeedKmh,
          timestamp: now,
        ));
        return;
      }
    }
  }
}
