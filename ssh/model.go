package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"
)

type endpoint struct{ Host, Port, Via string }
type host struct {
	Name, User, Via, Identity string
	Legacy                    endpoint
	Routes                    map[string]endpoint
}
type authority struct{ Host, Key, Principals, Validity string }
type inventory struct {
	Route    string
	Hosts    []host
	CA       authority
	Warnings []string
}
type connection struct{ Alias, Host, Port, User, Via, Identity, Certificate string }

var aliasPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
var hostPattern = regexp.MustCompile(`^[A-Za-z0-9._:%-]+$`)
var durationPattern = regexp.MustCompile(`^[1-9][0-9]*[smhdw]$`)

func validateYAMLTree(n *yaml.Node, depth int, count *int) error {
	*count++
	if depth > 32 || *count > 100000 {
		return errors.New("YAML structure exceeds supported bounds")
	}
	if n.Kind == yaml.AliasNode {
		return errors.New("YAML aliases require explicit expansion before migration")
	}
	if n.Kind == yaml.MappingNode {
		if _, e := mapping(n); e != nil {
			return e
		}
	}
	for _, child := range n.Content {
		if e := validateYAMLTree(child, depth+1, count); e != nil {
			return e
		}
	}
	return nil
}

func jumpAlias(jump string) (string, error) {
	parts := strings.Split(jump, "@")
	if len(parts) > 2 || (len(parts) == 2 && (!aliasPattern.MatchString(parts[0]) || strings.HasPrefix(parts[0], "-"))) {
		return "", errors.New("invalid ProxyJump user")
	}
	host := parts[len(parts)-1]
	port := ""
	if strings.HasPrefix(host, "[") {
		end := strings.Index(host, "]")
		if end < 0 {
			return "", errors.New("invalid ProxyJump IPv6")
		}
		tail := host[end+1:]
		if tail != "" {
			if !strings.HasPrefix(tail, ":") {
				return "", errors.New("invalid ProxyJump suffix")
			}
			port = tail[1:]
			if port == "" {
				return "", errors.New("empty ProxyJump port")
			}
		}
		host = host[1:end]
		ip, _, _ := strings.Cut(host, "%")
		if net.ParseIP(ip) == nil || !hostPattern.MatchString(host) {
			return "", errors.New("invalid ProxyJump IPv6")
		}
	} else {
		if strings.Contains(host, ":") {
			var found bool
			host, port, found = strings.Cut(host, ":")
			if found && port == "" {
				return "", errors.New("empty ProxyJump port")
			}
		}
		if !aliasPattern.MatchString(host) || strings.HasPrefix(host, "-") {
			return "", errors.New("invalid ProxyJump host")
		}
	}
	if port != "" {
		p, e := strconv.Atoi(port)
		if e != nil || p < 1 || p > 65535 {
			return "", errors.New("invalid ProxyJump port")
		}
	}
	return host, nil
}

