// Enumerate test declarations without executing TestMain or test bodies.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"go/ast"
	"go/build"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type Module struct {
	Declared []string `json:"declared"`
	Selected []string `json:"selected"`
}

// Go splits -run at slashes outside bracket expressions. Only the first
// pattern selects top-level tests; descendants are checked in runtime events.
func topPattern(value string) string {
	bracket, escaped := false, false
	for i, ch := range value {
		if escaped {
			escaped = false
			continue
		}
		if ch == '\\' {
			escaped = true
			continue
		}
		if ch == '[' {
			bracket = true
		}
		if ch == ']' {
			bracket = false
		}
		if ch == '/' && !bracket {
			return value[:i]
		}
	}
	return value
}

func main() {
	root := flag.String("root", ".", "repository root")
	run := flag.String("run", "", "top-level Go test regexp")
	fuzz := flag.String("fuzz", "", "one fuzz target")
	flag.Parse()
	pattern, e := regexp.Compile(topPattern(*run))
	if e != nil {
		panic(e)
	}
	result := map[string]Module{}
	for _, module := range []string{"ssh", "codex-hud"} {
		row := Module{Declared: []string{}, Selected: []string{}}
		dir := filepath.Join(*root, module)
		e := filepath.WalkDir(dir, func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() && (entry.Name() == "testdata" || entry.Name() == "vendor" || entry.Name() == ".git") {
				return filepath.SkipDir
			}
			if !entry.IsDir() && strings.HasSuffix(path, "_test.go") && filepath.Dir(path) != dir {
				return fmt.Errorf("new test package needs inventory support: %s", path)
			}
			return nil
		})
		if e != nil {
			panic(e)
		}
		files, e := filepath.Glob(filepath.Join(dir, "*_test.go"))
		if e != nil {
			panic(e)
		}
		for _, path := range files {
			tree, e := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if e != nil {
				panic(e)
			}
			active, e := build.Default.MatchFile(dir, filepath.Base(path))
			if e != nil {
				panic(e)
			}
			for _, declaration := range tree.Decls {
				fn, ok := declaration.(*ast.FuncDecl)
				if !ok || fn.Recv != nil {
					continue
				}
				name := fn.Name.Name
				if !(strings.HasPrefix(name, "Test") || strings.HasPrefix(name, "Fuzz")) || name == "TestMain" {
					continue
				}
				// go test verifies signatures during the actual build. Here even a broken
				// declaration stays in the review inventory so it cannot vanish silently.
				row.Declared = append(row.Declared, name)
				selected := pattern.MatchString(name)
				if *fuzz != "" {
					selected = name == *fuzz
				}
				if active && selected {
					row.Selected = append(row.Selected, name)
				}
			}
		}
		sort.Strings(row.Declared)
		sort.Strings(row.Selected)
		for i := 1; i < len(row.Declared); i++ {
			if row.Declared[i] == row.Declared[i-1] {
				panic(fmt.Sprintf("duplicate test ID: %s/%s", module, row.Declared[i]))
			}
		}
		result[module] = row
	}
	if e := json.NewEncoder(os.Stdout).Encode(result); e != nil {
		panic(e)
	}
}
