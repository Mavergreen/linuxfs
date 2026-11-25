/*
 * platform: macOS-only -- CoreGraphics draws and ImageIO reads and writes .icns, on Mac OS X 10.9
 *   usage: linuxfs-volicon BASE.icns TUX.png OUT.icns
 *          linuxfs's volume icon (spec: item 6's amendment): every representation of BASE (each size at each DPI, @2x
 *          too), with Tux drawn into its lower-right corner, written as OUT with the same representations. The pkg's
 *          postinstall runs it on the target Mac with that Mac's own External.icns (IOStorageFamily.kext), so no Apple
 *          artwork is shipped, and writes each macfuse_<fs>.fs bundle's Contents/Resources/linuxfs.icns, which linuxfs
 *          hands lklfuse as volicon=. OUT is made 0644 in a temporary file beside it, read back and checked, then
 *          renamed over it: on any failure nothing is written and OUT, if there was one, is as it was. Exit 0 on
 *          success, 1 on failure (said on stderr), 2 on misuse.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Tux's place: a square box TUX_EDGE of the icon's edge on a side, TUX_INSET of it in from the right and the bottom; Tux
 * keeps its proportions and stands in the box's lower-right corner */
#define TUX_EDGE 0.45
#define TUX_INSET 0.06
#define ICNS CFSTR("com.apple.icns")
#define MAXREP 64

static const char *prog = "linuxfs-volicon";

static int fail(const char *what, const char *path)
{
	fprintf(stderr, "%s: %s%s%s\n", prog, what, path ? ": " : "", path ? path : "");
	return 1;
}

static CGImageSourceRef source(const char *path)
{
	CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
	CGImageSourceRef s = u ? CGImageSourceCreateWithURL(u, NULL) : NULL;

	if (u)
		CFRelease(u);
	if (s && (CGImageSourceGetStatus(s) != kCGImageStatusComplete || !CGImageSourceGetType(s) ||
		  CGImageSourceGetCount(s) == 0)) {
		CFRelease(s);
		s = NULL;
	}
	return s;
}

static double dpi_of(CFDictionaryRef props)
{
	CFNumberRef n = props ? CFDictionaryGetValue(props, kCGImagePropertyDPIWidth) : NULL;
	double d = 72;

	if (n)
		CFNumberGetValue(n, kCFNumberDoubleType, &d);
	return d;
}

/* BASE's image IM (W by H pixels) with TUX in its lower-right corner, as a new image; NULL on failure */
static CGImageRef composite(CGImageRef im, size_t w, size_t h, CGImageRef tux)
{
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef c = cs ? CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedLast) : NULL;
	CGImageRef out = NULL;
	double side = (w < h ? w : h), edge = TUX_EDGE * side, inset = TUX_INSET * side;
	double tw = CGImageGetWidth(tux), th = CGImageGetHeight(tux), scale = edge / (tw > th ? tw : th);

	if (c) {
		CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
		CGContextDrawImage(c, CGRectMake(0, 0, w, h), im);
		/* Core Graphics' origin is the lower left: Tux's right edge and bottom are the box's */
		CGContextDrawImage(c, CGRectMake(w - inset - tw * scale, inset, tw * scale, th * scale), tux);
		out = CGBitmapContextCreateImage(c);
		CGContextRelease(c);
	}
	if (cs)
		CGColorSpaceRelease(cs);
	return out;
}

struct rep {
	size_t w, h;
	double dpi;
};

/* A and B hold the same representations, matched one to one (each of B used once), so the sets are equal both ways */
static int same_reps(const struct rep *a, size_t na, const struct rep *b, size_t nb)
{
	char used[MAXREP] = { 0 };
	size_t i, j;

	if (na != nb || nb > MAXREP)
		return 0;
	for (i = 0; i < na; i++) {
		for (j = 0; j < nb; j++)
			if (!used[j] && a[i].w == b[j].w && a[i].h == b[j].h &&
			    (int)(a[i].dpi + 0.5) == (int)(b[j].dpi + 0.5))
				break;
		if (j == nb)
			return 0;
		used[j] = 1;
	}
	return 1;
}

