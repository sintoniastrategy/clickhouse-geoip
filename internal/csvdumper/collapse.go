package csvdumper

import (
	"net"
	"net/netip"
)

// Collapsing merges consecutive networks that carry an identical payload
// into the largest aligned prefixes that cover them.
//
// It exists because one database can feed several tables. DB-IP's
// "IP to Location + ISP" is a single file of ~88.8M networks, cut at ISP
// and city boundaries; dumped as `country` that same granularity yields
// 88.8M rows where the data only distinguishes ~1.2M. Every row is a
// prefix in the ip_trie dictionary built on top, at roughly 165 bytes
// each, so the difference is tens of gigabytes of RAM.
//
// Merging only ever combines two siblings that exactly fill their parent,
// so a merged prefix covers precisely the addresses its members covered
// and nothing else: lookups are unchanged. Networks with differing
// payloads never share a run, and the source networks partition the
// address space at leaf level, so no third network can hide inside a
// merged supernet.

// toPrefix converts what maxminddb hands back into a netip.Prefix.
// SkipAliasedNetworks yields IPv4 in its native form, but a 4-in-6
// mapped address with a /96..128 mask is handled too.
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

// run accumulates same-payload prefixes, merging as it goes. It behaves
// like a binary counter: a push either merges with the top of the stack
// and carries, or settles, so the stack stays shallow in practice. The
// cap is a safety valve — flushing early only means less merging.
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
