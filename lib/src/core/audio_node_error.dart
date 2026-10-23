part of 'audio_node.dart';

class const AudioNodeError({required final String message});

class const AudioNodeParamError({
  required final String param,
  required final String error,
}) extends AudioNodeError {
  this : super(message: '[$param]: $error');
}
