package dart

// Code generation: one `dart_build_runner` per Dart package whose lock has
// `build_runner` builders, with the generated files it builds as `outs` and
// those files in the sources of the rules that use them.
//
// Gazelle does not read `build.yaml`. The pub hub writes the builder
// definitions of its lock as JSON (`@<hub>//build_runner:builders.json`, made
// by `package:build_config`), and Gazelle reads that file through the runfiles
// of the `gazelle` target, or from `-dart_build_runner_facts`.
//
// Which files to declare (see predictOutputs): a file is an output when a Dart
// source of the package names it (`part`, `import` or `export`) and a builder
// of the lock that writes to the source tree (`build_to: source`) writes it,
// by its `build_extensions`, for a file of the package. Gazelle cannot run the
// builders, so it cannot know whether a builder actually writes a file; it
// relies on the source naming it. A declared file no builder writes fails the
// `dart_build_runner` action with a message naming the file.

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
	"github.com/bazelbuild/bazel-gazelle/walk"
	"github.com/bazelbuild/rules_go/go/runfiles"
)

const (
	// `# gazelle:dart_build_runner <hub>` names the pub hub whose builders
	// apply; `# gazelle:dart_build_runner off` stops code generation here and
	// below.
	buildRunnerDirective = "dart_build_runner"
	buildRunnerOff       = "off"
	defaultHub           = "pub_deps"
	buildRunnerKind      = "dart_build_runner"

	// The file the hub writes, relative to the hub's root.
	factsPath = "build_runner/builders.json"
)

// The directories of a Dart package whose files one `dart_build_runner`
// builds for, and whose rules Gazelle then writes in the package's own BUILD
// file: a generated file must be declared in the Bazel package that builds
// it, so these directories cannot be Bazel packages of their own.
var codegenDirs = []string{"lib", "bin", "test"}

// builderFacts is the hub's `builders.json` (written by `gen_entry --facts`).
type builderFacts struct {
	Version  int          `json:"version"`
	Builders []builderDef `json:"builders"`
	Error    string       `json:"error"`
}

type builderDef struct {
	Key             string              `json:"key"`
	Package         string              `json:"package"`
	AutoApply       string              `json:"auto_apply"`
	BuildTo         string              `json:"build_to"`
	BuildExtensions map[string][]string `json:"build_extensions"`
	AppliesBuilders []string            `json:"applies_builders"`
}

// codegen is what Gazelle uses of a hub's facts.
type codegen struct {
	hub string
	// The `build_extensions` of every builder that writes to the source tree.
	// A builder with `auto_apply: none` counts: the package's `build.yaml`,
	// which Gazelle does not read, may enable it.
	extensions []buildExtension
}

type factsResult struct {
	cg  *codegen
	err error
}

// buildRunnerSetting returns the hub of the directory's code generation, "" when
// it is switched off, and whether a directive names it.
func buildRunnerSetting(c *config.Config) (hub string, explicit bool) {
	if c.Exts != nil {
		if v, ok := c.Exts[buildRunnerDirective].(string); ok && v != "" {
			if v == buildRunnerOff {
				return "", true
			}
			return v, true
		}
		if v, ok := c.Exts["dart_pub_deps_repo"].(string); ok && v != "" {
			return v, false
		}
	}
	return defaultHub, false
}

// codegenFor returns the code generation facts that apply to the directory, or
// nil when there are none: switched off, no facts file, or no builder that
// writes to the source tree.
func (d *dartLang) codegenFor(c *config.Config) *codegen {
	hub, explicit := buildRunnerSetting(c)
	if hub == "" {
		return nil
	}
	if d.facts == nil {
		d.facts = map[string]*factsResult{}
	}
	res, ok := d.facts[hub]
	if !ok {
		res = &factsResult{}
		res.cg, res.err = d.loadCodegen(c, hub)
		d.facts[hub] = res
		if res.err != nil && explicit {
			log.Printf("dart: %v; Gazelle writes no dart_build_runner for hub %q", res.err, hub)
		}
	}
	return res.cg
}

