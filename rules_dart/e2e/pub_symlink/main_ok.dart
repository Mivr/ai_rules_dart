import "package:ok_clean/ok.dart" as clean;
import "package:ok_inlink/a.dart" as inlink_a;
import "package:ok_inlink/b.dart" as inlink_b;

void main() {
  if (clean.ok != "ok" || inlink_a.ok != "ok" || inlink_b.ok != "ok") {
    throw "unexpected package contents";
  }
}