int main(int argc, char **argv)
{
	CGImageSourceRef base, tuxs, back;
	CGImageDestinationRef dest;
	CFMutableDataRef data;
	CGImageRef tux;
	struct rep want[MAXREP], got[MAXREP];
	size_t n, i, len;
	char tmp[PATH_MAX];
	const char *out;
	int fd, ok;

	if (argc != 4) {
		fprintf(stderr, "usage: %s BASE.icns TUX.png OUT.icns\n", prog);
		return 2;
	}
	out = argv[3];
	base = source(argv[1]);
	if (!base || !CFEqual(CGImageSourceGetType(base), ICNS))
		return fail("not a readable .icns", argv[1]);
	n = CGImageSourceGetCount(base);
	if (n > MAXREP)
		return fail("too many representations", argv[1]);
	tuxs = source(argv[2]);
	tux = tuxs ? CGImageSourceCreateImageAtIndex(tuxs, 0, NULL) : NULL;
	if (!tux || CGImageGetWidth(tux) == 0 || CGImageGetHeight(tux) == 0)
		return fail("not a readable image", argv[2]);

	data = CFDataCreateMutable(NULL, 0);
	dest = data ? CGImageDestinationCreateWithData(data, ICNS, n, NULL) : NULL;
	if (!dest)
		return fail("cannot make an .icns", NULL);
	for (i = 0; i < n; i++) {
		CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(base, i, NULL);
		CGImageRef im = CGImageSourceCreateImageAtIndex(base, i, NULL), c;
		CFNumberRef d;
		CFDictionaryRef keep;
		const void *k[2] = { kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight }, *v[2];

		if (!im)
			return fail("cannot read a representation of", argv[1]);
		want[i].w = CGImageGetWidth(im);
		want[i].h = CGImageGetHeight(im);
		want[i].dpi = dpi_of(props);
		c = composite(im, want[i].w, want[i].h, tux);
		if (!c)
			return fail("cannot draw a representation of", argv[1]);
		/* the DPI is what tells a @2x representation from the plain one of the same pixel size (ic11-ic14) */
		d = CFNumberCreate(NULL, kCFNumberDoubleType, &want[i].dpi);
		v[0] = v[1] = d;
		keep = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CGImageDestinationAddImage(dest, c, keep);
		CFRelease(keep);
		CFRelease(d);
		CGImageRelease(c);
		CGImageRelease(im);
		if (props)
			CFRelease(props);
	}
	if (!CGImageDestinationFinalize(dest))
		return fail("cannot write an .icns", NULL);

	/* read back: the same representations, every one of them, or nothing is written */
	back = CGImageSourceCreateWithData(data, NULL);
	ok = back && CGImageSourceGetType(back) && CFEqual(CGImageSourceGetType(back), ICNS) &&
	     CGImageSourceGetCount(back) == n;
	for (i = 0; ok && i < n; i++) {
		CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(back, i, NULL);
		CGImageRef im = CGImageSourceCreateImageAtIndex(back, i, NULL);

		ok = im != NULL;
		if (im) {
			got[i].w = CGImageGetWidth(im);
			got[i].h = CGImageGetHeight(im);
			got[i].dpi = dpi_of(props);
			CGImageRelease(im);
		}
		if (props)
			CFRelease(props);
	}
	if (!ok || !same_reps(want, n, got, n))
		return fail("the .icns written does not hold every representation of", argv[1]);

	if (snprintf(tmp, sizeof(tmp), "%s.XXXXXX", out) >= (int)sizeof(tmp))
		return fail("name too long", out);
	fd = mkstemp(tmp);
	if (fd < 0)
		return fail(strerror(errno), out);
	len = CFDataGetLength(data);
	ok = fchmod(fd, 0644) == 0 && write(fd, CFDataGetBytePtr(data), len) == (ssize_t)len && fsync(fd) == 0;
	ok = close(fd) == 0 && ok;
	if (!ok || rename(tmp, out) != 0) {
		int e = errno;

		unlink(tmp);
		return fail(strerror(e), out);
	}
	return 0;
}
