import 'package:hum/src/utils/deep_equality.dart';
import 'package:test/test.dart';

enum _SampleEnum { alpha, beta }

void main() {
  group('deepEquals', () {
    group('nulls and identical', () {
      test('identical references return true', () {
        final list = [1, 2, 3];
        expect(deepEquals(list, list), isTrue);

        const obj = 'hello';
        expect(deepEquals(obj, obj), isTrue);
      });

      test('both null returns true', () {
        expect(deepEquals(null, null), isTrue);
      });

      test('one null returns false', () {
        expect(deepEquals(null, 1), isFalse);
        expect(deepEquals('test', null), isFalse);
        expect(deepEquals(null, []), isFalse);
        expect(deepEquals([], null), isFalse);
      });
    });

    group('primitives and enums', () {
      test('integers', () {
        expect(deepEquals(42, 42), isTrue);
        expect(deepEquals(42, 43), isFalse);
      });

      test('doubles', () {
        expect(deepEquals(440.0, 440.0), isTrue);
        expect(deepEquals(440.0, 440.5), isFalse);
      });

      test('strings', () {
        expect(deepEquals('synth', 'synth'), isTrue);
        expect(deepEquals('synth', 'filter'), isFalse);
      });

      test('booleans', () {
        expect(deepEquals(true, true), isTrue);
        expect(deepEquals(false, false), isTrue);
        expect(deepEquals(true, false), isFalse);
      });

      test('enums', () {
        expect(deepEquals(_SampleEnum.alpha, _SampleEnum.alpha), isTrue);
        expect(deepEquals(_SampleEnum.alpha, _SampleEnum.beta), isFalse);
      });

      test('type mismatches return false', () {
        expect(deepEquals(42, '42'), isFalse);
        expect(deepEquals([1], {1}), isFalse); // List vs Set
        expect(deepEquals([1], 1), isFalse);
        expect(deepEquals('true', true), isFalse);
      });

      test('num equality behaves like Dart == for int and double', () {
        expect(deepEquals(1, 1.0), isTrue); // In Dart, 1 == 1.0
        expect(deepEquals(1, 2.0), isFalse);
      });
    });

    group('lists', () {
      test('empty lists are equal', () {
        expect(deepEquals([], []), isTrue);
      });

      test('lists with identical values in same order are equal', () {
        expect(deepEquals([1, 2, 3], [1, 2, 3]), isTrue);
        expect(deepEquals([440.0, 880.0], [440.0, 880.0]), isTrue);
        expect(deepEquals(['a', 'b'], ['a', 'b']), isTrue);
      });

      test('lists with different values are not equal', () {
        expect(deepEquals([1, 2, 3], [1, 2, 4]), isFalse);
        expect(deepEquals([440.0], [441.0]), isFalse);
      });

      test('lists with different order are not equal', () {
        expect(deepEquals([1, 2, 3], [3, 2, 1]), isFalse);
      });

      test('lists with different lengths are not equal', () {
        expect(deepEquals([1, 2], [1, 2, 3]), isFalse);
        expect(deepEquals([1, 2, 3], [1, 2]), isFalse);
      });

      test('nested lists are deeply compared', () {
        final a = [
          [1, 2],
          [3, 4],
        ];
        final b = [
          [1, 2],
          [3, 4],
        ];
        final c = [
          [1, 2],
          [3, 5],
        ];

        expect(deepEquals(a, b), isTrue);
        expect(deepEquals(a, c), isFalse);
      });
    });

    group('sets', () {
      test('empty sets are equal', () {
        expect(deepEquals(<int>{}, <int>{}), isTrue);
      });

      test('sets with same elements in any order are equal', () {
        expect(deepEquals({1, 2, 3}, {3, 2, 1}), isTrue);
        expect(deepEquals({'a', 'b'}, {'b', 'a'}), isTrue);
      });

      test('sets with different elements are not equal', () {
        expect(deepEquals({1, 2}, {1, 3}), isFalse);
      });

      test('sets with different lengths are not equal', () {
        expect(deepEquals({1, 2}, {1, 2, 3}), isFalse);
      });
    });

    group('maps', () {
      test('empty maps are equal', () {
        expect(deepEquals({}, {}), isTrue);
      });

      test('maps with same key-value pairs in any order are equal', () {
        expect(deepEquals({'a': 1, 'b': 2}, {'b': 2, 'a': 1}), isTrue);
      });

      test('maps with different values are not equal', () {
        expect(deepEquals({'a': 1}, {'a': 2}), isFalse);
      });

      test('maps with missing keys are not equal', () {
        expect(deepEquals({'a': 1}, {'b': 1}), isFalse);
        expect(deepEquals({'a': 1}, {'a': 1, 'b': 2}), isFalse);
      });

      test('nested maps and lists within maps are deeply compared', () {
        final a = {
          'frequencies': [440.0, 554.37, 659.25],
          'config': {'q': 45.0, 'enabled': true},
        };
        final b = {
          'frequencies': [440.0, 554.37, 659.25],
          'config': {'q': 45.0, 'enabled': true},
        };
        final c = {
          'frequencies': [440.0, 554.37, 659.0], // modified
          'config': {'q': 45.0, 'enabled': true},
        };

        expect(deepEquals(a, b), isTrue);
        expect(deepEquals(a, c), isFalse);
      });
    });

    group('property list comparisons (fixedProps & dynamicProps)', () {
      test('typical fixedProps comparison', () {
        // e.g. [maxDelay, numChannels, arguments]
        final oldProps = [
          0.5,
          2,
          ['-q', '-d'],
        ];
        final newPropsIdentical = [
          0.5,
          2,
          ['-q', '-d'],
        ];
        final newPropsChanged = [
          1.0,
          2,
          ['-q', '-d'],
        ];
        final newPropsArgsChanged = [
          0.5,
          2,
          ['-q', '-i', 'mic'],
        ];

        expect(deepEquals(oldProps, newPropsIdentical), isTrue);
        expect(deepEquals(oldProps, newPropsChanged), isFalse);
        expect(deepEquals(oldProps, newPropsArgsChanged), isFalse);
      });

      test('typical dynamicProps comparison with lists and nulls', () {
        // e.g. [frequencies, gain, cutoff, null]
        final oldProps = [
          [440.0, 880.0],
          0.8,
          null,
        ];
        final newPropsIdentical = [
          [440.0, 880.0],
          0.8,
          null,
        ];
        final newPropsFreqChanged = [
          [440.0, 882.0],
          0.8,
          null,
        ];
        final newPropsNullFilled = [
          [440.0, 880.0],
          0.8,
          1000.0,
        ];

        expect(deepEquals(oldProps, newPropsIdentical), isTrue);
        expect(deepEquals(oldProps, newPropsFreqChanged), isFalse);
        expect(deepEquals(oldProps, newPropsNullFilled), isFalse);
      });
    });

    group('records', () {
      test('positional records with primitives are equal', () {
        expect(deepEquals((1, 2.0, 'a'), (1, 2.0, 'a')), isTrue);
        expect(deepEquals((1, 2.0, 'a'), (1, 2.5, 'a')), isFalse);
        expect(deepEquals((1, 2.0), (1, 2.0, 3)), isFalse);
      });

      test('named records (like param objects) are equal by field values', () {
        expect(
          deepEquals(
            (cutoff: 440.0, resonance: 0.7),
            (cutoff: 440.0, resonance: 0.7),
          ),
          isTrue,
        );
        expect(
          deepEquals(
            (cutoff: 440.0, resonance: 0.7),
            (
              resonance: 0.7,
              cutoff: 440.0,
            ), // field order in named records doesn't matter
          ),
          isTrue,
        );
        expect(
          deepEquals(
            (cutoff: 440.0, resonance: 0.7),
            (cutoff: 880.0, resonance: 0.7),
          ),
          isFalse,
        );
      });

      test('records inside props lists are compared', () {
        final listA = [
          (cutoff: 440.0, resonance: 0.7),
          true,
        ];
        final listB = [
          (cutoff: 440.0, resonance: 0.7),
          true,
        ];
        final listC = [
          (cutoff: 440.0, resonance: 0.8),
          true,
        ];

        expect(deepEquals(listA, listB), isTrue);
        expect(deepEquals(listA, listC), isFalse);
      });

      test('records containing collections use reference equality for the collections', () {
        // Because Dart records evaluate field equality via field1 == field2,
        // and List == List is reference equality in Dart, records containing
        // non-identical list instances return false.
        final r1 = (items: [1, 2]);
        final r2 = (items: [1, 2]);
        expect(deepEquals(r1, r2), isFalse);

        // But identical instances work:
        final sharedList = [1, 2];
        final r3 = (items: sharedList);
        final r4 = (items: sharedList);
        expect(deepEquals(r3, r4), isTrue);
      });
    });
  });
}
