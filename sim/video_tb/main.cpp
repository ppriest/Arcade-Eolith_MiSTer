// eo_video against a MAME capture (scripts/eolith_capture.py).
//
//   run_verilator.sh video_tb +dir=<capture dir> +frame=<N> +buf=<b> +out=<file.ppm>
//
// Loads both buffers of f<N>_vram.bin and the palette f<N>_palette.bin through the CPU port
// (the dumps hold no 0xff byte, so the write filter does not lose any), selects buffer <b> for
// the CPU as MAME had it, runs two frames with ce_pix every 8 clk, and writes the second frame's
// shown dots (hblank and vblank low) as a binary PPM.
#include "Vtb_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::string arg(int argc, char **argv, const char *key, const char *def = "") {
	size_t n = strlen(key);
	for (int i = 1; i < argc; i++)
		if (!strncmp(argv[i], key, n)) return std::string(argv[i] + n);
	return def;
}

static std::vector<uint8_t> slurp(const std::string &p) {
	std::vector<uint8_t> v;
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
	uint8_t buf[65536];
	size_t k;
	while ((k = fread(buf, 1, sizeof buf, f)) > 0) v.insert(v.end(), buf, buf + k);
	fclose(f);
	return v;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string dir = arg(argc, argv, "+dir=");
	std::string fr = arg(argc, argv, "+frame=");
	int bufsel = atoi(arg(argc, argv, "+buf=", "0").c_str());
	std::string out = arg(argc, argv, "+out=", "video.ppm");
	auto vram = slurp(dir + "/f" + fr + "_vram.bin");
	auto pal = slurp(dir + "/f" + fr + "_palette.bin");
	// the board from the dump: vegaeo's m_vram is uint8[0x28000] with a palette, eolith's uint16[0x40000]
	// in host (little-endian) order without one, eolith16's uint8[0x20000] without one
	int board = vram.size() == 0x80000 ? 1 : vram.size() == 0x20000 ? 2 : 0;
	if (board == 0 ? (vram.size() != 0x28000 || pal.size() != 512) : !pal.empty()) {
		fprintf(stderr, "bad dump sizes\n");
		return 1;
	}

	Vtb_video *t = new Vtb_video;
	auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
	t->board = board;
	t->flip = atoi(arg(argc, argv, "+flip=", "0").c_str());   // +flip=1: the picture turned 180 degrees
	// +xh=X1,Y1,X2,Y2: the light pens' crosses at those dots (the game's units doubled), both drawn
	{
		int x1 = -1, y1 = 0, x2 = 0, y2 = 0;
		sscanf(arg(argc, argv, "+xh=", "").c_str(), "%d,%d,%d,%d", &x1, &y1, &x2, &y2);
		t->cross_en = x1 >= 0 ? 3 : 0;
		t->cx1 = x1 >= 0 ? x1 : 0; t->cy1 = y1; t->cx2 = x2; t->cy2 = y2;
	}
	t->ce_pix = 0; t->cpu_vram_cs = 0; t->cpu_pal_cs = 0; t->cpu_we = 0;
	tick();

	for (int k = 0; k < 2; k++) {
		t->vbuf = k;
		if (board == 0) {
			for (int i = 0; i < 0x5000; i++) {
				const uint8_t *p = &vram[k * 0x14000 + i * 4];
				t->cpu_vram_cs = 1; t->cpu_we = 1; t->cpu_be = 0xf; t->cpu_addr = i;
				t->cpu_wdata = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
				tick();
			}
		} else if (board == 2) {
			// MAME's share is in host order (each halfword's low byte first); the CPU's view swaps each pair
			for (int i = 0; i < 0x4000; i++) {
				const uint8_t *p = &vram[k * 0x10000 + i * 4];
				t->cpu_vram_cs = 1; t->cpu_we = 1; t->cpu_be = 0xf; t->cpu_addr = i;
				t->cpu_wdata = (uint32_t)p[1] << 24 | (uint32_t)p[0] << 16 | (uint32_t)p[3] << 8 | p[2];
				tick();
			}
		} else {
			// lines 0-239 of buffer k (336 halfwords a line), two halfwords a dword
			auto h = [&](int i) { return (uint32_t)vram[2 * i] | (uint32_t)vram[2 * i + 1] << 8; };
			for (int d = 0; d < 240 * 336 / 2; d++) {
				t->cpu_vram_cs = 1; t->cpu_we = 1; t->cpu_be = 0xf; t->cpu_addr = d;
				t->cpu_wdata = h(k * 0x20000 + 2 * d) << 16 | h(k * 0x20000 + 2 * d + 1);
				tick();
			}
		}
	}
	t->cpu_vram_cs = 0;
	for (int i = 0; i < (board == 0 ? 256 : 0); i++) {
		t->cpu_pal_cs = 1; t->cpu_we = 1; t->cpu_be = 0x3; t->cpu_addr = i;
		t->cpu_wdata = (uint32_t)pal[2 * i] << 8 | pal[2 * i + 1];
		tick();
	}
	t->cpu_pal_cs = 0; t->cpu_we = 0;
	t->vbuf = bufsel;

	std::vector<uint8_t> img;
	int frames = 0, prev_vb = 1;
	for (long c = 0; frames < 3 && c < 20000000; c++) {
		t->ce_pix = (c % 8) == 0;
		tick();
		if (!t->ce_pix) continue;
		if (prev_vb && !t->vblank) frames++;
		prev_vb = t->vblank;
		if (frames == 2 && !t->hblank && !t->vblank) {
			img.push_back(t->r); img.push_back(t->g); img.push_back(t->b);
		}
	}
	const int lines = board == 2 ? 200 : 240;    // eolith16 shows 200
	if (img.size() != (size_t)320 * lines * 3) { fprintf(stderr, "captured %zu dots\n", img.size() / 3); return 1; }
	FILE *f = fopen(out.c_str(), "wb");
	fprintf(f, "P6\n320 %d\n255\n", lines);
	fwrite(img.data(), 1, img.size(), f);
	fclose(f);
	printf("wrote %s\n", out.c_str());
	delete t;
	return 0;
}
