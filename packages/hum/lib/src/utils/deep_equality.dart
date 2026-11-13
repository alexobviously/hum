/// Deep value equality for node property lists and parameters.
bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;

  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }

  if (a is Set && b is Set) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !deepEquals(a[key], b[key])) return false;
    }
    return true;
  }

  return a == b;
}
