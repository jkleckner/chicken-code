/* ScrollerNeed.h
 *
 * Copyright (C) 1998-2000  Helmut Maierhofer <helmut.maierhofer@chello.at>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 */

#ifndef SCROLLERNEED_H
#define SCROLLERNEED_H

#import <Foundation/Foundation.h>

/* Decides which scrollers a session window needs to make the whole framebuffer
 * reachable, given the framebuffer size and the viewport currently showing it.
 *
 * This must be answered from the framebuffer we ACTUALLY have, never from the
 * one we asked the server for. -[Session windowDidResize:] sends the server a
 * SetDesktopSize request when it believes the server supports resizing, but
 * that is a request, not a guarantee: Chicken never negotiates the
 * ExtendedDesktopSize pseudo-encoding (rfbproto.h defines it but nothing
 * requests it) and never reads the server's accept/reject reply. A server that
 * ignores the request leaves the framebuffer at its original size.
 *
 * Skipping scroller setup on the assumption the request succeeded is what made
 * part of an oversized remote display permanently unreachable -- there is no
 * autoscroll any more, and RFBView forwards the scroll wheel to the server
 * rather than scrolling the view, so scrollers are the only way to pan.
 *
 * Deciding from measured sizes is self-correcting: if the server did honour
 * the resize, content matches the viewport and no scroller is reported.
 *
 * Note that a scroller consumes `scrollerThickness` from the perpendicular
 * axis, so needing one can force the other. That second-order case is why this
 * lives in a header with its own tests rather than inline at the call site.
 */
static inline void ScrollerNeedForContent(double contentWidth,
                                          double contentHeight,
                                          double viewportWidth,
                                          double viewportHeight,
                                          double scrollerThickness,
                                          BOOL *needsHorizontal,
                                          BOOL *needsVertical)
{
    BOOL h = contentWidth  > viewportWidth;
    BOOL v = contentHeight > viewportHeight;

    /* Adding one scroller shrinks the opposite axis, which can pull the other
     * scroller in. Re-check both; a single extra pass is enough, since once
     * both are on there is nothing further to discover. */
    if (h && !v)
        v = contentHeight > (viewportHeight - scrollerThickness);
    else if (v && !h)
        h = contentWidth > (viewportWidth - scrollerThickness);

    if (needsHorizontal)
        *needsHorizontal = h;
    if (needsVertical)
        *needsVertical = v;
}

#endif /* SCROLLERNEED_H */
