package csvdumper

import (
	"net"
	"net/netip"
)

func toPrefix(n *net.IPNet) (netip.Prefix, bool) {
	addr, ok := netip.AddrFromSlice(n.IP)
	if !ok {
		return netip.Prefix{}, false
	}
	bits, _ := n.Mask.Size()

	if addr.Is4In6() {
		addr = addr.Unmap()
		if bits >= 96 {
			bits -= 96 // ::ffff:0:0/96 is the whole of IPv4
		}
	}
	if addr.Is4() && bits > 32 {
		return netip.Prefix{}, false
	}
	return netip.PrefixFrom(addr, bits).Masked(), true
}

func parentOf(a, b netip.Prefix) (netip.Prefix, bool) {
	if a.Bits() != b.Bits() || a.Bits() == 0 {
		return netip.Prefix{}, false
	}

	parent, err := a.Addr().Prefix(a.Bits() - 1)
	if err != nil {
		return netip.Prefix{}, false
	}
	if parent.Addr() != a.Addr() {
		return netip.Prefix{}, false
	}
	if !parent.Contains(b.Addr()) {
		return netip.Prefix{}, false
	}
	return parent, true
}

const mergeStackCap = 4096

type mergeStack struct {
	prefixes []netip.Prefix
}

func (s *mergeStack) push(p netip.Prefix) {
	s.prefixes = append(s.prefixes, p)

	for len(s.prefixes) >= 2 {
		top := len(s.prefixes) - 1
		parent, ok := parentOf(s.prefixes[top-1], s.prefixes[top])
		if !ok {
			return
		}
		s.prefixes = append(s.prefixes[:top-1], parent)
	}
}

func (s *mergeStack) full() bool { return len(s.prefixes) >= mergeStackCap }

func (s *mergeStack) drain() []netip.Prefix {
	out := s.prefixes
	s.prefixes = nil
	return out
}
