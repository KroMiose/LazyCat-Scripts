package main

import (
	"strings"
)

// Validate ownership without evaluating SSH configuration. Existing blocks stay
// byte-for-byte in place: moving Include changes first-value-wins precedence.
// Accept only the exact paths written by the Shell or Go client; an edited
// directive inside the markers is user data, not permission to overwrite it.
func managedInclude(data []byte, generated string) (bool, error) {
	if _, e := stripBlock(data); e != nil {
		return false, &migrationConflict{e.Error()}
	}
	inside, found, includes := false, false, 0
	for _, line := range strings.Split(string(data), "\n") {
		switch line {
		case begin:
			inside = true
			found = true
		case end:
			inside = false
		default:
			if !inside {
				continue
			}
			v := strings.TrimSpace(line)
			if v == "" || strings.HasPrefix(v, "#") {
				continue
			}
			if v != "Include "+sshQuote(generated) && v != "Include "+generated {
				return false, &migrationConflict{"managed Include block was edited; preserve and review user directives"}
			}
			includes++
		}
	}
	if found && includes != 1 {
		return false, &migrationConflict{"managed Include block must reference exactly one generated configuration"}
	}
	return found, nil
}

func syncInclude(data []byte, generated string) ([]byte, error) {
	found, e := managedInclude(data, generated)
	if e != nil {
		return nil, e
	}
	if found {
		return data, nil
	}
	return []byte(begin + "\nInclude " + sshQuote(generated) + "\n" + end + "\n" + string(data)), nil
}
