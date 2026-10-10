// The Vega sound board against MAME, alone: MAME's latch commands in, the voice-register writes out.
//
//   run_verilator.sh snd_tb +img=<image.bin> +mame=<mame_wave.txt> +out=<rtl_wave.txt> [+frames=N]
//
// +img is the download image (scripts/build_mra.py --image); the chip model's array is loaded from it
// and the 8052's program (the first 32 KB at SD_SNDPRG) goes in through the board's download port with
// rst held. +mame is scripts/mame/qs1000_wave.lua's log: each "L <frame> <data> <seconds>" is written to
// the latch at that time, counted in clocks of 630/11 MHz from the release of rst (MAME's power-on); a line
// without the time, at the start of that frame (954,545 clocks a MAME frame). The board's latch and register writes go to +out in the
// same format, for scripts/qs1000_wave_compare.py --no-capture, and its banked data reads ("R <frame> <addr> <data>").
#include "Vtb_snd.h"
#include "Vtb_snd___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <fcntl.h>

double sc_time_stamp() { return 0; }

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

int main(int argc, char **argv) {
#ifdef _WIN32
	_fmode = _O_BINARY;
#endif
	Verilated::commandArgs(argc, argv);
	std::string imgp = arg(argc, argv, "+img="), mamep = arg(argc, argv, "+mame="), outp = arg(argc, argv, "+out=");
	FILE *f = fopen(imgp.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open +img=%s\n", imgp.c_str()); return 2; }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> img(n);
	if (fread(img.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
	fclose(f);

	struct Cmd { uint64_t clk; int frame; uint8_t d; };
	std::vector<Cmd> cmds;
	int last_frame = 0;
	FILE *m = fopen(mamep.c_str(), "r");
	if (!m) { fprintf(stderr, "cannot open +mame=%s\n", mamep.c_str()); return 2; }
	const uint64_t CPF = 954545;
	char line[256];
	while (fgets(line, sizeof line, m)) {
		int fr; unsigned d, o;
		double tsec;
		int nf = line[0] == 'L' ? sscanf(line + 1, "%d %x %lf", &fr, &d, &tsec) : 0;
		if (nf >= 2) {
			// at MAME's time where the log has it (seconds x 630/11 MHz from the release of rst, which is
			// MAME's power-on), else at the start of the frame
			uint64_t c = nf == 3 ? (uint64_t)(tsec * 57272727.27 + 0.5) : (uint64_t)(fr - 1) * CPF;
			if (nf == 2 && !cmds.empty() && cmds.back().frame == fr) c = cmds.back().clk + 20000;
			cmds.push_back({c, fr, (uint8_t)d});
			if (fr > last_frame) last_frame = fr;
		} else if (line[0] == 'W' && sscanf(line + 1, "%d %x %x", &fr, &o, &d) == 3) {
			if (fr > last_frame) last_frame = fr;
		}
	}
	fclose(m);
	int nframes = atoi(arg(argc, argv, "+frames=", std::to_string(last_frame).c_str()).c_str());
	printf("%zu latch commands, %d frames\n", cmds.size(), nframes);

	Vtb_snd *t = new Vtb_snd;
	auto &mem = t->rootp->tb_snd__DOT__u_chip__DOT__mem;
	for (size_t i = 0; i + 1 < img.size(); i += 2)
		mem[i >> 1] = (uint16_t)(img[i] | (img[i + 1] << 8));
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
	t->rst = 1; t->dl_we = 0; t->latch_wr = 0;
	int board = atoi(arg(argc, argv, "+board=", "0").c_str());   // 0 Vega, 1 Gradation 2D (the sound CPU too)
	t->board = board;
	const size_t SD_SNDPRG = 0x2080000, SD_SNDCPU = 0x2088000;
	for (int i = 0; i < 0x8000; i++) {
		t->dl_we = 1; t->dl_addr = i; t->dl_data = img[SD_SNDPRG + i];
		tick();
	}
	for (int i = 0; board == 1 && i < 0x8000; i++) {
		t->dl_we = 1; t->dl_addr = 0x8000 | i; t->dl_data = img[SD_SNDCPU + i];
		tick();
	}
	t->dl_we = 0;
	for (int i = 0; i < 20000; i++) tick();       // the SDRAM's initialisation
	t->rst = 0;

	FILE *o = fopen(outp.c_str(), "w");
	size_t ci = 0;
	uint64_t nw = 0;
	int prev_pend = 0;
	int prev_txd = 1;
	bool txlog = atoi(arg(argc, argv, "+txlog=", "0").c_str()) != 0;   // board 1: "T <clock> <level>" at each TxD edge
	// +pcwin=F: the 8052's PC, at each change, for +pclen clocks (200,000) from the start of MAME frame F
	long pcwin = atol(arg(argc, argv, "+pcwin=", "-1").c_str());
	uint64_t pclen = strtoull(arg(argc, argv, "+pclen=", "200000").c_str(), nullptr, 10);   // clocks traced
	auto &pcref = t->rootp->tb_snd__DOT__u_snd__DOT__u_mcu__DOT__u_regs__DOT__pc;
	unsigned last_pc = 0x10000;
	// +scpc=F1,F2 (board 1): the sound CPU's PC at each change, frames F1 to F2 ("c <frame> <pc>")
	int scf1 = -1, scf2 = -1;
	sscanf(arg(argc, argv, "+scpc=", "").c_str(), "%d,%d", &scf1, &scf2);
	auto &scpc = t->rootp->tb_snd__DOT__u_scpu__DOT__u_mcu__DOT__u_regs__DOT__pc;
	auto &sca = t->rootp->tb_snd__DOT__u_scpu__DOT__u_mcu__DOT__u_regs__DOT__a;
	auto &scsp = t->rootp->tb_snd__DOT__u_scpu__DOT__u_mcu__DOT__u_regs__DOT__sp;
	unsigned last_scpc = 0x10000;
	for (uint64_t c = 0; c < (uint64_t)nframes * CPF; c++) {
		t->latch_wr = 0;
		if (ci < cmds.size() && c >= cmds[ci].clk) {
			t->latch_wr = 1; t->latch_d = cmds[ci].d;
			fprintf(o, "L %d %02x\n", (int)(c / CPF) + 1, cmds[ci].d);
			ci++;
		}
		tick();
		if (pcwin > 0 && c >= (uint64_t)(pcwin - 1) * CPF && c < (uint64_t)(pcwin - 1) * CPF + pclen && pcref != last_pc) {
			fprintf(o, "C %llu %04x\n", (unsigned long long)(c - (uint64_t)(pcwin - 1) * CPF), pcref);
			last_pc = pcref;
		}
		if (scf1 > 0 && (int)(c / CPF) + 1 >= scf1 && (int)(c / CPF) + 1 <= scf2 && scpc != last_scpc) {
			fprintf(o, "c %d %04x a=%02x sp=%02x\n", (int)(c / CPF) + 1, scpc, sca, scsp);
			last_scpc = scpc;
		}
		if (t->xrd && t->xrd_addr >= 0x100) fprintf(o, "R %d %04x %02x\n", (int)(c / CPF) + 1, t->xrd_addr, t->xrd_data);
		if (board == 1 && t->txd_o != prev_txd) {
			if (txlog) fprintf(o, "T %llu %d\n", (unsigned long long)c, t->txd_o);
			prev_txd = t->txd_o;
		}
		if (board == 1 && t->sxrd) fprintf(o, "S %d %04x %02x\n", (int)(c / CPF) + 1, t->sxrd_addr, t->sxrd_data);
		if (t->pending != prev_pend) { fprintf(o, "P %d %d\n", (int)(c / CPF) + 1, t->pending); prev_pend = t->pending; }
		if (t->p3we) fprintf(o, "3 %d %02x\n", (int)(c / CPF) + 1, t->p3);
		if (t->wave_wr) {
			fprintf(o, "W %d %02x %02x\n", (int)(c / CPF) + 1, t->wave_off, t->wave_data);
			nw++;
		}
	}
	fclose(o);
	printf("%llu register writes; banked-read misses %u (sound CPU %u), engine queue drops %u, ROM stalls %u\n",
	       (unsigned long long)nw, t->xmiss, t->sxmiss, t->drops, t->stalls);
	printf("8052: %u enables of %u nominal, most owed %u, %u clocks waiting on banked reads\n",
	       t->cens, t->noms, t->debtmax, t->stallclk);
	delete t;
	return 0;
}
