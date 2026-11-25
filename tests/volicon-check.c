/*
 * platform: macOS-only -- reads .icns files with ImageIO and compares their pixels with CoreGraphics
 * usage: volicon-check BASE.icns OUT.icns EDGE INSET
 *        What tests/volicon-test.sh asks of linuxfs-volicon's OUT, made from BASE: the same representations (each pixel
 *        size at each DPI, so @2x too), and in each one BASE's pixels everywhere but a square box in the lower-right
 *        corner, EDGE of the icon's edge on a side and INSET of it from the right and bottom, where Tux is drawn (a
 *        good part of the box changed). Prints "ok - ..." or "not ok - ..." lines (the test numbers them); exits 1
 *        on any "not ok", 2 on misuse or an unreadable file.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXREP 32
#define SAME_TOLERANCE 2	/* a channel may move this much through decoding and encoding again */
#define CHANGED 48	/* a channel moved this much is Tux */

static int bad;

static void expect(int ok, const char *fmt, size_t w, int dpi, const char *more)
{
	printf("%s - ", ok ? "ok" : "not ok");
	printf(fmt, w, dpi, more);
	printf("\n");
	if (!ok)
		bad = 1;
}

struct rep {
	size_t w, h;
	int dpi;
	CGImageRef im;
};

static int load(const char *path, struct rep *r, size_t *n)
{
	CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	CGImageSourceRef s = u ? CGImageSourceCreateWithURL(u, NULL) : NULL;
	size_t i;

	if (u)
		CFRelease(u);
	if (!s || !CGImageSourceGetType(s) || !CFEqual(CGImageSourceGetType(s), CFSTR("com.apple.icns")))
		return -1;
	*n = CGImageSourceGetCount(s);
	if (*n > MAXREP)
		return -1;
	for (i = 0; i < *n; i++) {
		CFDictionaryRef p = CGImageSourceCopyPropertiesAtIndex(s, i, NULL);
		CFNumberRef d = p ? CFDictionaryGetValue(p, kCGImagePropertyDPIWidth) : NULL;
		double dpi = 72;

		if (d)
			CFNumberGetValue(d, kCFNumberDoubleType, &dpi);
		r[i].dpi = (int)(dpi + 0.5);
		r[i].im = CGImageSourceCreateImageAtIndex(s, i, NULL);
		if (!r[i].im)
			return -1;
		r[i].w = CGImageGetWidth(r[i].im);
		r[i].h = CGImageGetHeight(r[i].im);
		if (p)
			CFRelease(p);
	}
	CFRelease(s);
	return 0;
}

/* IM's pixels as premultiplied RGBA, 8 bits, sRGB; row 0 is the top */
static unsigned char *pixels(CGImageRef im, size_t w, size_t h)
{
	unsigned char *px = calloc(w * h, 4);
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef c = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);

	CGContextDrawImage(c, CGRectMake(0, 0, w, h), im);
	CGContextRelease(c);
	CGColorSpaceRelease(cs);
	return px;
}

int main(int argc, char **argv)
{
	struct rep b[MAXREP], o[MAXREP];
	size_t nb, no, i, j, x, y;
	double edgef, insetf;

	if (argc != 5) {
		fprintf(stderr, "usage: volicon-check BASE.icns OUT.icns EDGE INSET\n");
		return 2;
	}
	edgef = atof(argv[3]);
	insetf = atof(argv[4]);
	if (load(argv[1], b, &nb) || nb == 0) {
		fprintf(stderr, "volicon-check: %s is not a readable .icns\n", argv[1]);
		return 2;
	}
	if (load(argv[2], o, &no)) {
		printf("not ok - %s is a readable .icns\n", argv[2]);
		return 1;
	}
	printf("%s - the composite has as many representations as the base (%zu, base %zu)\n", no == nb ? "ok" : "not ok", no, nb);
	if (no != nb)
		bad = 1;
	for (i = 0; i < nb; i++) {
		unsigned char *bp, *op;
		size_t edge, inset, x0, x1, y0, y1, inside = 0, changed = 0, outside_off = 0;
		int maxd = 0;

		for (j = 0; j < no; j++)
			if (o[j].w == b[i].w && o[j].h == b[i].h && o[j].dpi == b[i].dpi)
				break;
		expect(j < no, "the composite has the base's %zux at %d dpi%s", b[i].w, b[i].dpi, "");
		if (j == no)
			continue;
		bp = pixels(b[i].im, b[i].w, b[i].h);
		op = pixels(o[j].im, o[j].w, o[j].h);
		edge = (size_t)(edgef * b[i].w + 0.5);
		inset = (size_t)(insetf * b[i].w + 0.5);
		/* the box in rows from the top: x0..x1, y0..y1 (exclusive), one pixel more each way for antialiasing */
		x1 = b[i].w - inset;
		x0 = x1 - edge;
		y1 = b[i].h - inset;
		y0 = y1 - edge;
		for (y = 0; y < b[i].h; y++)
			for (x = 0; x < b[i].w; x++) {
				unsigned char *p = bp + (y * b[i].w + x) * 4, *q = op + (y * b[i].w + x) * 4;
				int k, d = 0;
				int in = x >= x0 && x < x1 && y >= y0 && y < y1;
				int near = x + 1 >= x0 && x <= x1 && y + 1 >= y0 && y <= y1;

				for (k = 0; k < 4; k++)
					if (abs(p[k] - q[k]) > d)
						d = abs(p[k] - q[k]);
				if (in) {
					inside++;
					changed += d >= CHANGED;
				} else if (!near && d > SAME_TOLERANCE) {
					outside_off++;
					if (d > maxd)
						maxd = d;
				}
			}
		{
			char more[96];

			snprintf(more, sizeof(more), " (%zu pixels off, by up to %d)", outside_off, maxd);
			expect(outside_off == 0, "%zux at %d dpi: outside the lower-right box, the base's own pixels%s", b[i].w, b[i].dpi, more);
			snprintf(more, sizeof(more), " (%zu of %zu)", changed, inside);
			expect(changed * 10 >= inside, "%zux at %d dpi: Tux is in the box, a tenth of it or more changed%s", b[i].w, b[i].dpi, more);
		}
		free(bp);
		free(op);
	}
	return bad;
}
