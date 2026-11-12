package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Persistent lock files are deliberately never unlinked while active: unlinking a
// locked inode would let another process acquire a different lock for the same turn.
func withLock(path string, fn func() error) error {
	return withLockContext(context.Background(), path, fn)
}

func withLockContext(ctx context.Context, path string, fn func() error) error {
	if err := privateDir(filepath.Dir(path)); err != nil {
		return err
	}
	fd, err := unix.Open(path, unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	deadline := time.Now().Add(4 * time.Second)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		err = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			break
		}
		if err != unix.EWOULDBLOCK && err != unix.EAGAIN {
			return err
		}
		if time.Now().After(deadline) {
			return errors.New("另一个 codex-hud 进程正在处理，请稍后重试")
		}
		time.Sleep(10 * time.Millisecond)
	}
	defer unix.Flock(fd, unix.LOCK_UN)
	return fn()
}

func turnHash(session, turn string) string {
	identity, _ := json.Marshal([]string{session, turn})
	sum := sha256.Sum256(identity)
	return hex.EncodeToString(sum[:])
}

func markerExists(path string) bool {
	s, err := os.Stat(path)
	return err == nil && time.Since(s.ModTime()) < 24*time.Hour
}

func cleanMarkers(dir, prefix string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), prefix) && strings.HasSuffix(e.Name(), ".sent") {
			s, err := e.Info()
			if err == nil && time.Since(s.ModTime()) > 24*time.Hour {
				_ = os.Remove(filepath.Join(dir, e.Name()))
			}
		}
	}
}

// A fixed set of advisory lock stripes avoids accumulating permanent lock files.
// Turn markers remain exact; unrelated turns sharing a stripe only serialize.
func (a *app) turnTransaction(session, turn string, fn func(string) error) error {
	if session == "" || turn == "" {
		return fn("")
	}
	h := turnHash(session, turn)
	dir := filepath.Join(a.paths.Cache, "turns")
	return withLockContext(a.ctx, filepath.Join(dir, h[:2]+".lock"), func() error { cleanMarkers(dir, h[:2]); return fn(filepath.Join(dir, h+".sent")) })
}
