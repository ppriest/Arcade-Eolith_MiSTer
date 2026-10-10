// The 93C66 against MAME: scripts/mame/eeprom_log.lua's pin traffic replayed at MAME's times, the DO bit of
// every IN0 read compared.
//
//   run_verilator.sh ee_tb +log=<debug/ee/set.log> [+dump=<file>] [+max=10]
//
// Each "W <seconds> <data>" sets CS, CLK and DI from bits 1-3 at that time, in clocks of 630/11 MHz from
// MAME's power-on (the release of rst); each "R <seconds> <data>" compares bit 3 with the part's DO in
// that clock. The array is all ones at the start (MAME's blank EEPROM); +dump writes it at the end, 512
// bytes, as MAME saves nvram/<set>/eeprom.
#include "Vtb_ee.h"
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
	std::string logp = arg(argc, argv, "+log="), dump = arg(argc, argv, "+dump=");
	int maxbad = atoi(arg(argc, argv, "+max=", "10").c_str());
	struct Ev { char k; uint64_t clk; uint32_t d; double t; };
	std::vector<Ev> ev;
	FILE *f = fopen(logp.c_str(), "r");
	if (!f) { fprintf(stderr, "cannot open +log=%s\n", logp.c_str()); return 2; }
	char line[256];
	const double CLK_HZ = 630e6 / 11.0;
	while (fgets(line, sizeof line, f)) {
		char k; double t; unsigned d;
		if (sscanf(line, "%c %lf %x", &k, &t, &d) == 3 && (k == 'W' || k == 'R'))
			ev.push_back({k, (uint64_t)(t * CLK_HZ + 0.5), d, t});
	}
	fclose(f);

	Vtb_ee *top = new Vtb_ee;
	auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };
	top->rst = 1; top->cs = 0; top->sk = 0; top->di = 0; top->rd_addr = 0;
	for (int i = 0; i < 4; i++) tick();
	top->rst = 0;
	uint64_t now = 0;
	long reads = 0, writes = 0, bad = 0, nwritten = 0;
	for (size_t i = 0; i < ev.size(); i++) {
		const Ev &e = ev[i];
		while (now < e.clk) { tick(); now++; if (top->written) nwritten++; }
		if (e.k == 'W') {
			top->cs = (e.d >> 1) & 1; top->sk = (e.d >> 2) & 1; top->di = (e.d >> 3) & 1;
			top->eval();
			writes++;
		} else {
			top->eval();
			int want = (e.d >> 3) & 1;
			reads++;
			if (top->dout != want && bad++ < maxbad)
				printf("read %ld (event %zu, %.9f s): DO %d, MAME %d\n", reads, i, e.t, top->dout, want);
		}
	}
	for (int i = 0; i < 4; i++) { tick(); if (top->written) nwritten++; }
	printf("%ld writes, %ld reads replayed; %ld DO differences; %ld array changes\n", writes, reads, bad, nwritten);
	if (!dump.empty()) {
		FILE *o = fopen(dump.c_str(), "wb");
		for (int a = 0; a < 512; a++) {
			top->rd_addr = a; tick(); tick();
			fputc(top->rd_data, o);
		}
		fclose(o);
	}
	delete top;
	return bad ? 1 : 0;
}
