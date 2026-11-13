part of 'audio_node.dart';

class const AudioNodeError({required final String message});

class const AudioNodeParamError({
  required final String param,
  required final String error,
}) extends AudioNodeError {
  this : super(message: '[$param]: $error');
}

/// A collection of [AudioNodeError]s associated with a specific [AudioNode].
class const NodeDiagnostic({
  required final AudioNode node,
  required final List<AudioNodeError> errors,
}) {
  bool get hasErrors => errors.isNotEmpty;

  @override
  String toString() {
    final prefix = '${node.runtimeType}:';
    return switch (errors) {
      [final single] => '$prefix ${single.message}',
      _ => '$prefix\n${errors.map((e) => '  • ${e.message}').join('\n')}',
    };
  }
}
