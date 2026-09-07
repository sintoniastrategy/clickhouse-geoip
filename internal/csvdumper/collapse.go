package csvdumper

import (
	"net"
	"net/netip"
)

// Collapsing merges adjacent same-payload networks into the largest aligned
// prefixes covering them. One database feeds several tables: DB-IP's 88.8M
// networks are cut at ISP boundaries, so dumped as `country` they yield 88.8M
// rows where the data distinguishes 2.2M — and every row is an ip_trie prefix.
//
// Only two siblings that exactly fill their parent ever merge, so a merged
// prefix covers precisely what its members did: lookups are unchanged.

// toPrefix converts what maxminddb returns into a netip.Prefix. IPv4 arrives
// native under SkipAliasedNetworks; 4-in-6 with a /96..128 mask also works.
func toPrefix(n *net.IPNet) (netip.Prefix, bool) {
	addr, ok := netip.AddrFromSlice(n.IP)
	if !ok {
		return netip.Prefix{}, false
	}
	ones, _ := n.Mask.Size()
	if addr.Is4In6() {
		addr = addr.Unmap()
		if ones >= 96 {
			ones -= 96
		}
	}
	if addr.Is4() && ones > 32 {
		return netip.Prefix{}, false
	}
	return netip.PrefixFrom(addr, ones).Masked(), true
}

// parentOf reports the enclosing prefix when a and b are the two halves
// of it, lower half first.
func parentOf(a, b netip.Prefix) (netip.Prefix, bool) {
	if a.Bits() != b.Bits() || a.Bits() == 0 {
		return netip.Prefix{}, false
	}
	if a.Addr().Is4() != b.Addr().Is4() {
		return netip.Prefix{}, false
	}
	parent, err := a.Addr().Prefix(a.Bits() - 1)
	if err != nil || parent.Addr() != a.Addr() {
		// a is the upper half, so this pair cannot merge upwards.
		return netip.Prefix{}, false
	}
	sibling, err := b.Addr().Prefix(b.Bits() - 1)
	if err != nil || sibling != parent {
		return netip.Prefix{}, false
	}
	return parent, true
}

// run accumulates same-payload prefixes, merging as it goes, like a binary
// counter: a push either carries into the stack top or settles. The cap is a
// safety valve — flushing early only means less merging.
const runStackCap = 4096

type run struct {
	stack []netip.Prefix
}

func (r *run) add(p netip.Prefix) {
	r.stack = append(r.stack, p)
	for len(r.stack) >= 2 {
		parent, ok := parentOf(r.stack[len(r.stack)-2], r.stack[len(r.stack)-1])
		if !ok {
			break
		}
		r.stack = r.stack[:len(r.stack)-2]
		r.stack = append(r.stack, parent)
	}
}

func (r *run) full() bool { return len(r.stack) >= runStackCap }

func (r *run) drain() []netip.Prefix {
	out := r.stack
	r.stack = nil
	return out
}
