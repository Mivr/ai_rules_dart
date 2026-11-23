import 'dart:io';

/// Host driver that fails on purpose: exits non-zero and names the failure.
void main() {
  stderr.writeln('DRIVE_RED_MUST_FAIL: this driver exits 1 on purpose');
  exit(1);
}
