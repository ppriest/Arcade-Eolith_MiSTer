// eo_pens: each stick mode, the d-pad's stepping and its speed-up, the mouse, clamping, flip and the two
// players apart.
//
//   run_verilator.sh pens_tb
//
// Prints one line per check and "PASS n" or "FAIL k of n".
#include "Vtb_pens.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

double sc_time_stamp() { return 0; }

static Vtb_pens *t;
static int n_ok = 0, n_bad = 0;

static void clk() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
// a frame: the frame pulse for one clock, then a few clocks without it
static void frames(int n) { for (int i = 0; i < n; i++) { t->frame = 1; clk(); t->frame = 0; for (int k = 0; k < 3; k++) clk(); } }
static void stick(int p, int x, int y) {
	uint16_t v = (uint16_t)(((uint8_t)(int8_t)y << 8) | (uint8_t)(int8_t)x);
	if (p) t->ana1 = v; else t->ana0 = v;
}
static void check(const char *what, int got, int exp) {
	bool ok = got == exp;
	printf("%-52s %4d  expected %4d  %s\n", what, got, exp, ok ? "ok" : "WRONG");
	ok ? n_ok++ : n_bad++;
}
// one mouse packet: counts as hps_io gives them, 9-bit signed
static void mouse(int dx, int dy) { t->ms_dx = dx & 0x1ff; t->ms_dy = dy & 0x1ff; t->ms_ev = 1; clk(); t->ms_ev = 0; clk(); }
// the module's aim mapping
static int aim_x(int a) { return ((((uint8_t)(int8_t)a) ^ 0x80) * 5) >> 3; }
static int aim_y(int a) { return ((((uint8_t)(int8_t)a) ^ 0x80) * 15) >> 5; }
enum { UP = 8, DOWN = 4, LEFT = 2, RIGHT = 1 };

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vtb_pens;
	t->reset = 1; clk(); clk(); t->reset = 0; clk();
	check("reset: P1 x", t->pen1_x, 80);
	check("reset: P1 y", t->pen1_y, 60);

	// Aim (mode 0, the default), the stick still: the d-pad steps and its position holds
	t->dir0 = RIGHT; frames(1); t->dir0 = 0; frames(1);
	check("a one-frame tap steps 1 unit", t->pen1_x, 81);
	t->dir0 = RIGHT; frames(30); t->dir0 = 0; frames(1);
	check("30 frames held: 12 x 1 then 18 x 3", t->pen1_x, 81 + 12 + 18 * 3);
	t->dir0 = RIGHT; frames(40); t->dir0 = 0; frames(1);
	check("held to the right edge: clamped at 159", t->pen1_x, 159);
	t->dir0 = LEFT; frames(100); t->dir0 = 0; frames(1);
	check("held to the left edge: clamped at 0", t->pen1_x, 0);
	t->dir0 = UP; frames(5); t->dir0 = 0; frames(1);
	check("up 5 frames from 60", t->pen1_y, 55);
	t->dir0 = DOWN; frames(200); t->dir0 = 0; frames(1);
	check("held down: clamped at 119", t->pen1_y, 119);

	// Aim: a moving stick (or a light gun through it) puts the pen where it points, no dead zone
	stick(0, 127, -127); clk(); clk();
	check("Aim, full right: X", t->pen1_x, aim_x(127));
	check("Aim, full up: Y", t->pen1_y, aim_y(-127));
	stick(0, 40, 30); frames(3);
	check("Aim, partial right: X", t->pen1_x, aim_x(40));
	check("Aim, partial down: Y", t->pen1_y, aim_y(30));
	stick(0, 4, -5); frames(3);
	check("Aim, near the centre: X (no dead zone)", t->pen1_x, aim_x(4));
	check("Aim, near the centre: Y (no dead zone)", t->pen1_y, aim_y(-5));
	stick(0, 5, -5); frames(3);
	check("Aim, a change of 1 is ignored", t->pen1_x, aim_x(4));
	stick(0, 0, 0); frames(1);
	check("Aim, the centred stick: X 80, as before", t->pen1_x, 80);
	check("Aim, the centred stick: Y 60, as before", t->pen1_y, 60);
	t->dir0 = LEFT; frames(2); t->dir0 = 0; frames(3);
	check("Aim, the d-pad's position holds, stick still", t->pen1_x, 78);
	t->ms_to = 1; mouse(10, 5); frames(3);
	check("Aim, the mouse's position holds, stick still: X", t->pen1_x, 88);
	check("Aim, the mouse's position holds, stick still: Y", t->pen1_y, 55);
	t->ms_to = 0;
	stick(0, -40, 0); clk(); clk();
	check("Aim, the stick moving takes the pen back", t->pen1_x, aim_x(-40));
	int x = t->pen1_x, y = t->pen1_y;

	// D-pad: any deflection past the dead zone steps
	t->mode0 = 2; stick(0, 0, 0); frames(1);
	stick(0, -40, 0); frames(5); stick(0, 0, 0); frames(1);
	check("D-pad mode, partial left 5 frames", t->pen1_x, x - 5);
	stick(0, 0, 20); frames(4); stick(0, 0, 0); frames(1);
	check("D-pad mode, partial down 4 frames", t->pen1_y, y + 4);
	stick(0, 4, 0); frames(4);
	check("D-pad mode, inside the dead zone: held", t->pen1_x, x - 5);

	// Auto: a partial deflection aims, a full one steps, a resting stick holds
	t->mode0 = 1;
	stick(0, 40, 0); clk(); clk();
	check("Auto, partial right aims", t->pen1_x, aim_x(40));
	stick(0, 120, 0); frames(3); stick(0, 0, 0); frames(1);
	check("Auto, full right steps 3 frames", t->pen1_x, aim_x(40) + 3);

	// flip: the game sees the turned position
	x = t->pen1_x; y = t->pen1_y;
	t->flip = 1; t->eval();
	check("flip: X as 159 - x", t->pen1_x, 159 - x);
	check("flip: Y as 119 - y", t->pen1_y, 119 - y);
	t->dir0 = RIGHT; frames(1); t->dir0 = 0; frames(1);
	check("flip: right moves the shown pen right", 159 - t->pen1_x, x + 1);
	t->flip = 0; t->eval();

	// P2 apart from P1 (P2 in Aim, its stick still)
	x = t->pen1_x;
	t->dir1 = RIGHT; frames(3); t->dir1 = 0; frames(1);
	check("P2 steps on its own d-pad", t->pen2_x, 83);
	check("P1 unmoved by P2's d-pad", t->pen1_x, x);
	stick(1, -127, 127); clk(); clk();
	check("P2 Aim: X", t->pen2_x, aim_x(-127));
	check("P2 Aim: Y", t->pen2_y, aim_y(127));
	check("P1 unmoved by P2's stick", t->pen1_x, x);

	// the mouse: counts move the pen of the player it is given to; Y positive up; off moves nobody
	frames(1);
	x = t->pen1_x; y = t->pen1_y; int x2 = t->pen2_x;
	t->ms_to = 1; mouse(10, 5);
	check("mouse to P1: +10 X", t->pen1_x, x + 10);
	check("mouse to P1: +5 up is Y - 5", t->pen1_y, y - 5);
	check("mouse to P1: P2 unmoved", t->pen2_x, x2);
	for (int i = 0; i < 4; i++) mouse(255, -256);
	check("mouse: clamped at X 159", t->pen1_x, 159);
	check("mouse: -256 (down) clamped at Y 119", t->pen1_y, 119);
	mouse(-256, 255); check("mouse: -256 X clamped at 0", t->pen1_x, 0);
	check("mouse: +255 up clamped at Y 0", t->pen1_y, 0);
	t->ms_to = 2; mouse(20, 0);
	check("mouse to P2: +20 X", t->pen2_x, x2 + 20);
	check("mouse to P2: P1 unmoved", t->pen1_x, 0);
	t->ms_to = 0; mouse(30, 30);
	check("mouse off: P1 unmoved", t->pen1_x, 0);
	check("mouse off: P2 unmoved", t->pen2_x, x2 + 20);

	if (n_bad) printf("FAIL %d of %d\n", n_bad, n_ok + n_bad);
	else printf("PASS %d\n", n_ok);
	delete t;
	return n_bad ? 1 : 0;
}