func (d *dartLang) loadCodegen(c *config.Config, hub string) (*codegen, error) {
	var file string
	if d.factsFlag != "" {
		file = d.factsFlag
		if !filepath.IsAbs(file) {
			file = filepath.Join(c.RepoRoot, file)
		}
	} else {
		// The main repository's mapping turns the hub's apparent name into
		// its runfiles directory.
		p, err := runfiles.RlocationFrom(hub+"/"+factsPath, "")
		if err != nil {
			return nil, fmt.Errorf("cannot find @%s//%s in the runfiles of the gazelle target (add it to the target's `data`): %v", hub, strings.Replace(factsPath, "/", ":", 1), err)
		}
		file = p
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, fmt.Errorf("cannot read the builder facts of hub %q: %v", hub, err)
	}
	var facts builderFacts
	if err := json.Unmarshal(data, &facts); err != nil {
		return nil, fmt.Errorf("%s: %v", file, err)
	}
	if facts.Version != 1 {
		return nil, fmt.Errorf("%s: version %d of the builder facts is not one this Gazelle reads (1)", file, facts.Version)
	}
	if facts.Error != "" {
		return nil, fmt.Errorf("hub %q: %s", hub, facts.Error)
	}
	cg := &codegen{hub: hub}
	for _, b := range facts.Builders {
		if b.BuildTo != "source" {
			continue
		}
		inputs := make([]string, 0, len(b.BuildExtensions))
		for in := range b.BuildExtensions {
			inputs = append(inputs, in)
		}
		sort.Strings(inputs)
		for _, in := range inputs {
			if ext, ok := parseBuildExtension(in, b.BuildExtensions[in]); ok {
				cg.extensions = append(cg.extensions, ext)
			}
		}
	}
	if len(cg.extensions) == 0 {
		return nil, nil
	}
	return cg, nil
}

// dartPackageRoot returns the workspace-relative directory of the nearest
// `pubspec.yaml` at or above rel.
func dartPackageRoot(repoRoot, rel string) (string, bool) {
	current := rel
	for {
		if _, err := os.Stat(filepath.Join(repoRoot, filepath.FromSlash(current), "pubspec.yaml")); err == nil {
			return current, true
		}
		if current == "" {
			return "", false
		}
		current = path.Dir(current)
		if current == "." {
			current = ""
		}
	}
}

// codegenScope says where rel stands relative to the Dart package at root: the
// first directory below root, and whether a BUILD file splits off rel or one of
// its ancestors below root.
func codegenScope(root, rel string) (top string, inside bool) {
	sub := rel
	if root != "" {
		if !strings.HasPrefix(rel, root+"/") {
			return "", false
		}
		sub = rel[len(root)+1:]
	}
	top = strings.SplitN(sub, "/", 2)[0]
	for _, d := range codegenDirs {
		if top == d {
			return top, true
		}
	}
	return top, false
}

// splitBetween reports whether a directory strictly between root and rel has a
// BUILD file (rel's own is checked by the caller).
func splitBetween(root, rel string) bool {
	for p := path.Dir(rel); p != root && p != "." && p != ""; p = path.Dir(p) {
		if info, err := walk.GetDirInfo(p); err == nil && info.File != nil {
			return true
		}
	}
	return false
}

// generateCodegenPackage writes the rules of a Dart package whose lock has
// builders: in the package's own directory, every rule for its lib/, bin/ and
// test/ files plus the `dart_build_runner`; in those directories, nothing. It
// returns false for a directory it does not handle, which then gets the
// per-directory rules.
func (d *dartLang) generateCodegenPackage(args language.GenerateArgs) (language.GenerateResult, bool) {
	root, ok := dartPackageRoot(args.Config.RepoRoot, args.Rel)
	if !ok {
		return language.GenerateResult{}, false
	}
	cg := d.codegenFor(args.Config)
	if cg == nil {
		return language.GenerateResult{}, false
	}
	if args.Rel != root {
		if _, inside := codegenScope(root, args.Rel); !inside || args.File != nil || splitBetween(root, args.Rel) {
			return language.GenerateResult{}, false
		}
		// The package's own BUILD file holds this directory's rules.
		return language.GenerateResult{}, true
	}
	pkgName := libraryName(args.Rel, args.Dir, args.Config)
	files, splitDirs := scanPackage(args)
	return codegenRules(args, cg, pkgName, files, splitDirs), true
}

