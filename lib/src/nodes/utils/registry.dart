import 'package:dsp/dsp.dart';

typedef ProcessorFactory = AudioProcessor Function(Object params);
typedef NodeRegistration = ({Type nodeType, ProcessorFactory build});
typedef ProcessorRegistry = Map<String, NodeRegistration>;

extension ProcessorRegistryExtension on ProcessorRegistry {
  AudioProcessor build(String typeKey, Object params) {
    final registration = this[typeKey];
    if (registration == null) {
      throw ArgumentError('No registration found for type key: $typeKey');
    }
    return registration.build(params);
  }

  String keyForNode(AudioNode node) =>
      entries.where((e) => e.value.nodeType == node.runtimeType).first.key;
}

// THIS IS TEMPORARY! We will probably use code gen.
ProcessorRegistry defaultRegistry() => {
  'sine': (nodeType: SineOscillator, build: SineOscillatorProcessor.build),
  'sawtooth': (
    nodeType: SawtoothOscillator,
    build: SawtoothOscillatorProcessor.build,
  ),
  'square': (
    nodeType: SquareOscillator,
    build: SquareOscillatorProcessor.build,
  ),
  'stereo_pan': (nodeType: StereoPan, build: StereoPanProcessor.build),
  'stereo_split': (nodeType: StereoSplit, build: StereoSplitProcessor.build),
  'offset': (nodeType: Offset, build: OffsetProcessor.build),
  'gain': (nodeType: Gain, build: GainProcessor.build),
  'dac': (nodeType: Dac, build: DacProcessor.build),
};
