/* Regression test for the out-of-bounds framebuffer read that crashed
 * FotCotVNC 2026.7 (EXC_BAD_ACCESS in _platform_memmove, via NSDrawBitmap).
 *
 * Run with Tests/run_tests.sh. There is no Xcode test target; this is a
 * standalone program so it compiles and runs in one step:
 *
 *   clang -Wall -framework Foundation -ISource Tests/test_fbclip.m -o /tmp/t && /tmp/t
 *
 * Where the old, crashing logic differed, a replica of it (legacyClip) first
 * asserts that the bug was real and reachable, so these tests keep their teeth
 * if the fix is ever reverted.
 */

#import <Foundation/Foundation.h>
#import "FrameBufferClip.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...) do {                                   \
    checks++;                                                   \
    if (!(cond)) {                                              \
        failures++;                                             \
        fprintf(stderr, "FAIL %s:%d: ", __func__, __LINE__);    \
        fprintf(stderr, __VA_ARGS__);                           \
        fprintf(stderr, "\n");                                  \
    }                                                           \
} while (0)

/* ---------------------------------------------------------------------------
 * A faithful replica of the ORIGINAL clamping logic from
 * -[FrameBuffer drawRect:at:] (FrameBufferDrawing.h, before the fix), used
 * only to demonstrate that the crash is real and reachable.
 * Returns YES if the original code would have proceeded to draw.
 * ------------------------------------------------------------------------- */
static BOOL legacyClip(NSRect *r, NSSize size, int *yshiftOut)
{
    if (NSMaxX(*r) >= size.width) {
        r->size.width = size.width - r->origin.x;
    }
    int yshift = 0;
    if (NSMaxY(*r) >= size.height) {
        r->size.height -= 1;
        yshift = 1;
    }
    if (r->origin.x < 0 || r->origin.y < 0 ||
        r->size.width <= 0 || r->size.height <= 0) {
        return NO;
    }
    *yshiftOut = yshift;
    return YES;
}

/* Highest byte offset NSDrawBitmap will touch, given a framebuffer-space rect.
 * It reads r.size.height rows at a stride of size.width*bpp, consuming
 * r.size.width*bpp bytes of each row, starting at the rect's origin. */
static long lastByteTouched(NSRect r, NSSize size, int bpp)
{
    long bpr   = (long)size.width * bpp;
    long start = (long)r.origin.y * (long)size.width + (long)r.origin.x;
    return start * bpp + ((long)r.size.height - 1) * bpr + (long)r.size.width * bpp - 1;
}

static long bufferBytes(NSSize size, int bpp)
{
    return (long)size.width * (long)size.height * bpp;
}

/* ---------------------------------------------------------------------------
 * 1. The crash. A rect whose origin sits exactly on the bottom edge of the
 *    framebuffer produced a source pointer exactly one byte past the end of
 *    the calloc'd `pixels` buffer -- matching the crash report, where the
 *    faulting address was the first byte after a MALLOC_LARGE region.
 * ------------------------------------------------------------------------- */
static void test_origin_on_bottom_edge_is_rejected(void)
{
    NSSize size = NSMakeSize(512, 128);          /* 65536 px */
    const int bpp = 4;

    /* Reproduce the bug with the old logic. */
    NSRect legacy = NSMakeRect(0, 128, 512, 5);  /* origin.y == size.height */
    int yshift = 0;
    BOOL wouldDraw = legacyClip(&legacy, size, &yshift);
    CHECK(wouldDraw, "legacy logic should (buggily) accept this rect");
    long start = (long)legacy.origin.y * (long)size.width + (long)legacy.origin.x;
    CHECK(start * bpp == bufferBytes(size, bpp),
          "legacy source pointer should land exactly at end-of-buffer: "
          "%ld vs %ld", start * bpp, bufferBytes(size, bpp));

    /* The fix must reject it outright -- there is nothing to draw. */
    NSRect r = NSMakeRect(0, 128, 512, 5);
    int clipped = 0;
    CHECK(!FrameBufferClipRect(&r, size, &clipped),
          "fixed logic must reject a rect originating at the bottom edge");
}

/* ---------------------------------------------------------------------------
 * 2. Overrunning the bottom by many rows. The old code subtracted exactly one
 *    row regardless of how far past the edge the rect reached.
 * ------------------------------------------------------------------------- */
static void test_deep_bottom_overrun_is_clamped(void)
{
    NSSize size = NSMakeSize(512, 128);
    const int bpp = 4;

    NSRect legacy = NSMakeRect(0, 120, 512, 20); /* 12 rows past the end */
    int yshift = 0;
    CHECK(legacyClip(&legacy, size, &yshift), "legacy accepts");
    CHECK(lastByteTouched(legacy, size, bpp) >= bufferBytes(size, bpp),
          "legacy logic should still overrun after its -=1 clamp");

    NSRect r = NSMakeRect(0, 120, 512, 20);
    int clipped = 0;
    CHECK(FrameBufferClipRect(&r, size, &clipped), "fixed logic keeps the visible part");
    CHECK(r.size.height == 8, "expected 8 rows, got %g", r.size.height);
    CHECK(clipped == 12, "expected 12 clipped rows, got %d", clipped);
    CHECK(lastByteTouched(r, size, bpp) == bufferBytes(size, bpp) - 1,
          "clamped rect must end exactly at the last byte of the buffer");
}

/* ---------------------------------------------------------------------------
 * 3. A rect that exactly fills the framebuffer must be drawn in full. The old
 *    code dropped its bottom row because the test was `>=` rather than `>`,
 *    so the last row of the remote desktop never repainted.
 * ------------------------------------------------------------------------- */