// scannedFile is one file of a Dart package's lib/, bin/ or test/.
type scannedFile struct {
	Path    string // relative to the package root
	Split   bool   // in a directory with its own BUILD file
	Dart    bool
	Imports []DartImport
	Parts   []string
}

// scanPackage lists the files of the package's lib/, bin/ and test/ trees,
// with what Gazelle's walk excludes left out, and parses the Dart files. A
// nested Dart package (a directory with its own pubspec.yaml) is not scanned.
func scanPackage(args language.GenerateArgs) ([]scannedFile, map[string]bool) {
	var files []scannedFile
	splitDirs := map[string]bool{}
	subdirs := map[string]bool{}
	for _, s := range args.Subdirs {
		subdirs[s] = true
	}
	var visit func(rel, pkgRel string, split bool)
	visit = func(rel, pkgRel string, split bool) {
		info, err := walk.GetDirInfo(rel)
		if err != nil {
			return
		}
		if info.File != nil {
			split = true
			splitDirs[pkgRel] = true
		}
		for _, f := range info.RegularFiles {
			if f == "pubspec.yaml" {
				return
			}
		}
		for _, f := range info.RegularFiles {
			sf := scannedFile{Path: path.Join(pkgRel, f), Split: split}
			if strings.HasSuffix(f, ".dart") {
				imports, parts, err := parseDartSource(filepath.Join(args.Config.RepoRoot, filepath.FromSlash(rel), f))
				if err == nil {
					sf.Dart = true
					sf.Imports = imports
					sf.Parts = parts
				}
			}
			files = append(files, sf)
		}
		for _, s := range info.Subdirs {
			visit(path.Join(rel, s), path.Join(pkgRel, s), split)
		}
	}
	for _, d := range codegenDirs {
		if subdirs[d] {
			visit(path.Join(args.Rel, d), d, false)
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return files, splitDirs
}

// references returns the package-relative paths a Dart file names by `part`,
// `import` or `export`: relative URIs and `package:<pkgName>/` URIs. Names
// that leave the package are dropped.
func references(f scannedFile, pkgName string) []string {
	var refs []string
	add := func(p string) {
		if p != "" && p != "." && !strings.HasPrefix(p, "../") {
			refs = append(refs, p)
		}
	}
	resolve := func(uri string) {
		switch {
		case strings.HasPrefix(uri, "package:"):
			rest := strings.TrimPrefix(uri, "package:")
			if parts := strings.SplitN(rest, "/", 2); len(parts) == 2 && parts[0] == pkgName {
				add(path.Join("lib", parts[1]))
			}
		case strings.Contains(uri, ":"):
			// dart:, and absolute URIs.
		default:
			add(path.Join(path.Dir(f.Path), uri))
		}
	}
	for _, p := range f.Parts {
		resolve(p)
	}
	for _, imp := range f.Imports {
		resolve(imp.URI)
	}
	return refs
}

// syntheticInputs are the placeholder inputs build_runner gives builders that
// read a whole package or its lib/ (`$package$`, `$lib$`).
var syntheticInputs = [2]string{"$package$", "lib/$lib$"}

// prediction is what predictOutputs found for a package.
type prediction struct {
	// outs are the files the package's dart_build_runner declares.
	outs []string
	// claimed are files the package's sources name that other rules of the
	// BUILD file declare: they go in sources too, but not in outs.
	claimed []string
	// unreachable are files a builder would write in a directory that has a
	// BUILD file of its own, which the package's BUILD file cannot declare.
	unreachable []string
}

// predictOutputs returns the generated files to declare for a package: files
// that a source of the package names (by `part`, `import` or `export`) and
// that a builder writes, by its `build_extensions`, for a file of the package.
// claimed holds the outputs of the BUILD file's other rules.
func predictOutputs(pkgName string, files []scannedFile, splitDirs map[string]bool, extensions []buildExtension, claimed map[string]bool) prediction {
	// What a builder writes for the files the package's BUILD file owns, and
	// for every file of the package.
	producible := map[string]bool{}
	anywhere := map[string]bool{}
	inputs := append([]scannedFile{}, scannedFile{Path: syntheticInputs[0]}, scannedFile{Path: syntheticInputs[1]})
	inputs = append(inputs, files...)
	for _, in := range inputs {
		for _, e := range extensions {
			for _, o := range e.outputsFor(in.Path) {
				anywhere[o] = true
				if !in.Split {
					producible[o] = true
				}
			}
		}
	}
	var p prediction
	seen := map[string]bool{}
	for _, f := range files {
		if !f.Dart {
			continue
		}
		for _, ref := range references(f, pkgName) {
			if seen[ref] {
				continue
			}
			if _, inside := codegenScope("", ref); !inside {
				continue
			}
			seen[ref] = true
			switch {
			case inSplitDir(ref, splitDirs):
				if anywhere[ref] && !claimed[ref] {
					p.unreachable = append(p.unreachable, ref)
				}
			case claimed[ref]:
				p.claimed = append(p.claimed, ref)
			case producible[ref]:
				p.outs = append(p.outs, ref)
			}
		}
	}
	sort.Strings(p.outs)
	sort.Strings(p.claimed)
	sort.Strings(p.unreachable)
	return p
}

func inSplitDir(p string, splitDirs map[string]bool) bool {
	return splitDirOf(p, splitDirs) != ""
}

// splitDirOf returns the outermost directory above p that has a BUILD file.
func splitDirOf(p string, splitDirs map[string]bool) string {
	found := ""
	for d := path.Dir(p); d != "." && d != ""; d = path.Dir(d) {
		if splitDirs[d] {
			found = d
		}
	}
	return found
}

// claimedOutputs returns the files other rules of the BUILD file declare as
// outputs (`out`, `outs`): a generator of the user's own writes them.
func claimedOutputs(f *rule.File) map[string]bool {
	claimed := map[string]bool{}
	if f == nil {
		return claimed
	}
	for _, r := range f.Rules {
		if r.Kind() == buildRunnerKind {
			continue
		}
		if o := r.AttrString("out"); o != "" {
			claimed[o] = true
		}
		for _, o := range r.AttrStrings("outs") {
			claimed[o] = true
		}
	}
	return claimed
}

// codegenRules writes the rules of a Dart package in its own directory.
func codegenRules(args language.GenerateArgs, cg *codegen, pkgName string, files []scannedFile, splitDirs map[string]bool) language.GenerateResult {
	pred := predictOutputs(pkgName, files, splitDirs, cg.extensions, claimedOutputs(args.File))
	for _, u := range pred.unreachable {
		log.Printf("dart: %s: %s is generated, but %s has a BUILD file, so the Dart package's dart_build_runner "+
			"in %s cannot declare it. Delete that BUILD file to let Gazelle write the package's rules in %s.",
			rootLabel(args.Rel), u, splitDirOf(u, splitDirs), rootLabel(args.Rel), rootLabel(args.Rel))
	}
	outs := pred.outs
	// Generated files the sources name, whoever writes them: in sources as
	// labels, never as the checked-in copy.
	outSet := map[string]bool{}
	for _, o := range append(append([]string{}, outs...), pred.claimed...) {
		outSet[o] = true
	}
	byPath := map[string]scannedFile{}
	for _, f := range files {
		byPath[f.Path] = f
	}

	var res language.GenerateResult
	// The dart_build_runner reads the whole package: its deps are what any
	// of the package's files imports.
	all := newImportSet(pkgName)
	for _, f := range files {
		if !f.Split && f.Dart {
			all.add(f)
		}
	}

	// The library: every Dart file under lib/, with the generated ones as
	// outputs of the dart_build_runner (a checked-in copy is not a source,
	// but what it imports counts).
	var libSrcs []string
	libImports := newImportSet(pkgName)
	for _, f := range files {
		if f.Split || !f.Dart || !strings.HasPrefix(f.Path, "lib/") {
			continue
		}
		libImports.add(f)
		if !outSet[f.Path] {
			libSrcs = append(libSrcs, f.Path)
		}
	}
	for o := range outSet {
		if strings.HasPrefix(o, "lib/") {
			libSrcs = append(libSrcs, ":"+o)
		}
	}
	if len(libSrcs) > 0 {
		sort.Strings(libSrcs)
		r := rule.NewRule("dart_library", pkgName)
		r.SetAttr("srcs", libSrcs)
		r.SetAttr("package_name", pkgName)
		r.SetAttr("visibility", []string{"//visibility:public"})
		res.Gen = append(res.Gen, r)
		res.Imports = append(res.Imports, libImports)
	}

	// Binaries: each file directly in bin/, with the bin/ files it reaches.
	// Tests: each test/**_test.dart, with the test/ helpers it reaches.
	for _, f := range files {
		if f.Split || !f.Dart || outSet[f.Path] || !isMain(f.Path) {
			continue
		}
		kind, name, scope := "dart_binary", strings.TrimSuffix(path.Base(f.Path), ".dart"), "bin/"
		if strings.HasPrefix(f.Path, "test/") {
			kind, name, scope = "dart_test", strings.TrimSuffix(strings.TrimPrefix(f.Path, "test/"), ".dart"), "test/"
		}
		if name == pkgName {
			// `bin/<package>.dart` is common; the library has the name.
			name += "_" + strings.TrimSuffix(scope, "/")
		}
		srcs, imports := reach(f, scope, pkgName, byPath, outSet)
		r := rule.NewRule(kind, name)
		r.SetAttr("main", f.Path)
		if len(srcs) > 0 {
			r.SetAttr("srcs", srcs)
		}
		res.Gen = append(res.Gen, r)
		res.Imports = append(res.Imports, imports)
	}

	existing := ""
	taken := map[string]bool{}
	if args.File != nil {
		for _, r := range args.File.Rules {
			if r.Kind() == buildRunnerKind && existing == "" {
				existing = r.Name()
			} else {
				taken[r.Name()] = true
			}
		}
	}
	for _, r := range res.Gen {
		taken[r.Name()] = true
	}
	name := existing
	if name == "" {
		name = "gen"
		if taken[name] {
			name = pkgName + "_gen"
		}
	}
	if len(outs) > 0 {
		r := rule.NewRule(buildRunnerKind, name)
		r.SetAttr("outs", outs)
		r.SetAttr("runner", "@"+cg.hub+"//build_runner")
		res.Gen = append(res.Gen, r)
		res.Imports = append(res.Imports, all)
	} else if existing != "" {
		res.Empty = append(res.Empty, rule.NewRule(buildRunnerKind, existing))
	}
	return res
}

// reach returns the sources a binary or test needs besides its main: the
// files under scope it reaches by relative or package-relative names (not
// other mains), and the generated files any of them names. It also returns
// the imports of all of them.
func reach(main scannedFile, scope, pkgName string, byPath map[string]scannedFile, outSet map[string]bool) ([]string, *importSet) {
	imports := newImportSet("")
	seen := map[string]bool{main.Path: true}
	var srcs []string
	queue := []scannedFile{main}
	for len(queue) > 0 {
		f := queue[0]
		queue = queue[1:]
		imports.add(f)
		for _, ref := range references(f, pkgName) {
			if seen[ref] || !strings.HasPrefix(ref, scope) {
				continue
			}
			seen[ref] = true
			g, onDisk := byPath[ref]
			switch {
			case outSet[ref]:
				srcs = append(srcs, ":"+ref)
				if onDisk && g.Dart {
					queue = append(queue, g)
				}
			case onDisk && g.Dart && !g.Split && !isMain(ref):
				srcs = append(srcs, ref)
				queue = append(queue, g)
			}
		}
	}
	sort.Strings(srcs)
	return srcs, imports
}

func rootLabel(rel string) string {
	if rel == "" {
		return "."
	}
	return rel
}

func isMain(p string) bool {
	return path.Dir(p) == "bin" || (strings.HasPrefix(p, "test/") && strings.HasSuffix(p, "_test.dart"))
}
