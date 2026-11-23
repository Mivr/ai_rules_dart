package dart

import (
	"reflect"
	"testing"
)

func mustExt(t *testing.T, in string, outs ...string) buildExtension {
	t.Helper()
	e, ok := parseBuildExtension(in, outs)
	if !ok {
		t.Fatalf("parseBuildExtension(%q, %q) refused", in, outs)
	}
	return e
}

func TestBuildExtensionOutputs(t *testing.T) {
	tests := []struct {
		name  string
		in    string
		outs  []string
		input string
		want  []string
	}{
		{"suffix", ".dart", []string{".g.dart"}, "lib/src/user.dart", []string{"lib/src/user.g.dart"}},
		{"suffix two outputs", ".dart", []string{".config.dart", ".module.dart"}, "lib/di.dart", []string{"lib/di.config.dart", "lib/di.module.dart"}},
		{"suffix no match", ".drift", []string{".drift.dart"}, "lib/db.dart", nil},
		{"suffix without dot", ".dart", []string{"json_serializable.g.part"}, "lib/a.dart", []string{"lib/ajson_serializable.g.part"}},
		{"full path", "^lib/app.dart", []string{"lib/app.routes.dart"}, "lib/app.dart", []string{"lib/app.routes.dart"}},
		{"full path elsewhere", "^lib/app.dart", []string{"lib/app.routes.dart"}, "lib/src/app.dart", nil},
		{"anchored capture", "^test/{{}}.dart", []string{"test/mocks/{{}}.mocks.dart"}, "test/a/b_test.dart", []string{"test/mocks/a/b_test.mocks.dart"}},
		{"anchored capture misses", "^test/{{}}.dart", []string{"test/mocks/{{}}.mocks.dart"}, "lib/a.dart", nil},
		{"unanchored capture", "{{}}.dart", []string{"generated/{{}}.g.dart"}, "lib/a.dart", []string{"generated/lib/a.g.dart"}},
		{"named captures", "^lib/{{dir}}/{{file}}.dart", []string{"lib/{{dir}}/gen/{{file}}.g.dart"}, "lib/models/user.dart", []string{"lib/models/gen/user.g.dart"}},
		{"synthetic lib", "$lib$", []string{"all.dart"}, "lib/$lib$", []string{"lib/all.dart"}},
		{"synthetic package", "$package$", []string{"lib/all.dart"}, "$package$", []string{"lib/all.dart"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mustExt(t, tt.in, tt.outs...).outputsFor(tt.input)
			if len(got) == 0 && len(tt.want) == 0 {
				return
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("outputsFor(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestBuildExtensionRefused(t *testing.T) {
	for _, c := range []struct {
		in   string
		outs []string
	}{
		{".dart", []string{"{{}}.g.dart"}},
		{"{{}}.dart", []string{"x.g.dart"}},
		{"{{a}}/{{a}}.dart", []string{"{{a}}.g.dart"}},
	} {
		if _, ok := parseBuildExtension(c.in, c.outs); ok {
			t.Errorf("parseBuildExtension(%q, %q) accepted an entry build refuses", c.in, c.outs)
		}
	}
}

// The source-tree extensions of the builders S10 measures, as their
// build.yaml declare them: source_gen's combining builder (the `.g.dart` of
// json_serializable, built_value, drift, retrofit, riverpod and go_router),
// freezed, mockito, injectable, and drift's builders that only a build.yaml
// enables.
func nineBuilders(t *testing.T) []buildExtension {
	return []buildExtension{
		mustExt(t, ".dart", ".g.dart"),
		mustExt(t, ".dart", ".freezed.dart"),
		mustExt(t, ".dart", ".mocks.dart"),
		mustExt(t, ".dart", ".config.dart", ".module.dart"),
		mustExt(t, ".dart", ".drift.dart"),
		mustExt(t, ".drift", ".drift.dart"),
	}
}

func dart(p string, imports []string, parts ...string) scannedFile {
	f := scannedFile{Path: p, Dart: true, Parts: parts}
	for _, i := range imports {
		f.Imports = append(f.Imports, classifyURI(i))
	}
	return f
}

func TestPredictOutputs(t *testing.T) {
	files := []scannedFile{
		dart("lib/app.dart", []string{"package:app/src/models.dart", "di.config.dart"}),
		dart("lib/di.dart", []string{"package:injectable/injectable.dart"}),
		// Names the config of a file that does not exist.
		dart("lib/none.dart", []string{"absent.config.dart"}),
		dart("lib/src/models.dart", []string{"package:freezed_annotation/freezed_annotation.dart"}, "models.freezed.dart", "models.g.dart"),
		// Checked in: still an output, never a source.
		dart("lib/src/models.g.dart", nil),
		// A part no builder can write: a hand-written one that exists.
		dart("lib/src/raw.dart", nil, "raw.part.dart"),
		dart("lib/src/raw.part.dart", nil),
		// A part naming a file whose source does not exist.
		dart("lib/src/ghost.dart", nil, "../ghost.g.dart"),
		// An import of a file of another package, and one leaving the package.
		dart("lib/src/other.dart", []string{"package:other/other.g.dart", "../../outside.g.dart"}),
		{Path: "lib/db/tables.drift"},
		dart("lib/db/db.dart", []string{"tables.drift.dart"}, "db.g.dart"),
		dart("test/store_test.dart", []string{"package:app/app.dart", "store_test.mocks.dart"}),
		// Its own Bazel package: its output cannot be declared here.
		{Path: "lib/l10n/strings.dart", Dart: true, Split: true, Parts: []string{"strings.g.dart"}},
		// Another rule of the BUILD file writes it.
		dart("lib/src/message.dart", nil, "message.g.dart"),
	}
	claimed := map[string]bool{"lib/src/message.g.dart": true}
	p := predictOutputs("app", files, map[string]bool{"lib/l10n": true}, nineBuilders(t), claimed)
	want := []string{
		"lib/db/db.g.dart",
		"lib/db/tables.drift.dart",
		"lib/di.config.dart",
		"lib/src/models.freezed.dart",
		"lib/src/models.g.dart",
		"test/store_test.mocks.dart",
	}
	if !reflect.DeepEqual(p.outs, want) {
		t.Errorf("outs = %q, want %q", p.outs, want)
	}
	if want := []string{"lib/src/message.g.dart"}; !reflect.DeepEqual(p.claimed, want) {
		t.Errorf("claimed = %q, want %q", p.claimed, want)
	}
	// lib/l10n has its own BUILD file: the package's BUILD file cannot
	// declare what a builder writes there.
	if want := []string{"lib/l10n/strings.g.dart"}; !reflect.DeepEqual(p.unreachable, want) {
		t.Errorf("unreachable = %q, want %q", p.unreachable, want)
	}
}

func TestPredictOutputsInSplitDirectory(t *testing.T) {
	// A BUILD file left in lib/ by a per-directory layout: what lib/ files
	// name cannot be declared next to the pubspec.
	files := []scannedFile{
		{Path: "lib/user.dart", Dart: true, Split: true, Parts: []string{"user.g.dart"}},
		dart("test/user_test.dart", []string{"package:app/user.dart"}),
	}
	p := predictOutputs("app", files, map[string]bool{"lib": true}, nineBuilders(t), nil)
	if len(p.outs) != 0 || !reflect.DeepEqual(p.unreachable, []string{"lib/user.g.dart"}) {
		t.Errorf("outs = %q, unreachable = %q, want lib/user.g.dart unreachable", p.outs, p.unreachable)
	}
	if got := splitDirOf("lib/src/a/b.dart", map[string]bool{"lib": true, "lib/src": true}); got != "lib" {
		t.Errorf("splitDirOf = %q, want lib", got)
	}
}

func TestReferences(t *testing.T) {
	f := dart("lib/src/a.dart", []string{"dart:async", "package:app/b.dart", "package:other/c.dart", "../d.dart", "e.dart", "../../../f.dart"}, "a.g.dart")
	got := references(f, "app")
	want := []string{"lib/src/a.g.dart", "lib/b.dart", "lib/d.dart", "lib/src/e.dart"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("references = %q, want %q", got, want)
	}
}

func TestReach(t *testing.T) {
	files := []scannedFile{
		dart("test/a_test.dart", []string{"package:app/app.dart", "helpers/fake.dart", "a_test.mocks.dart", "b_test.dart"}),
		dart("test/b_test.dart", nil),
		dart("test/helpers/fake.dart", []string{"package:fake_async/fake_async.dart", "util.dart"}),
		dart("test/helpers/util.dart", nil),
		dart("test/unused.dart", nil),
	}
	byPath := map[string]scannedFile{}
	for _, f := range files {
		byPath[f.Path] = f
	}
	srcs, imports := reach(files[0], "test/", "app", byPath, map[string]bool{"test/a_test.mocks.dart": true})
	want := []string{":test/a_test.mocks.dart", "test/helpers/fake.dart", "test/helpers/util.dart"}
	if !reflect.DeepEqual(srcs, want) {
		t.Errorf("srcs = %q, want %q", srcs, want)
	}
	if got := imports.SortedPackages(); !reflect.DeepEqual(got, []string{"app", "fake_async"}) {
		t.Errorf("imports = %q", got)
	}
}
