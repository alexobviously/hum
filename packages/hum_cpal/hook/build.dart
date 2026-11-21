import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // This is necessary to not try to `cargo build` for web builds.
    if (!input.config.buildCodeAssets) return;

    await RustBuilder(
      assetName: 'src/cpal_bindings.dart',
    ).run(input: input, output: output);
  });
}
