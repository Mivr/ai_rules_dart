// Package dart implements a Gazelle language extension for Dart.
//
// It generates dart_library, dart_binary, and dart_test BUILD targets
// from Dart source files by parsing import statements and applying
// Dart package conventions.
package dart

import (
	"flag"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

const dartName = "dart"

// dartLang implements language.Language for Dart.
type dartLang struct {
	analysis analysisState
	// factsFlag is -dart_build_runner_facts: a builders.json to read instead
	// of the hub's in the runfiles.
	factsFlag string
	// facts caches each hub's builder facts for the run.
	facts map[string]*factsResult
}

// NewLanguage creates a new Dart language extension for Gazelle.
func NewLanguage() language.Language {
	return &dartLang{}
}

func (*dartLang) Name() string { return dartName }

func (d *dartLang) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {
	fs.StringVar(&d.factsFlag, "dart_build_runner_facts", "",
		"builder facts (a pub hub's build_runner/builders.json) to read instead of the hub's in the runfiles; "+
			"relative to the repository root")
}
func (*dartLang) CheckFlags(fs *flag.FlagSet, c *config.Config) error { return nil }

func (*dartLang) KnownDirectives() []string {
	return []string{
		"dart_package_name",
		"dart_pub_deps_repo",
		buildRunnerDirective,
	}
}

func (*dartLang) Configure(c *config.Config, rel string, f *rule.File) {
	if f == nil {
		return
	}
	for _, d := range f.Directives {
		switch d.Key {
		case "dart_package_name":
			// Store custom package name override in config
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts["dart_package_name"] = d.Value
		case "dart_pub_deps_repo":
			// Store pub deps repository name for external dep labels
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts["dart_pub_deps_repo"] = d.Value
		case buildRunnerDirective:
			// The hub whose builders apply here, or "off".
			if c.Exts == nil {
				c.Exts = make(map[string]interface{})
			}
			c.Exts[buildRunnerDirective] = strings.TrimSpace(d.Value)
		}
	}
}

func (*dartLang) Kinds() map[string]rule.KindInfo {
	return dartKinds
}

func (*dartLang) Loads() []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_dart//dart:defs.bzl",
			Symbols: []string{"dart_library", "dart_binary", "dart_test", "dart_build_runner", "dart_analysis_options", "dart_analysis_config"},
		},
	}
}

func (*dartLang) ApparentLoads(moduleToApparentName func(string) string) []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_dart//dart:defs.bzl",
			Symbols: []string{"dart_library", "dart_binary", "dart_test", "dart_build_runner", "dart_analysis_options", "dart_analysis_config"},
		},
	}
}

func (*dartLang) Fix(c *config.Config, f *rule.File) {}
