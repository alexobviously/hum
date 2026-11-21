import 'package:flutter_test/flutter_test.dart';
import 'package:hum_flutter_example/main.dart';

void main() {
  testWidgets('renders step sequencer grid and play button', (tester) async {
    await tester.pumpWidget(const HumSequencerApp());

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Key'), findsOneWidget);
    expect(find.text('Scale'), findsOneWidget);
    expect(find.text('A4'), findsWidgets);
    expect(find.text('Tempo'), findsOneWidget);
  });
}
