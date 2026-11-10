class const ProcessContext({
  required final int sampleRate,
  required final int vectorSize,
}) {
  this
    : assert(
        vectorSize > 0 && vectorSize % 4 == 0,
        'vectorSize must be a positive multiple of 4',
      );
}
