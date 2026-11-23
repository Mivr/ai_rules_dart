package dart

import (
	"log"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// GenerateRules generates Dart BUILD rules for a directory: the Dart targets,
// then the analysis options targets (analysis_options.go).
func (d *dartLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	res := d.generateDartRules(args)
	taken := map[string]bool{}
	for _, r := range res.Gen {
		taken[r.Name()] = true
	}
	gen, imports, empty := d.analysisRules(args, taken)
	res.Gen = append(res.Gen, gen...)
	res.Imports = append(res.Imports, imports...)
	res.Empty = append(res.Empty, empty...)
	return res
}

func (d *dartLang) generateDartRules(args language.GenerateArgs) language.GenerateResult {
	dartFiles, err := ParseDartDir(args.Dir, args.RegularFiles)
	if err != nil || len(dartFiles) == 0 {
		return language.GenerateResult{}
	}

	warnOnPackageNameOverlap(args)

	// Classify files by conventional directory.
	var libFiles, binFiles, testFiles []DartFileInfo
	for _, f := range dartFiles {
		switch {
		case isInDir(args.Rel, "test") || strings.HasSuffix(f.Path, "_test.dart"):
			testFiles = append(testFiles, f)
		case isInDir(args.Rel, "bin"):
			binFiles = append(binFiles, f)
		default:
			libFiles = append(libFiles, f)
		}
	}

	var gen []*rule.Rule
	var imports []interface{}

	if len(libFiles) > 0 {
		r := rule.NewRule("dart_library", libraryName(args.Rel, args.Dir, args.Config))
		srcs := fileNames(libFiles)
		sort.Strings(srcs)
		r.SetAttr("srcs", srcs)
		r.SetAttr("visibility", []string{"//visibility:public"})
		needsPkgName := false
		if args.Config.Exts != nil {
			if _, ok := args.Config.Exts["dart_package_name"].(string); ok {
				needsPkgName = true
			}
		}
		if FindPubspecName(args.Dir, args.Rel) != "" {
			needsPkgName = true
		}
		if needsPkgName {
			r.SetAttr("package_name", r.Name())
		}
		gen = append(gen, r)
		imports = append(imports, collectImports(libFiles))
	}

	for _, f := range binFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_binary", name)
		r.SetAttr("main", f.Path)
		gen = append(gen, r)
		imports = append(imports, collectImports([]DartFileInfo{f}))
	}

	for _, f := range testFiles {
		name := strings.TrimSuffix(f.Path, ".dart")
		r := rule.NewRule("dart_test", name)
		r.SetAttr("main", f.Path)
		gen = append(gen, r)
		imports = append(imports, collectImports([]DartFileInfo{f}))
	}

	return language.GenerateResult{
		Gen:     gen,
		Imports: imports,
	}
}

// packageDeclLabel returns the in-package reference to a hand-written
// `dart_package_metadata` and the package name it declares, or "" when the
// directory has none.
func packageDeclLabel(args language.GenerateArgs) (label string, declaredName string) {
	if args.File == nil {
		return "", ""
	}
	for _, r := range args.File.Rules {
		if r.Kind() == "dart_package_metadata" {
			return ":" + r.Name(), r.AttrString("package_name")
		}
	}
	return "", ""
}

// warnOnPackageNameOverlap reports a `dart_package_metadata` whose declared name differs
// from the one a pubspec or `# gazelle:dart_package_name` directive supplies.
//
// The declaration wins, which leaves the other a value the developer stated and
// nothing acts on — the exact failure `dart_package_metadata` exists to remove, so it is
// not one to reintroduce silently here. Reported once per directory rather than
// once per emitted rule: it is a property of the directory, and four copies of
// one warning trains people to skip all of them.
func warnOnPackageNameOverlap(args language.GenerateArgs) {
	decl, declaredName := packageDeclLabel(args)
	if decl == "" || declaredName == "" {
		return
	}
	derived := libraryName(args.Rel, args.Dir, args.Config)
	if derived == "" || derived == declaredName {
		return
	}
	log.Printf(
		"dart: %s: dart_package_metadata %q declares package_name %q, but this "+
			"directory otherwise resolves to %q. The declaration wins; drop "+
			"the conflicting pubspec name or `# gazelle:dart_package_name` "+
			"directive.",
		args.Rel, decl, declaredName, derived,
	)
}

// libraryName determines the dart_library target name.
func libraryName(rel string, dir string, c *config.Config) string {
	if c.Exts != nil {
		if name, ok := c.Exts["dart_package_name"].(string); ok && name != "" {
			return name
		}
	}
	if name := FindPubspecName(dir, rel); name != "" {
		return name
	}
	if rel == "" {
		return "lib"
	}
	return path.Base(rel)
}

func isInDir(rel string, dir string) bool {
	return rel == dir || strings.HasPrefix(rel, dir+"/")
}

func fileNames(files []DartFileInfo) []string {
	names := make([]string, len(files))
	for i, f := range files {
		names[i] = f.Path
	}
	return names
}

type importSet struct {
	packages map[string]bool
}

func collectImports(files []DartFileInfo) *importSet {
	is := &importSet{packages: make(map[string]bool)}
	for _, f := range files {
		for _, imp := range f.Imports {
			if imp.IsPackage {
				is.packages[imp.Package] = true
			}
		}
	}
	return is
}

func (is *importSet) SortedPackages() []string {
	var pkgs []string
	for p := range is.packages {
		pkgs = append(pkgs, p)
	}
	sort.Strings(pkgs)
	return pkgs
}

func HasDartFiles(files []string) bool {
	for _, f := range files {
		if filepath.Ext(f) == ".dart" {
			return true
		}
	}
	return false
}
