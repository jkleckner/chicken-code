/* test_scrollneed.m
 *
 * Covers ScrollerNeed.h, which decides whether a session window needs
 * horizontal and/or vertical scrollers.
 *
 * The bug this guards against: -[Session windowDidResize:] used to skip
 * scroller setup entirely whenever the server "supported" SetDesktopSize,
 * betting that the server had resized its desktop to match the window. That
 * bet is unverified -- Chicken never negotiates the ExtendedDesktopSize
 * pseudo-encoding and never reads a reply -- so against a server that ignores
 * the request the framebuffer stayed larger than the window with no scrollers
 * and no autoscroll, making part of the remote display unreachable.
 *
 * The fix is to decide from the framebuffer we actually have rather than the
 * one we asked for, which is what these cases pin down.
 */

#import <Foundation/Foundation.h>
#import "ScrollerNeed.h"

static int failures = 0;
static int checks = 0;

static void expect(const char *what,
                   double contentW, double contentH,
                   double viewportW, double viewportH,
                   double thickness,
                   BOOL wantH, BOOL wantV)
{
    BOOL gotH = NO, gotV = NO;
    checks++;
    ScrollerNeedForContent(contentW, contentH, viewportW, viewportH, thickness,
                           &gotH, &gotV);
    if (gotH != wantH || gotV != wantV) {
        failures++;
        fprintf(stderr,
                "\n  FAIL %s: content %gx%g in viewport %gx%g (thickness %g)\n"
                "       wanted h=%d v=%d, got h=%d v=%d\n",
                what, contentW, contentH, viewportW, viewportH, thickness,
                wantH, wantV, gotH, gotV);
    }
}

int main(void)
{
    @autoreleasepool {
        const double T = 15.0;  /* representative legacy scroller thickness */

        /* Content fits: no scrollers. This is the case where the server did
         * honour a resize request, and it must not sprout scrollbars. */
        expect("exact fit", 1024, 768, 1024, 768, T, NO, NO);
        expect("content smaller", 800, 600, 1024, 768, T, NO, NO);

        /* Content larger in one dimension only. Note that adding one scroller
         * eats into the other axis, which can force the second scroller. */
        expect("wider only, tall room to spare", 2000, 500, 1024, 768, T, YES, NO);
        expect("taller only, wide room to spare", 500, 2000, 1024, 768, T, NO, YES);

        /* Content larger in both dimensions: both scrollers. This is the
         * reported bug -- a 2560x1600 desktop in a 1440x900 window. */
        expect("larger both ways", 2560, 1600, 1440, 900, T, YES, YES);

        /* The interesting case: content fits vertically only until the
         * horizontal scroller is added, which steals `thickness` of height. */
        expect("h scroller forces v", 2000, 768, 1024, 768, T, YES, YES);
        expect("v scroller forces h", 1024, 2000, 1024, 768, T, YES, YES);

        /* Just inside the margin: adding the h scroller still leaves room. */
        expect("h scroller, v still fits", 2000, 700, 1024, 768, T, YES, NO);

        /* Degenerate viewport (window collapsed or not yet laid out) must not
         * produce nonsense; anything positive needs scrollers. */
        expect("zero viewport", 100, 100, 0, 0, T, YES, YES);

        /* Zero-size content (no framebuffer yet) needs nothing. */
        expect("zero content", 0, 0, 1024, 768, T, NO, NO);
    }

    printf("test_scrollneed: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
