// System bench: the main board (+board=0 Vega, 1 Gradation 2D, 2 eolith16) from reset, on the real SDRAM
// controller and a chip model.
//
//   run_verilator.sh sys_tb +img=<image.bin> [+frames=N] [+snap=F1,F2,...] [+out=<dir>]
//                    [+pctrace=<instr.trace>] [+coin=F] [+start=F] [+hold=K] [+v=1]
//
// +img is the download image (scripts/build_mra.py --image <set> <file>), written into the chip
// model's array before the clock starts. +snap lists frames whose 320 x 240 shown dots are written as
// <out>/f<N>.ppm; a frame ends at the start of vblank, as MAME's frame notifier. +pctrace compares the
// CPU's retired PCs with a MAME instruction trace (docs/E1_TRACE_FORMAT.md) and reports the first
// difference (a TRAP retires with the address after it: accepted). +coin / +start press COIN1 / START1 at
// frame F for +hold frames (default 6).
// The QS1000 program (the first 32 KB at SD_SNDPRG) goes into the sound board while rst is held.
// +wave=<file> logs the sound latch writes ("L <frame> <data>") and the wavetable register writes
// ("W <frame> <off> <data>") in order, for scripts/qs1000_wave_compare.py.
// Per frame (+v=1, else every 60): instructions retired, I- and D-cache misses, the frame's clocks with
// the CPU retiring nothing for 64 clocks or more (stalls), and the buffer flips.
#include "Vtb_sys.h"
#include "Vtb_sys___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <fcntl.h>

double sc_time_stamp() { return 0; }

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