func mapping(n *yaml.Node) (map[string]*yaml.Node, error) {
	if n == nil || n.Tag == "!!null" {
		return map[string]*yaml.Node{}, nil
	}
	if n.Kind != yaml.MappingNode {
		return nil, errors.New("expected a mapping")
	}
	result := map[string]*yaml.Node{}
	for i := 0; i < len(n.Content); i += 2 {
		k := n.Content[i]
		if k.Tag != "!!str" {
			return nil, errors.New("mapping keys must be strings")
		}
		if _, exists := result[k.Value]; exists {
			return nil, fmt.Errorf("duplicate field %s at line %d", k.Value, k.Line)
		}
		result[k.Value] = n.Content[i+1]
	}
	return result, nil
}
func value(nodes ...*yaml.Node) (string, error) {
	result := ""
	seen := false
	for _, n := range nodes {
		if n == nil || n.Tag == "!!null" {
			continue
		}
		if n.Kind != yaml.ScalarNode || (n.Tag != "!!str" && n.Tag != "!!int") {
			return "", fmt.Errorf("expected string/integer at line %d", n.Line)
		}
		if strings.ContainsFunc(n.Value, func(r rune) bool { return r < 32 || r == 127 }) {
			return "", fmt.Errorf("multiline/control value at line %d", n.Line)
		}
		if seen && n.Value != result {
			return "", fmt.Errorf("conflicting equivalent fields at line %d", n.Line)
		}
		result = n.Value
		seen = true
	}
	return result, nil
}
func unknown(m map[string]*yaml.Node, known []string, prefix string, w *[]string) {
	allowed := map[string]bool{}
	for _, k := range known {
		allowed[k] = true
	}
	for k := range m {
		if !allowed[k] {
			*w = append(*w, prefix+k)
		}
	}
}
func parseInventory(data []byte) (inventory, error) {
	in, e := parseInventoryData(data)
	if e != nil {
		return in, &configurationError{e}
	}
	return in, nil
}
func parseInventoryData(data []byte) (inventory, error) {
	out := inventory{Route: "lan"}
	if len(data) > 4<<20 {
		return out, errors.New("inventory exceeds 4 MiB bound")
	}
	var doc yaml.Node
	d := yaml.NewDecoder(bytes.NewReader(data))
	if err := d.Decode(&doc); err != nil {
		return out, err
	}
	var extra yaml.Node
	if d.Decode(&extra) != io.EOF {
		return out, errors.New("expected exactly one YAML document")
	}
	if len(doc.Content) != 1 {
		return out, errors.New("empty inventory")
	}
	count := 0
	if e := validateYAMLTree(&doc, 0, &count); e != nil {
		return out, e
	}
	top, err := mapping(doc.Content[0])
	if err != nil {
		return out, err
	}
	v, err := value(top["version"])
	if err != nil || v != "1" {
		return out, errors.New("only inventory version 1 is supported")
	}
	if r, e := value(top["default_route"], top["defaultRoute"]); e != nil {
		return out, e
	} else if r != "" {
		out.Route = r
	}
	if out.Route != "lan" && out.Route != "wan" && out.Route != "tun" {
		return out, errors.New("default_route must be lan/wan/tun")
	}
	unknown(top, []string{"version", "default_route", "defaultRoute", "hosts", "ca"}, "", &out.Warnings)
	ca, e := mapping(top["ca"])
	if e != nil {
		return out, fmt.Errorf("ca: %w", e)
	}
	for _, f := range []struct {
		dst  *string
		keys []string
	}{{&out.CA.Host, []string{"ssh_host", "sshHost", "host"}}, {&out.CA.Key, []string{"ca_key_path", "caKeyPath"}}, {&out.CA.Principals, []string{"principals"}}, {&out.CA.Validity, []string{"validity"}}} {
		var nodes []*yaml.Node
		for _, k := range f.keys {
			nodes = append(nodes, ca[k])
		}
		*f.dst, e = value(nodes...)
		if e != nil {
			return out, e
		}
	}
	if out.CA.Key == "" {
		out.CA.Key = "~/.lazycat/ssh-ca/lazycat-ssh-ca"
	}
	if out.CA.Principals == "" {
		out.CA.Principals = "root"
	}
	if out.CA.Validity == "" {
		out.CA.Validity = "12h"
	}
	if out.CA.Host != "" {
		if !aliasPattern.MatchString(out.CA.Host) || strings.HasPrefix(out.CA.Host, "-") {
			return out, errors.New("invalid CA ssh host")
		}
		if !durationPattern.MatchString(out.CA.Validity) {
			return out, errors.New("invalid certificate validity")
		}
		for _, p := range strings.Split(out.CA.Principals, ",") {
			if !aliasPattern.MatchString(p) {
				return out, errors.New("invalid principal")
			}
		}
	}
	unknown(ca, []string{"ssh_host", "sshHost", "host", "ca_key_path", "caKeyPath", "principals", "validity"}, "ca.", &out.Warnings)
	hosts, e := mapping(top["hosts"])
	if e != nil || len(hosts) == 0 {
		return out, errors.New("hosts must be a nonempty mapping")
	}
	names := make([]string, 0, len(hosts))
	for name := range hosts {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if !aliasPattern.MatchString(name) || strings.HasPrefix(name, "-") {
			return out, fmt.Errorf("invalid alias %q", name)
		}
		m, e := mapping(hosts[name])
		if e != nil {
			return out, fmt.Errorf("hosts.%s: %w", name, e)
		}
		h := host{Name: name, Routes: map[string]endpoint{}}
		for _, f := range []struct {
			dst *string
			key string
		}{{&h.User, "user"}, {&h.Via, "via"}, {&h.Identity, "identityFile"}, {&h.Legacy.Host, "host"}, {&h.Legacy.Port, "port"}} {
			*f.dst, e = value(m[f.key])
			if e != nil {
				return out, fmt.Errorf("hosts.%s.%s: %w", name, f.key, e)
			}
		}
		known := []string{"user", "via", "identityFile", "host", "port"}
		for _, route := range []string{"lan", "wan", "tun"} {
			nested, e := mapping(m[route])
			if e != nil {
				return out, e
			}
			known = append(known, route)
			ep := endpoint{}
			for _, f := range []struct {
				dst   *string
				key   string
				camel string
			}{{&ep.Host, "host", "Host"}, {&ep.Port, "port", "Port"}, {&ep.Via, "via", "Via"}} {
				*f.dst, e = value(m[route+"_"+f.key], m[route+f.camel], nested[f.key])
				if e != nil {
					return out, fmt.Errorf("hosts.%s.%s: %w", name, route, e)
				}
				known = append(known, route+"_"+f.key, route+f.camel)
			}
			unknown(nested, []string{"host", "port", "via"}, "hosts."+name+"."+route+".", &out.Warnings)
			h.Routes[route] = ep
		}
		unknown(m, known, "hosts."+name+".", &out.Warnings)
		out.Hosts = append(out.Hosts, h)
	}
	sort.Strings(out.Warnings)
	for _, field := range out.Warnings {
		parts := strings.Split(field, ".")
		name := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(parts[len(parts)-1], "_", ""), "-", ""))
		switch name {
		case "proxycommand", "localcommand", "remotecommand", "permitlocalcommand", "include", "match", "identityagent", "forwardagent":
			return out, fmt.Errorf("unsupported execution or trust field: %s", field)
		}
	}
	return out, nil
}
func priority(route string) []string {
	switch route {
	case "wan":
		return []string{"wan", "tun", "lan"}
	case "tun":
		return []string{"tun", "wan", "lan"}
	default:
		return []string{"lan", "tun", "wan"}
	}
}
func connections(in inventory, key, cert string) ([]connection, error) {
	var out []connection
	index := map[string]host{}
	for _, h := range in.Hosts {
		index[h.Name] = h
	}
	add := func(h host, name string, ep endpoint) error {
		if ep.Host == "" || !hostPattern.MatchString(ep.Host) {
			return fmt.Errorf("%s: invalid HostName", name)
		}
		if h.User != "" && !aliasPattern.MatchString(h.User) {
			return fmt.Errorf("%s: invalid user", name)
		}
		if ep.Port != "" {
			p, e := strconv.Atoi(ep.Port)
			if e != nil || p < 1 || p > 65535 {
				return fmt.Errorf("%s: invalid port", name)
			}
		}
		if ep.Via != "" {
			for _, jump := range strings.Split(ep.Via, ",") {
				if _, e := jumpAlias(jump); e != nil {
					return fmt.Errorf("%s: invalid ProxyJump", name)
				}
			}
		}
		if strings.ContainsAny(h.Identity, "\r\n\x00\"") {
			return fmt.Errorf("%s: invalid IdentityFile", name)
		}
		c := connection{Alias: name, Host: ep.Host, Port: ep.Port, User: h.User, Via: ep.Via, Identity: h.Identity}
		if c.Identity == "" && in.CA.Host != "" {
			c.Identity = key
			c.Certificate = cert
		}
		out = append(out, c)
		return nil
	}
	for _, h := range in.Hosts {
		multi := false
		for _, e := range h.Routes {
			multi = multi || e.Host != ""
		}
		if !multi {
			ep := h.Legacy
			ep.Via = h.Via
			if err := add(h, h.Name, ep); err != nil {
				return nil, err
			}
			continue
		}
		routes := map[string]endpoint{}
		for k, v := range h.Routes {
			routes[k] = v
		}
		if routes["wan"].Host == "" && h.Legacy.Host != "" {
			ep := routes["wan"]
			ep.Host = h.Legacy.Host
			if h.Legacy.Port != "" {
				ep.Port = h.Legacy.Port
			}
			routes["wan"] = ep
		}
		for _, r := range priority(in.Route) {
			if routes[r].Host != "" {
				if e := add(h, h.Name, routes[r]); e != nil {
					return nil, e
				}
				break
			}
		}
		for _, r := range []string{"lan", "wan", "tun"} {
			ep := routes[r]
			if ep.Host != "" {
				if e := add(h, h.Name+"-"+r, ep); e != nil {
					return nil, e
				}
				continue
			}
			if h.Via == "" {
				continue
			}
			for _, fallback := range []string{"lan", "tun", "wan"} {
				if routes[fallback].Host != "" {
					ep = routes[fallback]
					break
				}
			}
			ep.Via = h.Via
			if jump, ok := index[h.Via]; ok {
				for _, jr := range priority(r) {
					if jump.Routes[jr].Host != "" {
						ep.Via = h.Via + "-" + jr
						break
					}
				}
			}
			if e := add(h, h.Name+"-"+r, ep); e != nil {
				return nil, e
			}
		}
	}
	byName := map[string]connection{}
	for _, c := range out {
		if _, ok := byName[c.Alias]; ok {
			return nil, fmt.Errorf("generated alias collision: %s", c.Alias)
		}
		byName[c.Alias] = c
	}
	visiting := map[string]bool{}
	done := map[string]bool{}
	var visit func(string) error
	visit = func(name string) error {
		if visiting[name] {
			return fmt.Errorf("ProxyJump cycle at %s", name)
		}
		if done[name] {
			return nil
		}
		c, ok := byName[name]
		if !ok {
			return nil
		}
		visiting[name] = true
		for _, jump := range strings.Split(c.Via, ",") {
			if jump == "" {
				continue
			}
			target, e := jumpAlias(jump)
			if e != nil {
				return e
			}
			if e := visit(target); e != nil {
				return e
			}
		}
		visiting[name] = false
		done[name] = true
		return nil
	}
	for name := range byName {
		if e := visit(name); e != nil {
			return nil, e
		}
	}
	return out, nil
}
func sshQuote(s string) string {
	return `"` + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), `"`, `\"`) + `"`
}
func render(cs []connection) []byte {
	var b strings.Builder
	b.WriteString("# Generated by LazyCat SSH (do not edit manually)\n")
	for _, c := range cs {
		fmt.Fprintf(&b, "Host %s\n    HostName %s\n    HostKeyAlias %s\n", c.Alias, c.Host, c.Alias)
		for _, v := range []struct{ k, s string }{{"User", c.User}, {"Port", c.Port}, {"ProxyJump", c.Via}, {"IdentityFile", c.Identity}, {"CertificateFile", c.Certificate}} {
			if v.s != "" {
				s := v.s
				if v.k == "IdentityFile" || v.k == "CertificateFile" {
					s = sshQuote(s)
				}
				fmt.Fprintf(&b, "    %s %s\n", v.k, s)
			}
		}
		b.WriteString("    IdentitiesOnly yes\n\n")
	}
	return []byte(b.String())
}
