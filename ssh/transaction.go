package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type fileState struct {
	Exists   bool
	Data     []byte
	Mode     uint32
	UID, GID int
	Xattrs   map[string][]byte
}
type change struct {
	Path          string
	Before, After fileState
}
type operation struct {
	Version    int
	ID, Status string
	Changes    []change
}

func state(path string) (fileState, error) {
	var out fileState
	for p := path; ; p = filepath.Dir(p) {
		s, e := os.Lstat(p)
		if e == nil && s.Mode()&os.ModeSymlink != 0 && !(runtime.GOOS == "darwin" && p != path && (p == "/var" || p == "/tmp" || p == "/etc")) {
			return out, fmt.Errorf("symlink requires explicit adoption: %s", p)
		}
		if e != nil && !os.IsNotExist(e) {
			return out, e
		}
		if filepath.Dir(p) == p {
			break
		}
	}
	s, e := os.Lstat(path)
	if os.IsNotExist(e) {
		return out, nil
	}
	if e != nil {
		return out, e
	}
	if !s.Mode().IsRegular() {
		return out, fmt.Errorf("not a regular file: %s", path)
	}
	st, ok := s.Sys().(*syscall.Stat_t)
	if !ok {
		return out, errors.New("unsupported file ownership metadata")
	}
	if int(st.Uid) != os.Geteuid() {
		return out, fmt.Errorf("file belongs to another user: %s", path)
	}
	if s.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return out, errors.New("special file permissions require review")
	}
	out.UID, out.GID = int(st.Uid), int(st.Gid)
	out.Xattrs, e = readXattrs(path)
	if e != nil {
		return out, e
	}
	out.Data, e = os.ReadFile(path)
	out.Exists = true
	out.Mode = uint32(s.Mode().Perm())
	return out, e
}
func readXattrs(path string) (map[string][]byte, error) {
	result := map[string][]byte{}
	n, e := unix.Listxattr(path, nil)
	if errors.Is(e, unix.ENOTSUP) {
		return result, nil
	}
	if e != nil {
		return nil, e
	}
	names := make([]byte, n)
	n, e = unix.Listxattr(path, names)
	if e != nil {
		return nil, e
	}
	for _, name := range strings.Split(string(names[:n]), "\x00") {
		// Kernel-managed provenance is not a user-owned attribute and cannot
		// be restored by ordinary processes on macOS.
		if name == "" || (runtime.GOOS == "darwin" && name == "com.apple.provenance") {
			continue
		}
		size, e := unix.Getxattr(path, name, nil)
		if e != nil {
			return nil, e
		}
		value := make([]byte, size)
		size, e = unix.Getxattr(path, name, value)
		if e != nil {
			return nil, e
		}
		result[name] = value[:size]
	}
	return result, nil
}
func same(a, b fileState) bool {
	return a.Exists == b.Exists && a.Mode == b.Mode && a.UID == b.UID && a.GID == b.GID && bytes.Equal(a.Data, b.Data) && maps.EqualFunc(a.Xattrs, b.Xattrs, bytes.Equal)
}
func writeState(path string, s fileState) error {
	if !s.Exists {
		e := os.Remove(path)
		if os.IsNotExist(e) {
			return nil
		}
		return e
	}
	if _, e := state(path); e != nil {
		return e
	}
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".lazycat-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if e = f.Chown(s.UID, s.GID); e != nil {
		f.Close()
		return e
	}
	for name, value := range s.Xattrs {
		if e = unix.Setxattr(f.Name(), name, value, 0); e != nil {
			f.Close()
			return e
		}
	}

	if e = f.Chmod(os.FileMode(s.Mode)); e == nil {
		_, e = f.Write(s.Data)
	}
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	return os.Rename(f.Name(), path)
}
func withFileLock(dir string, fn func() error) error {
	if e := os.MkdirAll(dir, 0700); e != nil {
		return e
	}
	if s, e := os.Lstat(dir); e != nil || !s.IsDir() || s.Mode()&os.ModeSymlink != 0 {
		return errors.New("unsafe lock directory")
	}
	fd, e := unix.Open(filepath.Join(dir, "operation.lock"), unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW, 0600)
	if e != nil {
		return e
	}
	defer unix.Close(fd)
	deadline := time.Now().Add(5 * time.Second)
	for {
		e = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB)
		if e == nil {
			break
		}
		if e != unix.EAGAIN && e != unix.EWOULDBLOCK {
			return e
		}
		if time.Now().After(deadline) {
			return errors.New("another operation is active")
		}
		time.Sleep(20 * time.Millisecond)
	}
	defer unix.Flock(fd, unix.LOCK_UN)
	return fn()
}
func journal(dir string, op operation) error {
	b, e := json.MarshalIndent(op, "", "  ")
	if e != nil {
		return e
	}
	return writeState(filepath.Join(dir, op.ID+".json"), fileState{Exists: true, Data: b, Mode: 0600, UID: os.Geteuid(), GID: os.Getegid()})
}
func prepare(path string, data []byte, mode uint32) (change, error) {
	before, e := state(path)
	if before.Exists {
		mode = before.Mode
	}
	after := fileState{Exists: true, Data: data, Mode: mode, UID: os.Geteuid(), GID: os.Getegid()}
	if before.Exists {
		after.UID, after.GID, after.Xattrs = before.UID, before.GID, before.Xattrs
	}
	return change{path, before, after}, e
}
func commit(dir string, changes []change) (string, error) {
	return commitWithWriter(dir, changes, writeState)
}

