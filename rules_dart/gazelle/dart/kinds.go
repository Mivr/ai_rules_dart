package dart

import "github.com/bazelbuild/bazel-gazelle/rule"

var dartKinds = map[string]rule.KindInfo{
	"dart_library": {
		MatchAttrs:    []string{"srcs"},
		NonEmptyAttrs: map[string]bool{"srcs": true},
		MergeableAttrs: map[string]bool{
			"srcs":             true,
			"deps":             true,
			"package_name":     true,
			"language_version": true,
			"package":          true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	"dart_binary": {
		MatchAttrs:    []string{"main"},
		NonEmptyAttrs: map[string]bool{"main": true},
		MergeableAttrs: map[string]bool{
			"srcs": true,
			"deps": true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	"dart_test": {
		MatchAttrs:    []string{"main"},
		NonEmptyAttrs: map[string]bool{"main": true},
		MergeableAttrs: map[string]bool{
			"srcs": true,
			"deps": true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	// One per Dart package whose lock has builders (build_runner.go), in the
	// package's own BUILD file. It matches whatever its name.
	"dart_build_runner": {
		MatchAny:      true,
		NonEmptyAttrs: map[string]bool{"outs": true},
		MergeableAttrs: map[string]bool{
			"outs":   true,
			"deps":   true,
			"runner": true,
		},
		ResolveAttrs: map[string]bool{"deps": true},
	},
	// One per analysis_options.yaml, and the root's list of them. The config
	// matches by name alone: there is one per repository.
	"dart_analysis_options": {
		MatchAttrs:     []string{"src"},
		NonEmptyAttrs:  map[string]bool{"src": true},
		MergeableAttrs: map[string]bool{"src": true, "deps": true},
		ResolveAttrs:   map[string]bool{"deps": true},
	},
	// Never "empty": an empty config is valid (SDK defaults) and `.bazelrc`
	// files name it, so Gazelle must not delete it.
	"dart_analysis_config": {
		MergeableAttrs: map[string]bool{"options": true},
	},
}
