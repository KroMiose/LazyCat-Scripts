package main

import (
	"testing"
	"time"
)

func TestRenewalWindowContract(t *testing.T) {
	for _, tc := range []struct {
		name     string
		validity time.Duration
		minutes  int
		window   time.Duration
	}{
		{"one-third", 12 * time.Hour, 30, 4 * time.Hour},
		{"two-checks", 12 * time.Hour, 150, 5 * time.Hour},
		{"half-cap", 12 * time.Hour, 200, 6 * time.Hour},
		{"just-below-half", 12 * time.Hour, 359, 6 * time.Hour},
		{"equal-half-invalid", 12 * time.Hour, 360, 0},
		{"too-long", 12 * time.Hour, 361, 0},
		{"zero", 12 * time.Hour, 0, 0},
		{"negative", 12 * time.Hour, -1, 0},
		{"overflow", 12 * time.Hour, int(^uint(0) >> 1), 0},
		{"short-validity", time.Minute, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, e := renewalWindow(tc.validity, tc.minutes)
			if tc.window == 0 {
				if e == nil {
					t.Fatal("invalid interval accepted", got)
				}
				return
			}
			if e != nil || got != tc.window {
				t.Fatal(got, e, "want", tc.window)
			}
		})
	}
}
