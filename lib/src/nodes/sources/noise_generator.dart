import 'dart:typed_data';

import 'package:dsp/dsp.dart';

enum NoiseType { white, pink, brown }

typedef NoiseGeneratorParams = ({NoiseType type});

class NoiseGenerator implements AudioNode<NoiseGeneratorProcessor> {
  final NoiseType type;
  final int? seed;

  const NoiseGenerator({this.type = .white, this.seed});
  const NoiseGenerator.white({int? seed}) : this(type: .white, seed: seed);
  const NoiseGenerator.pink({int? seed}) : this(type: .pink, seed: seed);
  const NoiseGenerator.brown({int? seed}) : this(type: .brown, seed: seed);

  @override
  List<Inlet> get inlets => const [];

  @override
  List<Outlet> get outlets => [Outlet(node: this, index: 0)];

  Outlet get outlet => outlets.first;

  @override
  NoiseGeneratorProcessor createProcessor() => NoiseGeneratorProcessor(
    type: type,
    seed: seed,
  );

  @override
  NoiseGeneratorParams get params => (type: type);
}

extension NoiseGeneratorScale on NoiseGenerator {
  Scale scale(double outLow, double outHigh) => Scale(
    input: outlet,
    inLow: const .value(-1.0),
    inHigh: const .value(1.0),
    outLow: .value(outLow),
    outHigh: .value(outHigh),
  );
}

class NoiseGeneratorProcessor implements AudioProcessor {
  NoiseGeneratorProcessor({
    this.type = NoiseType.white,
    int? seed,
  }) : _state = (seed == null || seed == 0) ? 2463534242 : seed & 0xFFFFFFFF;

  NoiseType type;
  int _state;

  // Pink noise filter state (Paul Kellet's 6-pole filter)
  double _b0 = 0.0;
  double _b1 = 0.0;
  double _b2 = 0.0;
  double _b3 = 0.0;
  double _b4 = 0.0;
  double _b5 = 0.0;
  double _b6 = 0.0;

  // Brown noise filter state (1-pole leaky integrator)
  double _brown = 0.0;

  @override
  void update(Object params) {
    params = params as NoiseGeneratorParams;
    type = params.type;
  }

  /// Fast inline 32-bit xorshift pseudo-random number generator.
  /// Yields uniformly distributed samples in [-1.0, 1.0].
  /// https://en.wikipedia.org/wiki/Xorshift
  @pragma('vm:prefer-inline')
  double _nextWhite() {
    int x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= (x >> 17);
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x;
    return (x & 0x00FFFFFF) * (2.0 / 0x00FFFFFF) - 1.0;
  }

  @override
  void process(
    ProcessContext context,
    List<Float32List> inputs,
    List<Float32List> outputs,
  ) {
    final output = outputs[0];
    final length = output.length;

    switch (type) {
      case .white:
        for (int i = 0; i < length; i++) {
          output[i] = _nextWhite();
        }

      case .pink:
        // https://en.wikipedia.org/wiki/Pink_noise
        // https://www.musicdsp.org/en/latest/Filters/76-pink-noise-filter.html

        // Using local variables is a performance optimisation, it's about
        // ~10% faster, due to some compiler wizardry stuff.
        // (instance variables live on the heap)
        double b0 = _b0,
            b1 = _b1,
            b2 = _b2,
            b3 = _b3,
            b4 = _b4,
            b5 = _b5,
            b6 = _b6;

        for (int i = 0; i < length; i++) {
          final white = _nextWhite();
          b0 = 0.99886 * b0 + white * 0.0555179;
          b1 = 0.99332 * b1 + white * 0.0750759;
          b2 = 0.96900 * b2 + white * 0.1538520;
          b3 = 0.86650 * b3 + white * 0.3104856;
          b4 = 0.55000 * b4 + white * 0.5329522;
          b5 = -0.7616 * b5 - white * 0.0168980;
          output[i] =
              (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11;
          b6 = white * 0.115926;
        }

        _b0 = b0;
        _b1 = b1;
        _b2 = b2;
        _b3 = b3;
        _b4 = b4;
        _b5 = b5;
        _b6 = b6;

      case .brown:
        // https://en.wikipedia.org/wiki/Brownian_noise
        double brown = _brown;
        for (int i = 0; i < length; i++) {
          final white = _nextWhite();
          // 0118999881999119725 3
          brown = brown * 0.9803921568627451 + white * 0.019607843137254902;
          output[i] = brown * 3.5;
        }
        _brown = brown;
    }
  }
}
