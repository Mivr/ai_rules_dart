// File-form probe for the run-home hermeticity gate: the registry row
// `@rules_flutter//dart:dart hello.dart` runs this through the SDK
// pass-through, which must exec it unchanged under a private HOME (the VM
// rejects the analytics flag) and print this line.
void main() {
  print('run-home hello');
}
