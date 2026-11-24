// Entrypoint over the dirlink consumer: a binary (rather than a bare
// library) so the package closure assembles exactly as it would for an app.
import '../lib/dirlink_user.dart';

void main() {
  print(describe());
}
