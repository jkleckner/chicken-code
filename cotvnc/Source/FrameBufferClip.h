/* FrameBufferClip.h
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

#ifndef FRAMEBUFFERCLIP_H
#define FRAMEBUFFERCLIP_H

#import <Foundation/Foundation.h>

/* Clips a framebuffer-space rectangle to the framebuffer's bounds.
 *
 * The caller cannot be trusted to supply an in-range rectangle. RFBView maps
 * AppKit's dirty rects into framebuffer coordinates using the *view's* height,
 * and the view and the framebuffer are sized by different, asynchronous
 * sources: the view follows the window (driven by the user), while the
 * framebuffer is reallocated only when the server acknowledges a resize with a
 * DesktopSize update. While those disagree, the incoming rectangle can start
 * or end outside the framebuffer entirely. Drawing it unclipped reads past the
 * end of the pixel buffer and segfaults inside NSDrawBitmap.
 *
 * `r` is narrowed in place, never moved and never grown. `clippedRows` receives
 * the number of rows removed from the bottom, which the caller must add to the
 * on-screen destination origin to hold the top edge of the image steady (the
 * view is not flipped, so y grows upward on screen but downward in the
 * framebuffer).
 *
 * Returns NO when nothing of the rectangle remains to be drawn.
 */
static inline BOOL FrameBufferClipRect(NSRect *r, NSSize size, int *clippedRows)
{
    if (clippedRows != NULL)
        *clippedRows = 0;

    /* Reject any origin outside the framebuffer. Checking only for negative
     * origins -- as this code once did -- lets an origin at or beyond the far
     * edge through, and that origin alone is enough to place the source
     * pointer past the end of the buffer before a single row is read. */
    if (r->origin.x < 0 || r->origin.y < 0)
        return NO;
    if (r->origin.x >= size.width || r->origin.y >= size.height)
        return NO;

    /* Clamp to the real edge. Subtracting a fixed number of rows or columns is
     * not enough: the rectangle may overrun by an arbitrary amount. */
    if (NSMaxX(*r) > size.width)
        r->size.width = size.width - r->origin.x;

    if (NSMaxY(*r) > size.height) {
        CGFloat height = size.height - r->origin.y;
        if (clippedRows != NULL)
            *clippedRows = (int)(r->size.height - height);
        r->size.height = height;
    }

    return r->size.width > 0 && r->size.height > 0;
}

#endif /* FRAMEBUFFERCLIP_H */
