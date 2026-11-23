/// A kernel-mode `dart_binary` with `defines` over `//defines_env`.
library;

import 'package:defines_env/defines_env.dart';

void main() {
  print(defcfgSummary);
}