// rtl/debug/eo_perf.sv's probe buses, decoded as scripts/read_issp.tcl does
static uint32_t field(const VlWide<4> &w, int lo, int hi) {
	uint32_t v = 0;
	for (int i = hi; i >= lo; i--) v = v << 1 | ((w[i >> 5] >> (i & 31)) & 1);
	return v;
}
static void print_perf(Vtb_sys *t) {
	const VlWide<4> &f = t->perf_f, &c = t->perf_c;
	printf("perf: frames %u flips %u gaps 1:%u 2:%u 3:%u 4+:%u max %u last %u | wait %u min %u busy %u "
	       "instr %u dmiss %u imiss %u polls %u\n",
	       field(f, 0, 15), field(f, 16, 31), field(f, 32, 47), field(f, 48, 63), field(f, 64, 79), field(f, 80, 95),
	       field(f, 96, 103), field(f, 104, 111), field(c, 0, 19), field(c, 20, 39), field(c, 40, 55), field(c, 56, 79),
	       field(c, 80, 95), field(c, 96, 111), field(c, 112, 127));
}

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::string imgp = arg(argc, argv, "+img=");
	int nframes = atoi(arg(argc, argv, "+frames=", "10").c_str());
	std::string outd = arg(argc, argv, "+out=", ".");
	std::string pctp = arg(argc, argv, "+pctrace=");
	int coin_f = atoi(arg(argc, argv, "+coin=", "-1").c_str());
	int start_f = atoi(arg(argc, argv, "+start=", "-1").c_str());
	int hold = atoi(arg(argc, argv, "+hold=", "6").c_str());
	// +fire=F1,F2,...: P1's button 1 pressed for +firehold frames (4) from each listed frame (hidctch3's pen trigger)
	std::vector<int> fire_at;
	int fire_hold = atoi(arg(argc, argv, "+firehold=", "4").c_str());   // frames each press lasts
	{
		std::string fs = arg(argc, argv, "+fire=");
		for (size_t q = 0; q < fs.size();) {
			size_t c = fs.find(',', q);
			fire_at.push_back(atoi(fs.substr(q, c == std::string::npos ? std::string::npos : c - q).c_str()));
			if (c == std::string::npos) break;
			q = c + 1;
		}
	}
	int coinrep = atoi(arg(argc, argv, "+coinrep=", "0").c_str());    // repeat every N frames (0: once)
	int startrep = atoi(arg(argc, argv, "+startrep=", "0").c_str());
	auto pressed = [&](int k, int at, int rep) {
		if (at < 0 || k < at) return false;
		return rep > 0 ? (k - at) % rep < hold : k < at + hold;
	};
	int verbose = atoi(arg(argc, argv, "+v=", "0").c_str());
	bool perf = atoi(arg(argc, argv, "+perf=", "0").c_str()) != 0;   // rtl/debug/eo_perf.sv's fields every 60 frames
	// +penlog=1: every read of a pen port (frame, line, pen, the position read) and each frame with IN0 reads that
	// see P1's pen button down
	bool penlog = atoi(arg(argc, argv, "+penlog=", "0").c_str()) != 0;
	long trig_reads = 0;
	std::string wavep = arg(argc, argv, "+wave=");
	FILE *wavef = wavep.empty() ? nullptr : fopen(wavep.c_str(), "w");
	long pcwin = atol(arg(argc, argv, "+pcwin=", "-1").c_str());   // print 40 retired PCs from this instruction
	// +bustrace=<set>_bus.trace: the CPU's data accesses in order against MAME's R/W rows (E1-32: one row an
	// access, mask = the lanes); the first +busmax differences are printed
	struct BusRow { uint64_t idx; char kind; uint32_t addr, data, mask; };
	std::vector<BusRow> mrows;
	{
		std::string bp = arg(argc, argv, "+bustrace=");
		if (!bp.empty()) {
			FILE *t = fopen(bp.c_str(), "r");
			if (!t) { fprintf(stderr, "cannot open +bustrace\n"); return 2; }
			char line[512];
			while (fgets(line, sizeof line, t)) {
				unsigned long long idx; char kind, space; unsigned a, d, m;
				if (line[0] == '#' || sscanf(line, "%llu %c %c %x %x %x", &idx, &kind, &space, &a, &d, &m) != 6) continue;
				if (kind == 'F' || space != 'P') continue;
				mrows.push_back({idx, kind, a, d, m});
			}
			fclose(t);
			printf("bustrace: %zu data accesses\n", mrows.size());
		}
	}
	int busmax = atoi(arg(argc, argv, "+busmax=", "4").c_str());
	// +ramdump=F: work RAM at 0 (SDRAM SD_WRAM, 2 MB, the CPU's byte order) to <out>/ram_f<F>.bin at the end of frame F
	int ramdump = atoi(arg(argc, argv, "+ramdump=", "-1").c_str());
	// +eedump=F: the 93C66's 512 bytes (Gradation 2D) to <out>/ee_f<F>.bin at the end of frame F
	int eedump = atoi(arg(argc, argv, "+eedump=", "-1").c_str());
	// +ram4=1: the work RAM at 0x40000000 instead (SDRAM SD_WRAM4, the Gradation 2D)
	const size_t ram_base = atoi(arg(argc, argv, "+ram4=", "0").c_str()) ? 0x2600000 : 0x2400000;
	// +wlog=<file>: every CPU write as "W <instr> <addr> <be> <data>", for comparing a stretch with MAME's bus
	// trace where the PCs have parted (scripts compare the sequence, not the timing)
	FILE *wlog = nullptr;
	{
		std::string wp = arg(argc, argv, "+wlog=");
		if (!wp.empty()) wlog = fopen(wp.c_str(), "w");
	}
	uint32_t wlo = 0, whi = 0xffffffffu;      // +wrange=lo,hi (hex): only writes in [lo, hi)
	sscanf(arg(argc, argv, "+wrange=", "").c_str(), "%x,%x", &wlo, &whi);
	bool wlog_reads = atoi(arg(argc, argv, "+wreads=", "0").c_str()) != 0;   // +wreads=1: reads too ("R ...")
	size_t bus_pos = 0;
	int bus_bad = 0;
	std::set<int> snaps;
	{
		std::string s = arg(argc, argv, "+snap=");
		for (size_t p = 0; p < s.size();) {
			size_t q = s.find(',', p);
			snaps.insert(atoi(s.substr(p, q - p).c_str()));
			if (q == std::string::npos) break;
			p = q + 1;
		}
	}

	FILE *f = fopen(imgp.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open +img=%s\n", imgp.c_str()); return 2; }
	std::vector<uint8_t> img;
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	img.resize(n);
	if (fread(img.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
	fclose(f);

	std::vector<uint32_t> mame_pc;
	std::vector<bool> mame_trap;   // TRAP (0xfc00-0xffff): e1_cpu's retire_pc is the halfword after it
	if (!pctp.empty()) {
		FILE *t = fopen(pctp.c_str(), "r");
		if (!t) { fprintf(stderr, "cannot open +pctrace\n"); return 2; }
		char line[4096];
		while (fgets(line, sizeof line, t)) {
			if (line[0] == '#') continue;
			unsigned long long idx; unsigned pc, op;
			if (sscanf(line, "%llu %x %x", &idx, &pc, &op) == 3) {
				mame_pc.push_back(pc);
				mame_trap.push_back(op >= 0xfc00);
			}
		}
		fclose(t);
		printf("pctrace: %zu instructions\n", mame_pc.size());
	}

	Vtb_sys *top = new Vtb_sys;
	auto &mem = top->rootp->tb_sys__DOT__u_chip__DOT__mem;
	for (size_t i = 0; i + 1 < img.size(); i += 2)
		mem[i >> 1] = (uint16_t)(img[i] | (img[i + 1] << 8));

	top->clk = 0; top->rst = 1; top->prst = 1; top->pause = 0;
	top->board = atoi(arg(argc, argv, "+board=", "0").c_str());   // 0 Vega, 1 Gradation 2D, 2 eolith16
	top->ws_mem3 = atoi(arg(argc, argv, "+ws3=", "0").c_str());   // memory wait states: clocks per MEM3 access
	top->ws_mem = atoi(arg(argc, argv, "+ws=", "0").c_str());     // and per MEM0-2 access (rtl/eo_busws.sv)
	top->p1p2 = 0xffff; top->system = 0x3f; top->snd_dl_we = 0;
	top->dsw = strtoul(arg(argc, argv, "+dsw=", "ff").c_str(), nullptr, 16);   // DSW1, as MAME's port
	// +pens=X,Y: hidctch3's light pens on (the mod byte's bit 2), pen 1 at X (0-159), Y (0-119)
	{
		int px = -1, py = 0;
		sscanf(arg(argc, argv, "+pens=", "").c_str(), "%d,%d", &px, &py);
		top->pens = px >= 0; top->pen1_x = px >= 0 ? px : 0; top->pen1_y = py;
		// +pens2=X,Y: pen 2's position (default 0, 0, as MAME's port with no second gun)
		int qx = 0, qy = 0;
		sscanf(arg(argc, argv, "+pens2=", "").c_str(), "%d,%d", &qx, &qy);
		top->pen2_x = qx; top->pen2_y = qy;
	}
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	for (int i = 0; i < 8; i++) tick();           // the PLL locks: the memory side's power-up reset
	top->prst = 0;
	const size_t SD_SNDPRG = 0x2080000, SD_SNDCPU = 0x2088000;
	for (int i = 0; i < 0x8000 && SD_SNDPRG + i < img.size(); i++) {
		top->snd_dl_we = 1; top->snd_dl_addr = i; top->snd_dl_data = img[SD_SNDPRG + i];
		tick();
	}
	for (int i = 0; top->board == 1 && i < 0x8000; i++) {    // the Gradation 2D sound CPU's program
		top->snd_dl_we = 1; top->snd_dl_addr = 0x8000 | i; top->snd_dl_data = img[SD_SNDCPU + i];
		tick();
	}
	top->snd_dl_we = 0;
	for (int i = 0; i < 20000; i++) tick();       // the SDRAM's initialisation, the caches' sweep
	top->rst = 0;

	uint64_t ninstr = 0, frame_instr = 0, clocks = 0, frame_clk = 0, stall = 0, since_retire = 0;
	uint64_t pc_ok = 0;
	bool pc_done = mame_pc.empty();
	uint32_t im0 = 0, dm0 = 0;
	int frame = 0, prev_vb = 0, flips = 0, prev_vbuf = 0;
	std::vector<uint8_t> pix;
	bool snapping = false;
	while (frame < nframes) {
		int fr1 = frame + 1;
		uint16_t sys = 0x3f;
		if (pressed(fr1, coin_f, coinrep)) sys &= ~0x01;
		if (pressed(fr1, start_f, startrep)) sys &= ~0x04;
		top->system = sys;
		bool fire = false;
		for (int f : fire_at) fire |= fr1 >= f && fr1 < f + fire_hold;
		top->p1p2 = fire ? 0xffef : 0xffff;
		tick();
		clocks++; frame_clk++;
		if (wlog) {
			auto *r = top->rootp;
			if (r->tb_sys__DOT__u_main__DOT__bus_req && r->tb_sys__DOT__u_main__DOT__bus_ack &&
			    (wlog_reads || r->tb_sys__DOT__u_main__DOT__bus_wr) && !r->tb_sys__DOT__u_main__DOT__bus_io &&
			    r->tb_sys__DOT__u_main__DOT__bus_addr >= wlo && r->tb_sys__DOT__u_main__DOT__bus_addr < whi)
				fprintf(wlog, "%c %llu %08x %x %08x\n", r->tb_sys__DOT__u_main__DOT__bus_wr ? 'W' : 'R',
				        (unsigned long long)ninstr, r->tb_sys__DOT__u_main__DOT__bus_addr, r->tb_sys__DOT__u_main__DOT__bus_be,
				        r->tb_sys__DOT__u_main__DOT__bus_wr ? r->tb_sys__DOT__u_main__DOT__bus_wdata
				                                            : r->tb_sys__DOT__u_main__DOT__bus_rdata);
		}
		{
			auto *r = top->rootp;
			if (bus_pos < mrows.size() && bus_bad < busmax && r->tb_sys__DOT__u_main__DOT__bus_req &&
			    r->tb_sys__DOT__u_main__DOT__bus_ack && !r->tb_sys__DOT__u_main__DOT__bus_io) {
				uint32_t a = r->tb_sys__DOT__u_main__DOT__bus_addr, be = r->tb_sys__DOT__u_main__DOT__bus_be;
				bool wr = r->tb_sys__DOT__u_main__DOT__bus_wr;
				uint32_t d = wr ? r->tb_sys__DOT__u_main__DOT__bus_wdata : r->tb_sys__DOT__u_main__DOT__bus_rdata;
				uint32_t lane = (be & 8 ? 0xff000000u : 0) | (be & 4 ? 0x00ff0000u : 0) | (be & 2 ? 0x0000ff00u : 0) |
				                (be & 1 ? 0x000000ffu : 0);
				uint32_t ra = be == 0xf ? a & ~3u : (be == 0xc || be == 0x3) ? a & ~1u : a;
				const BusRow &m = mrows[bus_pos];
				// the Gradation 2D's IN0 bits 9:8 are MAME's machine().rand()
				uint32_t cmp = (top->board == 1 && !wr && ra == 0xfc000000u) ? lane & ~0x300u : lane;
				if (m.kind != (wr ? 'W' : 'R') || m.addr != ra || m.mask != lane || (m.data & cmp) != (d & cmp)) {
					bus_bad++;
					printf("bustrace: access %zu differs (RTL instr %llu, MAME idx %llu, frame %d)\n"
					       "  RTL  %c %08x data %08x lanes %08x\n  MAME %c %08x data %08x mask %08x\n",
					       bus_pos, (unsigned long long)ninstr, (unsigned long long)m.idx, frame + 1, wr ? 'W' : 'R', ra,
					       d & lane, lane, m.kind, m.addr, m.data & m.mask, m.mask);
				}
				bus_pos++;
			}
		}
		if (wavef) {
			if (top->snd_latch_wr) fprintf(wavef, "L %d %02x\n", frame + 1, top->snd_latch);
			if (top->snd_wave_wr) fprintf(wavef, "W %d %02x %02x\n", frame + 1, top->snd_wave_off, top->snd_wave_data);
		}
		if (penlog) {
			if (top->dbg_pen_rd)
				printf("penread frame %d pen %d x %d y %d\n", frame + 1, (top->dbg_pen_rd & 1) ? 1 : 2,
				       (top->dbg_pen_rd & 1) ? (int)top->pen1_x : 0, (top->dbg_pen_rd & 1) ? (int)top->pen1_y : 0);
			if (top->dbg_trig_rd) trig_reads++;
		}
		if (top->retire) {
			if (pcwin >= 0 && (long)ninstr >= pcwin && (long)ninstr < pcwin + 40)
				printf("  %8llu %08x%s\n", (unsigned long long)ninstr, top->retire_pc,
				       ninstr < mame_pc.size() ? (top->retire_pc == mame_pc[ninstr] ? "" : "  <> MAME") : "");
			ninstr++; frame_instr++;
			if (since_retire >= 64) stall += since_retire;
			since_retire = 0;
			if (!pc_done) {
				if (pc_ok < mame_pc.size() && (top->retire_pc == mame_pc[pc_ok] ||
				    (mame_trap[pc_ok] && top->retire_pc == mame_pc[pc_ok] + 2))) pc_ok++;
				else {
					pc_done = true;
					if (pc_ok < mame_pc.size())
						printf("pctrace: first difference at instruction %llu (frame %d): RTL %08x, MAME %08x\n",
						       (unsigned long long)pc_ok, frame + 1, top->retire_pc, mame_pc[pc_ok]);
				}
				if (pc_ok == mame_pc.size() && !pc_done) {
					pc_done = true;
					printf("pctrace: all %llu instructions agree\n", (unsigned long long)pc_ok);
				}
			}
		} else since_retire++;
		if (top->vbuf != prev_vbuf) { flips++; prev_vbuf = top->vbuf; }
		if (top->ce_pix) {
			if (snapping && !top->hblank && !top->vblank) {
				pix.push_back(top->vid_r); pix.push_back(top->vid_g); pix.push_back(top->vid_b);
			}
			if (!prev_vb && top->vblank) {             // the frame ends
				frame++;
				if (penlog && trig_reads) { printf("trig frame %d in0_reads_down %ld\n", frame, trig_reads); trig_reads = 0; }
				// 320 x 240 shown, 320 x 200 on eolith16
				if (snapping && !pix.empty() && pix.size() % (320 * 3) == 0) {
					char p[512];
					snprintf(p, sizeof p, "%s/f%d.ppm", outd.c_str(), frame);
					FILE *o = fopen(p, "wb");
					fprintf(o, "P6\n320 %d\n255\n", (int)(pix.size() / (320 * 3)));
					fwrite(pix.data(), 1, pix.size(), o);
					fclose(o);
				}
				if (verbose || frame % 60 == 0)
					printf("frame %4d: %7llu instr, %5u I-miss, %6u D-miss, %7llu stall clk of %llu, flips %d\n",
					       frame, (unsigned long long)frame_instr, top->st_imiss - im0, top->st_dmiss - dm0,
					       (unsigned long long)stall, (unsigned long long)frame_clk, flips);
				if (frame == ramdump) {
					char p[512];
					snprintf(p, sizeof p, "%s/ram_f%d.bin", outd.c_str(), frame);
					FILE *o = fopen(p, "wb");
					for (size_t a = 0; a < 0x200000; a++)
						fputc((mem[(ram_base + a) >> 1] >> (8 * (a & 1))) & 0xff, o);
					fclose(o);
				}
				if (frame == eedump) {
					char p[512];
					snprintf(p, sizeof p, "%s/ee_f%d.bin", outd.c_str(), frame);
					FILE *o = fopen(p, "wb");
					for (int a = 0; a < 512; a++) fputc(top->rootp->tb_sys__DOT__u_main__DOT__u_e9__DOT__mem[a], o);
					fclose(o);
				}
				if (perf && frame % 60 == 0) print_perf(top);
				im0 = top->st_imiss; dm0 = top->st_dmiss;
				frame_instr = 0; frame_clk = 0; stall = 0; flips = 0;
				pix.clear();
				snapping = snaps.count(frame + 1) != 0;
			}
			prev_vb = top->vblank;
		}
	}
	if (!pc_done) printf("pctrace: %llu of %zu instructions agree (run ended)\n", (unsigned long long)pc_ok, mame_pc.size());
	if (wavef) fclose(wavef);
	if (!mrows.empty())
		printf("bustrace: %zu of %zu data accesses compared, %d differ%s\n", bus_pos, mrows.size(), bus_bad,
		       bus_bad >= busmax ? " (stopped at +busmax)" : "");
	printf("sound: %u banked-read misses\n", top->snd_xmiss);
	printf("%d frames, %llu instructions, %llu clocks (%.2f clk/instr)\n", frame, (unsigned long long)ninstr,
	       (unsigned long long)clocks, ninstr ? (double)clocks / ninstr : 0.0);
	delete top;
	return 0;
}
