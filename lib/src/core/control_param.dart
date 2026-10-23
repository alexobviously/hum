import 'dart:async';

import 'package:hum/hum.dart';

extension ControlParamExtension<T> on ControlParam<T> {
  T? get valueOrNull => switch (this) {
    ControlParamValue(:final value) => value,
    _ => null,
  };

  Outlet? get outletOrNull => switch (this) {
    ControlParamSignal(:final outlet) => outlet,
    _ => null,
  };

  /// Whether this parameter is an audio-rate signal.
  bool get isSignal => this is ControlParamSignal;

  /// Whether this parameter is a control-rate static value or stream.
  bool get isValue => !isSignal;
}

extension NullableControlParamExtension on ControlParam? {
  /// Whether this parameter can update to [other] without altering
  /// graph inlet routing (both null, or both sharing the same signal/value kind).
  bool canUpdate(ControlParam? other) {
    if (this == null && other == null) return true;
    if (this == null || other == null) return false;
    return this?.isSignal == other.isSignal;
  }
}

sealed class ControlParam<T> {
  const ControlParam();

  void init() {}
  void dispose() {}

  const factory value(T value) = ControlParamValue<T>;
  factory stream(Stream<T> stream, T initialValue) = ControlParamStream<T>;
  static ControlParam<double> signal(Outlet outlet) =>
      ControlParamSignal(outlet);
}

class ControlParamValue<T> extends ControlParam<T> {
  final T value;

  const ControlParamValue(this.value);

  const factory value(T value) = ControlParamValue<T>;
  factory stream(Stream<T> stream, T initialValue) = ControlParamStream<T>;
}

class ControlParamStream<T> extends ControlParam<T>
    implements ControlParamValue<T> {
  final Stream<T> stream;
  final T initialValue;

  ControlParamStream(this.stream, this.initialValue);

  late final StreamSubscription<T> _sub;

  late T _value = initialValue;

  @override
  T get value => _value;

  @override
  void init() {
    super.init();
    _sub = stream.listen((event) => _value = event);
  }

  @override
  void dispose() {
    super.dispose();
    _sub.cancel();
  }
}

class ControlParamSignal extends ControlParam<double> {
  final Outlet outlet;

  const ControlParamSignal(this.outlet);
}
