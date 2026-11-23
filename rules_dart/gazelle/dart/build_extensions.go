package dart

import (
	"regexp"
	"strings"
)

// buildExtension is one entry of a builder's `build_extensions`: which
// package files the builder reads and which files it writes for each.
//
// The matching follows `package:build`'s `expectedOutputs`
// (lib/src/expected_outputs.dart), so Gazelle predicts the same output paths
// as build_runner does for the same input:
//
//   - `.dart: [.g.dart]` matches a path ending in `.dart` and replaces that
//     suffix;
//   - `^lib/app.dart: [lib/app.g.dart]` (a leading `^`) matches one whole path
//     and names whole output paths;
//   - `{{}}` and `{{name}}` are capture groups (`.+`) whose text each output
//     repeats, anchored at the package root when the input starts with `^`,
//     and always matching up to the end of the path.
type buildExtension struct {
	kind    extensionKind
	input   string         // the whole input path (fullPath) or its suffix (suffixPath)
	capture *regexp.Regexp // for an input with capture groups
	names   []string       // the capture group names, in the order of capture
	outputs []string
}

type extensionKind int

const (
	suffixPath extensionKind = iota
	fullPath
	capturePath
)

var captureGroupRe = regexp.MustCompile(`{{(\w*)}}`)

// parseBuildExtension parses one `build_extensions` entry. It returns false for
// an entry `package:build` would refuse (an output naming a capture group the
// input lacks, a group named twice); such a builder fails in build_runner too.
func parseBuildExtension(input string, outputs []string) (buildExtension, bool) {
	matches := captureGroupRe.FindAllStringSubmatchIndex(input, -1)
	if len(matches) == 0 {
		for _, o := range outputs {
			if captureGroupRe.MatchString(o) {
				return buildExtension{}, false
			}
		}
		if strings.HasPrefix(input, "^") {
			return buildExtension{kind: fullPath, input: input[1:], outputs: outputs}, true
		}
		return buildExtension{kind: suffixPath, input: input, outputs: outputs}, true
	}
	var re strings.Builder
	pos := 0
	if strings.HasPrefix(input, "^") {
		re.WriteString("^")
		pos = 1
	}
	var names []string
	for _, m := range matches {
		name := input[m[2]:m[3]]
		for _, n := range names {
			if n == name {
				return buildExtension{}, false
			}
		}
		names = append(names, name)
		re.WriteString(regexp.QuoteMeta(input[pos:m[0]]))
		re.WriteString("(.+)")
		pos = m[1]
	}
	re.WriteString(regexp.QuoteMeta(input[pos:]))
	re.WriteString("$")
	compiled, err := regexp.Compile(re.String())
	if err != nil {
		return buildExtension{}, false
	}
	for _, o := range outputs {
		remaining := map[string]bool{}
		for _, n := range names {
			remaining[n] = true
		}
		for _, om := range captureGroupRe.FindAllStringSubmatch(o, -1) {
			if !remaining[om[1]] {
				return buildExtension{}, false
			}
			delete(remaining, om[1])
		}
		if len(remaining) > 0 {
			return buildExtension{}, false
		}
	}
	return buildExtension{kind: capturePath, capture: compiled, names: names, outputs: outputs}, true
}

// outputsFor returns the files the builder writes for the package file at
// path (relative to the package root), or nil when it does not read it.
func (e buildExtension) outputsFor(path string) []string {
	var outs []string
	switch e.kind {
	case capturePath:
		m := e.capture.FindStringSubmatchIndex(path)
		if m == nil {
			return nil
		}
		matched := m[1] - m[0]
		for _, o := range e.outputs {
			resolved := captureGroupRe.ReplaceAllStringFunc(o, func(group string) string {
				name := captureGroupRe.FindStringSubmatch(group)[1]
				for i, n := range e.names {
					if n == name {
						return path[m[2*(i+1)]:m[2*(i+1)+1]]
					}
				}
				return group
			})
			outs = append(outs, path[:len(path)-matched]+resolved)
		}
	case fullPath:
		if path != e.input {
			return nil
		}
		outs = append(outs, e.outputs...)
	default:
		if !strings.HasSuffix(path, e.input) {
			return nil
		}
		for _, o := range e.outputs {
			outs = append(outs, path[:len(path)-len(e.input)]+o)
		}
	}
	// build_runner refuses an output equal to its input.
	kept := outs[:0]
	for _, o := range outs {
		if o != path {
			kept = append(kept, o)
		}
	}
	return kept
}
