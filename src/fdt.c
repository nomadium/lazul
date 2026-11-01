/*
 * Early device tree scan, in C. The heap has to be sized before mruby
 * starts, so before the Ruby parser (kernel/fdt.rb) can run; this reads
 * only what that needs: the RAM in the /memory nodes and what is reserved
 * in it (the memory reservation block, /reserved-memory, and the device
 * tree blob itself).
 *
 * Format: https://devicetree-specification.readthedocs.io (chapter 5).
 * Everything in the blob is big-endian; properties of a node come before
 * its subnodes, but in no particular order among themselves.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "kernel.h"

#define	FDT_MAGIC	0xd00dfeed
#define	FDT_BEGIN_NODE	1
#define	FDT_END_NODE	2
#define	FDT_PROP	3
#define	FDT_NOP		4
#define	FDT_END		9

#define	MAX_DEPTH	16	/* deeper nodes are walked but not looked at */
#define	MAX_RANGES	32	/* RAM regions, and reserved ones, each */

struct fdt_header {
	uint32_t	magic;
	uint32_t	totalsize;
	uint32_t	off_dt_struct;
	uint32_t	off_dt_strings;
	uint32_t	off_mem_rsvmap;
	uint32_t	version;
	uint32_t	last_comp_version;
	uint32_t	boot_cpuid_phys;
	uint32_t	size_dt_strings;
	uint32_t	size_dt_struct;
};

/* A range of physical addresses, [start, end). */
struct range {
	uint64_t	start;
	uint64_t	end;
};

/* What the walk keeps about each open node, from the root down. */
struct node {
	const char	*name;
	uint32_t	 address_cells;	/* for its children's reg */
	uint32_t	 size_cells;
	int		 is_memory;	/* device_type = "memory" */
	const uint8_t	*reg;		/* its reg property, if any */
	uint32_t	 reg_len;
};

static struct range ram[MAX_RANGES], reserved[MAX_RANGES];
static int nram, nreserved;

static uint32_t
be32(const void *p)
{
	const uint8_t *b = p;

	return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 |
	    (uint32_t)b[2] << 8 | b[3];
}

/* A number made of n big-endian 32-bit cells. */
static uint64_t
cells(const uint8_t *p, uint32_t n)
{
	uint64_t v;

	for (v = 0; n > 0; n--, p += 4)
		v = v << 32 | be32(p);
	return v;
}

static void
add_range(struct range *list, int *n, uint64_t start, uint64_t size)
{
	if (size == 0)
		return;
	if (*n == MAX_RANGES)
		panic("device tree: too many memory ranges");
	list[*n].start = start;
	list[*n].end = start + size;
	(*n)++;
}

/*
 * Add every <address size> pair of a reg property, decoded with the
 * parent's cell counts, to list.
 */
static void
add_reg(struct range *list, int *n, const struct node *parent,
    const uint8_t *reg, uint32_t len)
{
	uint32_t ac, sc, entry;

	ac = parent->address_cells;
	sc = parent->size_cells;
	entry = 4 * (ac + sc);
	if (entry == 0 || ac > 2 || sc > 2)
		return;
	for (; len >= entry; reg += entry, len -= entry)
		add_range(list, n, cells(reg, ac), cells(reg + 4 * ac, sc));
}

/* Walk the structure block, filling ram[] and reserved[]. */
static void
walk(const uint8_t *fdt, const struct fdt_header *h)
{
	struct node stack[MAX_DEPTH];
	const uint8_t *p, *end, *value;
	const char *name, *strings;
	struct node *node, *parent;
	uint32_t token, len;
	int depth;

	p = fdt + be32(&h->off_dt_struct);
	end = p + be32(&h->size_dt_struct);
	strings = (const char *)fdt + be32(&h->off_dt_strings);
	depth = -1;

	while (p + 4 <= end) {
		token = be32(p);
		p += 4;
		switch (token) {
		case FDT_BEGIN_NODE:
			name = (const char *)p;
			p += (strlen(name) + 1 + 3) & ~3UL;
			if (++depth >= MAX_DEPTH)
				break;
			node = &stack[depth];
			memset(node, 0, sizeof(*node));
			node->name = name;
			node->address_cells = 2;	/* the spec's defaults */
			node->size_cells = 1;
			break;
		case FDT_END_NODE:
			if (depth >= 1 && depth < MAX_DEPTH) {
				node = &stack[depth];
				parent = &stack[depth - 1];
				/* A RAM region, e.g. /memory@80000000. */
				if (depth == 1 && node->is_memory && node->reg)
					add_reg(ram, &nram, parent, node->reg,
					    node->reg_len);
				/* A child of /reserved-memory. */
				if (depth == 2 &&
				    strcmp(parent->name, "reserved-memory") == 0 &&
				    node->reg)
					add_reg(reserved, &nreserved, parent,
					    node->reg, node->reg_len);
			}
			depth--;
			break;
		case FDT_PROP:
			len = be32(p);
			name = strings + be32(p + 4);
			value = p + 8;
			p += (8 + len + 3) & ~3UL;
			if (depth < 0 || depth >= MAX_DEPTH)
				break;
			node = &stack[depth];
			if (strcmp(name, "#address-cells") == 0 && len == 4)
				node->address_cells = be32(value);
			else if (strcmp(name, "#size-cells") == 0 && len == 4)
				node->size_cells = be32(value);
			else if (strcmp(name, "device_type") == 0)
				node->is_memory = len == sizeof("memory") &&
				    memcmp(value, "memory", len) == 0;
			else if (strcmp(name, "reg") == 0) {
				node->reg = value;
				node->reg_len = len;
			}
			break;
		case FDT_NOP:
			break;
		case FDT_END:
			return;
		default:
			panic("device tree: bad token");
		}
	}
	panic("device tree: no end token");
}

/*
 * End of the free RAM that starts at start: the end of the RAM region
 * holding start, lowered to the first reserved range above start. Panics
 * if the device tree is unusable, or says start is not free RAM.
 */
uintptr_t
fdt_free_ram_end(uintptr_t dtb, uintptr_t start)
{
	const struct fdt_header *h;
	const uint8_t *fdt, *rsv;
	uint64_t addr, size, limit;
	int i;

	fdt = (const uint8_t *)dtb;
	h = (const struct fdt_header *)fdt;
	if (be32(&h->magic) != FDT_MAGIC)
		panic("no device tree at the boot argument");
	if (be32(&h->version) < 17)
		panic("device tree: version older than 17");

	nram = nreserved = 0;
	for (rsv = fdt + be32(&h->off_mem_rsvmap); ; rsv += 16) {
		addr = cells(rsv, 2);
		size = cells(rsv + 8, 2);
		if (addr == 0 && size == 0)
			break;
		add_range(reserved, &nreserved, addr, size);
	}
	add_range(reserved, &nreserved, dtb, be32(&h->totalsize));
	walk(fdt, h);

	limit = 0;
	for (i = 0; i < nram; i++)
		if (ram[i].start <= start && start < ram[i].end)
			limit = ram[i].end;
	if (limit == 0)
		panic("device tree: the kernel is not in RAM");

	for (i = 0; i < nreserved; i++) {
		if (reserved[i].end <= start || reserved[i].start >= limit)
			continue;
		if (reserved[i].start <= start)
			panic("device tree: the heap start is reserved");
		limit = reserved[i].start;
	}
	return (uintptr_t)limit;
}