func commitWithWriter(dir string, changes []change, write func(string, fileState) error) (string, error) {
	id := ""
	e := withFileLock(dir, func() error {
		var pending []change
		for _, c := range changes {
			now, e := state(c.Path)
			if e != nil {
				return e
			}
			if !same(now, c.Before) {
				return fmt.Errorf("concurrent modification: %s", c.Path)
			}
			if !same(c.Before, c.After) {
				pending = append(pending, c)
			}
		}
		if len(pending) == 0 {
			return nil
		}
		nonce := make([]byte, 8)
		if _, e := rand.Read(nonce); e != nil {
			return e
		}
		id = time.Now().UTC().Format("20060102T150405") + "-" + hex.EncodeToString(nonce)
		op := operation{1, id, "prepared", pending}
		if e := journal(dir, op); e != nil {
			return e
		}
		restore := func(applied int, cause error) error {
			var recovery error
			for j := applied - 1; j >= 0; j-- {
				v := pending[j]
				current, re := state(v.Path)
				if re == nil && !same(current, v.After) {
					re = fmt.Errorf("rollback conflict: %s", v.Path)
				}
				if re == nil {
					re = write(v.Path, v.Before)
				}
				recovery = errors.Join(recovery, re)
			}
			op.Status = "rolled-back"
			if recovery != nil {
				op.Status = "rollback-required"
			}
			return errors.Join(cause, recovery, journal(dir, op))
		}
		for i, c := range pending {
			now, e := state(c.Path)
			if e == nil && !same(now, c.Before) {
				e = fmt.Errorf("concurrent modification: %s", c.Path)
			}
			if e == nil {
				e = write(c.Path, c.After)
			}
			if e != nil {
				return restore(i, e)
			}
		}
		op.Status = "committed"
		if e := journal(dir, op); e != nil {
			return restore(len(pending), e)
		}
		return nil
	})
	return id, e
}
func rollback(dir, id string) error {
	return rollbackChecked(dir, id, nil)
}

func rollbackChecked(dir, id string, check func(operation) error) error {
	if id == "" || filepath.Base(id) != id || strings.Contains(id, "..") {
		return errors.New("invalid operation id")
	}
	return withFileLock(dir, func() error {
		b, e := os.ReadFile(filepath.Join(dir, id+".json"))
		if e != nil {
			return e
		}
		var op operation
		if e = json.Unmarshal(b, &op); e != nil {
			return e
		}
		if op.Version != 1 || op.ID != id {
			return errors.New("unsupported operation record")
		}
		if check != nil {
			if e := check(op); e != nil {
				return e
			}
		}
		for _, c := range op.Changes {
			now, e := state(c.Path)
			if e != nil {
				return e
			}
			if !same(now, c.After) && !same(now, c.Before) {
				return fmt.Errorf("rollback would overwrite later changes: %s", c.Path)
			}
		}
		for i := len(op.Changes) - 1; i >= 0; i-- {
			c := op.Changes[i]
			now, e := state(c.Path)
			if e != nil {
				return e
			}
			if same(now, c.Before) {
				continue
			}
			if !same(now, c.After) {
				return fmt.Errorf("rollback conflict: %s", c.Path)
			}
			if e := writeState(c.Path, c.Before); e != nil {
				return e
			}
		}
		op.Status = "rolled-back"
		return journal(dir, op)
	})
}

// A file restore alone cannot restore launchd/systemd's loaded state. Until
// public lifecycle rollback is implemented, reject those records BEFORE writes.
// Internal failure recovery calls rollback together with its service recovery.
func rollbackUserOperation(p paths, id string) error {
	return rollbackChecked(p.Ops, id, func(op operation) error {
		for _, c := range op.Changes {
			_, task := timerFiles(p, 30)[c.Path]
			if task || c.Path == timerReceiptPath(p) {
				return &migrationConflict{"operation includes native tasks; file-only rollback is unsafe; review the saved task and program together"}
			}
		}
		return nil
	})
}

func digest(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

const begin = "# >>> LazyCat SSH BEGIN >>>"
const end = "# <<< LazyCat SSH END <<<"

func stripBlock(b []byte) ([]byte, error) {
	lines := strings.SplitAfter(string(b), "\n")
	inside := false
	count := 0
	var out strings.Builder
	for _, line := range lines {
		v := strings.TrimSuffix(line, "\n")
		switch v {
		case begin:
			if inside || count > 0 {
				return nil, errors.New("duplicate/nested managed block")
			}
			inside = true
			count++
		case end:
			if !inside {
				return nil, errors.New("unmatched end marker")
			}
			inside = false
		default:
			if !inside {
				out.WriteString(line)
			}
		}
	}
	if inside {
		return nil, errors.New("unclosed managed block")
	}
	return []byte(out.String()), nil
}
