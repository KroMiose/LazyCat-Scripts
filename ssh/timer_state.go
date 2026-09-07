package main

import (
	"context"
	"errors"
	"strings"
)

// Running and enabled are independent user choices. Updating an owned task
// must preserve both, including a task enabled only until the next reboot.
type linuxTimerState struct {
	active  bool
	enabled string
}

func readLinuxTimerState(ctx context.Context) (*linuxTimerState, error) {
	read := func(property string) (string, error) {
		b, e := timerCommand(ctx, "show", "lazycat-ssh-renew.timer", "--property="+property, "--value")
		return strings.TrimSpace(string(b)), e
	}
	a, e := read("ActiveState")
	if e != nil {
		return nil, e
	}
	if a != "active" && a != "inactive" {
		return nil, &migrationConflict{"timer is transitioning or failed; existing state preserved"}
	}
	enabled, e := read("UnitFileState")
	if e != nil {
		return nil, e
	}
	switch enabled {
	case "enabled", "enabled-runtime", "disabled":
	default:
		return nil, &migrationConflict{"timer enablement is unsupported or masked; existing state preserved"}
	}
	return &linuxTimerState{a == "active", enabled}, nil
}

func (s *linuxTimerState) pause(ctx context.Context) error {
	return (&timerAdoption{Active: s.active}).pause(ctx)
}

func (s *linuxTimerState) restore(ctx context.Context) error {
	if _, e := timerCommand(ctx, "daemon-reload"); e != nil {
		return e
	}
	// Avoid toggling links on ordinary updates. Removal failure recovery may
	// have disabled the task, so compare actual state before restoring it.
	b, e := timerCommand(ctx, "show", "lazycat-ssh-renew.timer", "--property=UnitFileState", "--value")
	if e != nil {
		return e
	}
	if strings.TrimSpace(string(b)) != s.enabled {
		if _, e = timerCommand(ctx, "disable", "lazycat-ssh-renew.timer"); e != nil {
			return e
		}
		if s.enabled != "disabled" {
			args := []string{"enable"}
			if s.enabled == "enabled-runtime" {
				args = append(args, "--runtime")
			}
			if _, e = timerCommand(ctx, append(args, "lazycat-ssh-renew.timer")...); e != nil {
				return e
			}
		}
	}
	action := "stop"
	if s.active {
		action = "start"
	}
	if _, e = timerCommand(ctx, action, "lazycat-ssh-renew.timer"); e != nil {
		return e
	}
	after, e := readLinuxTimerState(ctx)
	if e != nil {
		return e
	}
	if *after != *s {
		return errors.New("timer state restoration did not take effect")
	}
	return nil
}