static void test_exact_fit_draws_every_row(void)
{
    NSSize size = NSMakeSize(512, 128);
    const int bpp = 4;

    NSRect legacy = NSMakeRect(0, 0, 512, 128);
    int yshift = 0;
    CHECK(legacyClip(&legacy, size, &yshift), "legacy accepts");
    CHECK(legacy.size.height == 127, "legacy drops a row (documenting old behaviour)");

    NSRect r = NSMakeRect(0, 0, 512, 128);
    int clipped = 0;
    CHECK(FrameBufferClipRect(&r, size, &clipped), "fixed logic accepts a full-size rect");
    CHECK(r.size.height == 128, "expected all 128 rows, got %g", r.size.height);
    CHECK(clipped == 0, "nothing should be clipped, got %d", clipped);
    CHECK(lastByteTouched(r, size, bpp) == bufferBytes(size, bpp) - 1,
          "a full-framebuffer rect must touch exactly the whole buffer");
}

/* ---------------------------------------------------------------------------
 * 4. Origins outside the framebuffer in either axis, and negative origins.
 * ------------------------------------------------------------------------- */
static void test_out_of_range_origins_rejected(void)
{
    NSSize size = NSMakeSize(512, 128);
    int clipped = 0;
    NSRect r;

    r = NSMakeRect(512, 0, 10, 10);
    CHECK(!FrameBufferClipRect(&r, size, &clipped), "origin.x == width must be rejected");
    r = NSMakeRect(900, 0, 10, 10);
    CHECK(!FrameBufferClipRect(&r, size, &clipped), "origin.x > width must be rejected");
    r = NSMakeRect(0, 900, 10, 10);
    CHECK(!FrameBufferClipRect(&r, size, &clipped), "origin.y > height must be rejected");
    r = NSMakeRect(-1, 0, 10, 10);
    CHECK(!FrameBufferClipRect(&r, size, &clipped), "negative origin.x must be rejected");
    r = NSMakeRect(0, -1, 10, 10);
    CHECK(!FrameBufferClipRect(&r, size, &clipped), "negative origin.y must be rejected");
    r = NSMakeRect(0, 0, 0, 10);
    CHECK(!FrameBufferClipRect(&r, size, &clipped), "zero width must be rejected");
    r = NSMakeRect(0, 0, 10, 0);
    CHECK(!FrameBufferClipRect(&r, size, &clipped), "zero height must be rejected");
}

/* ---------------------------------------------------------------------------
 * 5. Right-edge clamping, which must not move the destination origin.
 * ------------------------------------------------------------------------- */
static void test_right_edge_clamped(void)
{
    NSSize size = NSMakeSize(512, 128);
    const int bpp = 4;

    NSRect r = NSMakeRect(500, 0, 40, 4);        /* 28 columns past the right */
    int clipped = 0;
    CHECK(FrameBufferClipRect(&r, size, &clipped), "fixed logic keeps the visible part");
    CHECK(r.size.width == 12, "expected 12 columns, got %g", r.size.width);
    CHECK(clipped == 0, "horizontal clipping must not shift rows, got %d", clipped);
    CHECK(lastByteTouched(r, size, bpp) < bufferBytes(size, bpp), "must stay in bounds");
}

/* ---------------------------------------------------------------------------
 * 6. Exhaustive sweep. For every rect the clip accepts, NSDrawBitmap's read
 *    span must lie entirely inside the buffer. This is the property that
 *    actually prevents the segfault.
 * ------------------------------------------------------------------------- */
static void test_accepted_rects_never_escape_the_buffer(void)
{
    const int bpp = 4;
    const NSSize sizes[] = {
        {512, 128}, {1, 1}, {1920, 1080}, {3, 7}, {800, 600},
    };

    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
        NSSize size = sizes[s];
        long capacity = bufferBytes(size, bpp);

        for (int oy = -3; oy <= (int)size.height + 3; oy++) {
            for (int ox = -3; ox <= (int)size.width + 3; ox++) {
                for (int h = 0; h <= 6; h++) {
                    for (int w = 0; w <= 6; w++) {
                        NSRect r = NSMakeRect(ox, oy, w, h);
                        NSRect original = r;
                        int clipped = 0;
                        if (!FrameBufferClipRect(&r, size, &clipped))
                            continue;

                        long last = lastByteTouched(r, size, bpp);
                        long first = ((long)r.origin.y * (long)size.width +
                                      (long)r.origin.x) * bpp;
                        if (first < 0 || last >= capacity) {
                            failures++;
                            fprintf(stderr,
                                "FAIL escape: fb %gx%g rect {%g,%g %gx%g} -> "
                                "{%g,%g %gx%g} touches [%ld,%ld] of %ld\n",
                                size.width, size.height,
                                original.origin.x, original.origin.y,
                                original.size.width, original.size.height,
                                r.origin.x, r.origin.y, r.size.width, r.size.height,
                                first, last, capacity);
                        }
                        checks++;

                        /* The clip may only shrink, never grow or move. */
                        CHECK(r.size.width <= original.size.width &&
                              r.size.height <= original.size.height &&
                              r.origin.x == original.origin.x &&
                              r.origin.y == original.origin.y,
                              "clip must only shrink the rect in place");
                        CHECK(clipped == (int)(original.size.height - r.size.height),
                              "clipped row count must match the height reduction");
                    }
                }
            }
        }
    }
}

int main(void)
{
    @autoreleasepool {
        test_origin_on_bottom_edge_is_rejected();
        test_deep_bottom_overrun_is_clamped();
        test_exact_fit_draws_every_row();
        test_out_of_range_origins_rejected();
        test_right_edge_clamped();
        test_accepted_rects_never_escape_the_buffer();
    }
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
