/* v3era_imgops.c -- see v3era_imgops.h for the contract. */

#include "v3era_imgops.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define V3E_CLAMP255(x) ((x) < 0 ? 0 : ((x) > 255 ? 255 : (x)))

/* ---- colour ---------------------------------------------------------- */

void v3e_to_gray(const uint8_t *src, int w, int h, int ch, uint8_t *dst) {
  const size_t n = (size_t)w * (size_t)h;
  size_t i;

  if (ch <= 2) {
    /* Gray or gray+alpha: the luma plane is already there, just de-interleave. */
    if (ch == 1) {
      memcpy(dst, src, n);
    } else {
      for (i = 0; i < n; i++) dst[i] = src[i * 2];
    }
    return;
  }

  /* Rec.601 luma in fixed point: 0.299/0.587/0.114 scaled by 1<<16. */
  for (i = 0; i < n; i++) {
    const uint8_t *p = src + i * (size_t)ch;
    uint32_t y = 19595u * p[0] + 38470u * p[1] + 7471u * p[2];
    dst[i] = (uint8_t)(y >> 16);
  }
}

void v3e_gray_to_channels(const uint8_t *src, int w, int h, int ch, uint8_t *dst) {
  const size_t n = (size_t)w * (size_t)h;
  size_t i;
  int c;

  if (ch == 1) {
    memcpy(dst, src, n);
    return;
  }
  for (i = 0; i < n; i++) {
    uint8_t v = src[i];
    uint8_t *q = dst + i * (size_t)ch;
    if (ch == 2) {
      q[0] = v;
      q[1] = 255;
    } else {
      for (c = 0; c < 3; c++) q[c] = v;
      if (ch == 4) q[3] = 255;
    }
  }
}

void v3e_autocontrast(uint8_t *buf, int w, int h, int ch, double lo_pct,
                      double hi_pct) {
  const size_t n = (size_t)w * (size_t)h;
  int c;

  if (n == 0 || ch < 1) return;
  if (lo_pct < 0.0) lo_pct = 0.0;
  if (hi_pct < 0.0) hi_pct = 0.0;
  if (lo_pct + hi_pct >= 100.0) return;

  /* Colour channels only -- stretching alpha would punch holes in the image. */
  const int colour_ch = (ch == 2) ? 1 : (ch == 4 ? 3 : ch);

  for (c = 0; c < colour_ch; c++) {
    uint32_t hist[256];
    size_t i;
    int lo = 0, hi = 255;
    memset(hist, 0, sizeof(hist));
    for (i = 0; i < n; i++) hist[buf[i * (size_t)ch + (size_t)c]]++;

    {
      const uint64_t lo_target = (uint64_t)((double)n * lo_pct / 100.0);
      const uint64_t hi_target = (uint64_t)((double)n * hi_pct / 100.0);
      uint64_t acc = 0;
      int v;
      for (v = 0; v < 256; v++) {
        acc += hist[v];
        if (acc > lo_target) { lo = v; break; }
      }
      acc = 0;
      for (v = 255; v >= 0; v--) {
        acc += hist[v];
        if (acc > hi_target) { hi = v; break; }
      }
    }

    if (hi <= lo) continue; /* Flat channel: leave it alone. */
    {
      /* Precompute the full 8-bit transfer curve; the per-pixel loop is then a
       * single dependent load and stays vectorisable. */
      uint8_t lut[256];
      const double scale = 255.0 / (double)(hi - lo);
      int v;
      for (v = 0; v < 256; v++) {
        int o = (int)lround(((double)v - (double)lo) * scale);
        lut[v] = (uint8_t)V3E_CLAMP255(o);
      }
      for (i = 0; i < n; i++) {
        size_t idx = i * (size_t)ch + (size_t)c;
        buf[idx] = lut[buf[idx]];
      }
    }
  }
}

/* ---- integral images -------------------------------------------------- */

void v3e_integral(const uint8_t *gray, int w, int h, uint64_t *sum,
                  uint64_t *sqsum) {
  const int sw = w + 1;
  int y, x;

  memset(sum, 0, (size_t)sw * sizeof(uint64_t));
  if (sqsum) memset(sqsum, 0, (size_t)sw * sizeof(uint64_t));

  for (y = 0; y < h; y++) {
    uint64_t row = 0, row_sq = 0;
    const uint8_t *src = gray + (size_t)y * (size_t)w;
    uint64_t *prev = sum + (size_t)y * (size_t)sw;
    uint64_t *cur = prev + sw;
    uint64_t *prev_sq = sqsum ? sqsum + (size_t)y * (size_t)sw : NULL;
    uint64_t *cur_sq = prev_sq ? prev_sq + sw : NULL;

    cur[0] = 0;
    if (cur_sq) cur_sq[0] = 0;
    for (x = 0; x < w; x++) {
      const uint64_t v = src[x];
      row += v;
      cur[x + 1] = prev[x + 1] + row;
      if (cur_sq) {
        row_sq += v * v;
        cur_sq[x + 1] = prev_sq[x + 1] + row_sq;
      }
    }
  }
}

/* Inclusive rectangle sum from a summed-area table with a (w+1) stride. */
static inline uint64_t v3e_rect(const uint64_t *sat, int sw, int x0, int y0,
                                int x1, int y1) {
  return sat[(size_t)(y1 + 1) * sw + (x1 + 1)] - sat[(size_t)y0 * sw + (x1 + 1)] -
         sat[(size_t)(y1 + 1) * sw + x0] + sat[(size_t)y0 * sw + x0];
}

/* ---- thresholding ------------------------------------------------------ */

int v3e_otsu_threshold(const uint8_t *gray, int w, int h) {
  const size_t n = (size_t)w * (size_t)h;
  uint64_t hist[256];
  uint64_t total_sum = 0, w_bg = 0, sum_bg = 0;
  double best_var = -1.0;
  int first_best = 0, last_best = 0, t;
  size_t i;

  if (n == 0) return -1;
  memset(hist, 0, sizeof(hist));
  for (i = 0; i < n; i++) hist[gray[i]]++;
  for (t = 0; t < 256; t++) total_sum += (uint64_t)t * hist[t];

  for (t = 0; t < 256; t++) {
    w_bg += hist[t];
    if (w_bg == 0) continue;
    {
      const uint64_t w_fg = (uint64_t)n - w_bg;
      double mean_bg, mean_fg, between;
      if (w_fg == 0) break;
      sum_bg += (uint64_t)t * hist[t];
      mean_bg = (double)sum_bg / (double)w_bg;
      mean_fg = (double)(total_sum - sum_bg) / (double)w_fg;
      between = (double)w_bg * (double)w_fg * (mean_bg - mean_fg) *
                (mean_bg - mean_fg);
      /* Track the whole plateau of maximisers, not just the first. A cleanly
       * bimodal image -- exactly what a binarised scan is -- has an empty gap
       * between its two peaks, and every threshold in that gap scores
       * identically. Taking the first maximiser would sit the threshold hard
       * against the ink peak, where sensor noise then flips pixels; the
       * midpoint of the gap is the robust choice. */
      if (between > best_var) {
        best_var = between;
        first_best = t;
        last_best = t;
      } else if (between == best_var) {
        last_best = t;
      }
    }
  }
  return (first_best + last_best) / 2;
}

void v3e_threshold_apply(const uint8_t *gray, int w, int h, int thr, int invert,
                         uint8_t *dst) {
  const size_t n = (size_t)w * (size_t)h;
  const uint8_t below = invert ? 255 : 0;
  const uint8_t above = invert ? 0 : 255;
  size_t i;
  for (i = 0; i < n; i++) dst[i] = (gray[i] <= thr) ? below : above;
}

int v3e_sauvola(const uint8_t *gray, int w, int h, int window, double k,
                double r, uint8_t *dst) {
  const int sw = w + 1;
  const size_t sat_len = (size_t)sw * (size_t)(h + 1);
  uint64_t *sum, *sqsum;
  int rad, y, x;

  if (w <= 0 || h <= 0) return 0;
  if (window < 3) window = 3;
  if ((window & 1) == 0) window++;
  if (r <= 0.0) r = 128.0;
  rad = window / 2;

  sum = (uint64_t *)malloc(sat_len * sizeof(uint64_t));
  sqsum = (uint64_t *)malloc(sat_len * sizeof(uint64_t));
  if (!sum || !sqsum) {
    free(sum);
    free(sqsum);
    return -1;
  }
  v3e_integral(gray, w, h, sum, sqsum);

  for (y = 0; y < h; y++) {
    const int y0 = y - rad < 0 ? 0 : y - rad;
    const int y1 = y + rad >= h ? h - 1 : y + rad;
    for (x = 0; x < w; x++) {
      const int x0 = x - rad < 0 ? 0 : x - rad;
      const int x1 = x + rad >= w ? w - 1 : x + rad;
      const double area = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1);
      const double s = (double)v3e_rect(sum, sw, x0, y0, x1, y1);
      const double sq = (double)v3e_rect(sqsum, sw, x0, y0, x1, y1);
      const double mean = s / area;
      double var = sq / area - mean * mean;
      double thr;
      if (var < 0.0) var = 0.0; /* Guard against fp cancellation on flat areas. */
      thr = mean * (1.0 + k * (sqrt(var) / r - 1.0));
      dst[(size_t)y * (size_t)w + (size_t)x] =
          ((double)gray[(size_t)y * (size_t)w + (size_t)x] <= thr) ? 0 : 255;
    }
  }

  free(sum);
  free(sqsum);
  return 0;
}

/* ---- filtering --------------------------------------------------------- */

void v3e_box_blur(const uint8_t *src, int w, int h, int ch, int radius,
                  uint8_t *scratch, uint8_t *dst) {
  const int win = 2 * radius + 1;
  int y, x, c;

  if (radius <= 0) {
    if (dst != src) memcpy(dst, src, (size_t)w * (size_t)h * (size_t)ch);
    return;
  }

  /* Horizontal pass into scratch, using a running window sum. Edge pixels are
   * clamped (replicated), which avoids the dark halo a zero border produces. */
  for (y = 0; y < h; y++) {
    const uint8_t *srow = src + (size_t)y * (size_t)w * (size_t)ch;
    uint8_t *drow = scratch + (size_t)y * (size_t)w * (size_t)ch;
    for (c = 0; c < ch; c++) {
      uint32_t acc = 0;
      int i;
      for (i = -radius; i <= radius; i++) {
        int xx = i < 0 ? 0 : (i >= w ? w - 1 : i);
        acc += srow[(size_t)xx * ch + c];
      }
      for (x = 0; x < w; x++) {
        drow[(size_t)x * ch + c] = (uint8_t)(acc / (uint32_t)win);
        {
          int xa = x - radius, xb = x + radius + 1;
          xa = xa < 0 ? 0 : (xa >= w ? w - 1 : xa);
          xb = xb < 0 ? 0 : (xb >= w ? w - 1 : xb);
          acc -= srow[(size_t)xa * ch + c];
          acc += srow[(size_t)xb * ch + c];
        }
      }
    }
  }

  /* Vertical pass from scratch into dst. */
  for (x = 0; x < w; x++) {
    for (c = 0; c < ch; c++) {
      uint32_t acc = 0;
      int i;
      for (i = -radius; i <= radius; i++) {
        int yy = i < 0 ? 0 : (i >= h ? h - 1 : i);
        acc += scratch[((size_t)yy * w + x) * ch + c];
      }
      for (y = 0; y < h; y++) {
        dst[((size_t)y * w + x) * ch + c] = (uint8_t)(acc / (uint32_t)win);
        {
          int ya = y - radius, yb = y + radius + 1;
          ya = ya < 0 ? 0 : (ya >= h ? h - 1 : ya);
          yb = yb < 0 ? 0 : (yb >= h ? h - 1 : yb);
          acc -= scratch[((size_t)ya * w + x) * ch + c];
          acc += scratch[((size_t)yb * w + x) * ch + c];
        }
      }
    }
  }
}

/* Sorting network for 9 elements -- 19 compare-exchanges, branch-light. */
static inline void v3e_sort9(uint8_t *v) {
#define SWAP(a, b)                    \
  do {                                \
    uint8_t lo = v[a] < v[b] ? v[a] : v[b]; \
    uint8_t hi = v[a] < v[b] ? v[b] : v[a]; \
    v[a] = lo;                        \
    v[b] = hi;                        \
  } while (0)
  SWAP(1, 2); SWAP(4, 5); SWAP(7, 8); SWAP(0, 1); SWAP(3, 4); SWAP(6, 7);
  SWAP(1, 2); SWAP(4, 5); SWAP(7, 8); SWAP(0, 3); SWAP(5, 8); SWAP(4, 7);
  SWAP(3, 6); SWAP(1, 4); SWAP(2, 5); SWAP(4, 7); SWAP(4, 2); SWAP(6, 4);
  SWAP(4, 2);
#undef SWAP
}

void v3e_median3(const uint8_t *src, int w, int h, int ch, uint8_t *dst) {
  int y, x, c;
  if (w < 3 || h < 3) {
    memcpy(dst, src, (size_t)w * (size_t)h * (size_t)ch);
    return;
  }
  for (y = 0; y < h; y++) {
    const int ym = y > 0 ? y - 1 : 0;
    const int yp = y < h - 1 ? y + 1 : h - 1;
    for (x = 0; x < w; x++) {
      const int xm = x > 0 ? x - 1 : 0;
      const int xp = x < w - 1 ? x + 1 : w - 1;
      for (c = 0; c < ch; c++) {
        uint8_t v[9];
        v[0] = src[((size_t)ym * w + xm) * ch + c];
        v[1] = src[((size_t)ym * w + x) * ch + c];
        v[2] = src[((size_t)ym * w + xp) * ch + c];
        v[3] = src[((size_t)y * w + xm) * ch + c];
        v[4] = src[((size_t)y * w + x) * ch + c];
        v[5] = src[((size_t)y * w + xp) * ch + c];
        v[6] = src[((size_t)yp * w + xm) * ch + c];
        v[7] = src[((size_t)yp * w + x) * ch + c];
        v[8] = src[((size_t)yp * w + xp) * ch + c];
        v3e_sort9(v);
        dst[((size_t)y * w + x) * ch + c] = v[4];
      }
    }
  }
}

int v3e_unsharp(const uint8_t *src, int w, int h, int ch, int radius,
                double amount, uint8_t *dst) {
  const size_t n = (size_t)w * (size_t)h * (size_t)ch;
  uint8_t *blur, *scratch;
  size_t i;

  if (radius <= 0 || amount == 0.0) {
    if (dst != src) memcpy(dst, src, n);
    return 0;
  }
  blur = (uint8_t *)malloc(n);
  scratch = (uint8_t *)malloc(n);
  if (!blur || !scratch) {
    free(blur);
    free(scratch);
    return -1;
  }
  v3e_box_blur(src, w, h, ch, radius, scratch, blur);
  for (i = 0; i < n; i++) {
    const double d = (double)src[i] - (double)blur[i];
    const long o = lround((double)src[i] + amount * d);
    dst[i] = (uint8_t)V3E_CLAMP255(o);
  }
  free(blur);
  free(scratch);
  return 0;
}

/* ---- geometry ---------------------------------------------------------- */

void v3e_resize_bilinear(const uint8_t *src, int sw, int sh, int ch,
                         uint8_t *dst, int dw, int dh) {
  int dy, dx, c;
  double sx_ratio, sy_ratio;

  if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return;
  if (sw == dw && sh == dh) {
    memcpy(dst, src, (size_t)sw * (size_t)sh * (size_t)ch);
    return;
  }
  /* Half-pixel centre alignment: maps destination centres onto source centres
   * so a 2x downscale averages the right pairs instead of shifting by half a
   * pixel, which is visible as a drift on thin glyph strokes. */
  sx_ratio = (double)sw / (double)dw;
  sy_ratio = (double)sh / (double)dh;

  for (dy = 0; dy < dh; dy++) {
    double fy = ((double)dy + 0.5) * sy_ratio - 0.5;
    int y0, y1;
    double wy;
    if (fy < 0.0) fy = 0.0;
    y0 = (int)fy;
    if (y0 > sh - 1) y0 = sh - 1;
    y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
    wy = fy - (double)y0;

    for (dx = 0; dx < dw; dx++) {
      double fx = ((double)dx + 0.5) * sx_ratio - 0.5;
      int x0, x1;
      double wx;
      if (fx < 0.0) fx = 0.0;
      x0 = (int)fx;
      if (x0 > sw - 1) x0 = sw - 1;
      x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
      wx = fx - (double)x0;

      for (c = 0; c < ch; c++) {
        const double p00 = src[((size_t)y0 * sw + x0) * ch + c];
        const double p01 = src[((size_t)y0 * sw + x1) * ch + c];
        const double p10 = src[((size_t)y1 * sw + x0) * ch + c];
        const double p11 = src[((size_t)y1 * sw + x1) * ch + c];
        const double top = p00 + (p01 - p00) * wx;
        const double bot = p10 + (p11 - p10) * wx;
        const long o = lround(top + (bot - top) * wy);
        dst[((size_t)dy * dw + dx) * ch + c] = (uint8_t)V3E_CLAMP255(o);
      }
    }
  }
}

void v3e_resize_area(const uint8_t *src, int sw, int sh, int ch, uint8_t *dst,
                     int dw, int dh) {
  int dy, dx, c;
  if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return;
  if (dw > sw || dh > sh) {
    v3e_resize_bilinear(src, sw, sh, ch, dst, dw, dh);
    return;
  }
  for (dy = 0; dy < dh; dy++) {
    int y0 = (int)((double)dy * sh / dh);
    int y1 = (int)((double)(dy + 1) * sh / dh);
    if (y1 <= y0) y1 = y0 + 1;
    if (y1 > sh) y1 = sh;
    for (dx = 0; dx < dw; dx++) {
      int x0 = (int)((double)dx * sw / dw);
      int x1 = (int)((double)(dx + 1) * sw / dw);
      int yy, xx;
      if (x1 <= x0) x1 = x0 + 1;
      if (x1 > sw) x1 = sw;
      for (c = 0; c < ch; c++) {
        uint32_t acc = 0;
        uint32_t count = 0;
        for (yy = y0; yy < y1; yy++) {
          for (xx = x0; xx < x1; xx++) {
            acc += src[((size_t)yy * sw + xx) * ch + c];
            count++;
          }
        }
        dst[((size_t)dy * dw + dx) * ch + c] =
            (uint8_t)(count ? acc / count : 0);
      }
    }
  }
}

void v3e_rotate_quadrant(const uint8_t *src, int w, int h, int ch, int turns,
                         uint8_t *dst) {
  int y, x, c;
  turns = ((turns % 4) + 4) % 4;
  if (turns == 0) {
    memcpy(dst, src, (size_t)w * (size_t)h * (size_t)ch);
    return;
  }
  for (y = 0; y < h; y++) {
    for (x = 0; x < w; x++) {
      const uint8_t *p = src + ((size_t)y * w + x) * ch;
      uint8_t *q;
      if (turns == 1) {
        /* 90 CW: dst is h wide, w tall; (x,y) -> (h-1-y, x). */
        q = dst + ((size_t)x * h + (h - 1 - y)) * ch;
      } else if (turns == 2) {
        q = dst + ((size_t)(h - 1 - y) * w + (w - 1 - x)) * ch;
      } else {
        /* 270 CW: (x,y) -> (y, w-1-x). */
        q = dst + ((size_t)(w - 1 - x) * h + y) * ch;
      }
      for (c = 0; c < ch; c++) q[c] = p[c];
    }
  }
}

void v3e_rotate_bilinear(const uint8_t *src, int w, int h, int ch,
                         double angle_rad, uint8_t *dst, int dw, int dh,
                         uint8_t fill) {
  const double ca = cos(angle_rad), sa = sin(angle_rad);
  const double scx = (double)w / 2.0 - 0.5, scy = (double)h / 2.0 - 0.5;
  const double dcx = (double)dw / 2.0 - 0.5, dcy = (double)dh / 2.0 - 0.5;
  int dy, dx, c;

  for (dy = 0; dy < dh; dy++) {
    const double ry = (double)dy - dcy;
    for (dx = 0; dx < dw; dx++) {
      const double rx = (double)dx - dcx;
      /* Inverse map: rotate the destination point by -angle into source space. */
      const double sx = ca * rx + sa * ry + scx;
      const double sy = -sa * rx + ca * ry + scy;
      uint8_t *q = dst + ((size_t)dy * dw + dx) * ch;

      if (sx < -0.5 || sy < -0.5 || sx > (double)w - 0.5 ||
          sy > (double)h - 0.5) {
        for (c = 0; c < ch; c++) q[c] = fill;
        continue;
      }
      {
        double cx = sx < 0.0 ? 0.0 : sx;
        double cy = sy < 0.0 ? 0.0 : sy;
        int x0 = (int)cx, y0 = (int)cy, x1, y1;
        double wx, wy;
        if (x0 > w - 1) x0 = w - 1;
        if (y0 > h - 1) y0 = h - 1;
        x1 = x0 + 1 < w ? x0 + 1 : w - 1;
        y1 = y0 + 1 < h ? y0 + 1 : h - 1;
        wx = cx - (double)x0;
        wy = cy - (double)y0;
        for (c = 0; c < ch; c++) {
          const double p00 = src[((size_t)y0 * w + x0) * ch + c];
          const double p01 = src[((size_t)y0 * w + x1) * ch + c];
          const double p10 = src[((size_t)y1 * w + x0) * ch + c];
          const double p11 = src[((size_t)y1 * w + x1) * ch + c];
          const double top = p00 + (p01 - p00) * wx;
          const double bot = p10 + (p11 - p10) * wx;
          const long o = lround(top + (bot - top) * wy);
          q[c] = (uint8_t)V3E_CLAMP255(o);
        }
      }
    }
  }
}

/* ---- analysis ---------------------------------------------------------- */

double v3e_laplacian_variance(const uint8_t *gray, int w, int h) {
  double sum = 0.0, sum_sq = 0.0;
  int y, x;
  size_t n = 0;

  if (w < 3 || h < 3) return 0.0;
  for (y = 1; y < h - 1; y++) {
    for (x = 1; x < w - 1; x++) {
      const int c = gray[(size_t)y * w + x];
      const int lap = gray[(size_t)(y - 1) * w + x] +
                      gray[(size_t)(y + 1) * w + x] +
                      gray[(size_t)y * w + (x - 1)] +
                      gray[(size_t)y * w + (x + 1)] - 4 * c;
      sum += (double)lap;
      sum_sq += (double)lap * (double)lap;
      n++;
    }
  }
  if (n == 0) return 0.0;
  {
    const double mean = sum / (double)n;
    const double var = sum_sq / (double)n - mean * mean;
    return var < 0.0 ? 0.0 : var;
  }
}

double v3e_mean_luma(const uint8_t *gray, int w, int h) {
  const size_t n = (size_t)w * (size_t)h;
  uint64_t acc = 0;
  size_t i;
  if (n == 0) return 0.0;
  for (i = 0; i < n; i++) acc += gray[i];
  return (double)acc / (double)n;
}

double v3e_ink_coverage(const uint8_t *gray, int w, int h) {
  const size_t n = (size_t)w * (size_t)h;
  uint64_t ink = 0;
  size_t i;
  if (n == 0) return 0.0;
  for (i = 0; i < n; i++) {
    if (gray[i] < 128) ink++;
  }
  return (double)ink / (double)n;
}

void v3e_row_projection(const uint8_t *bin, int w, int h, int32_t *out) {
  int y, x;
  for (y = 0; y < h; y++) {
    int32_t acc = 0;
    const uint8_t *row = bin + (size_t)y * (size_t)w;
    for (x = 0; x < w; x++) {
      if (row[x] < 128) acc++;
    }
    out[y] = acc;
  }
}

double v3e_projection_variance(const uint8_t *bin, int w, int h,
                               double angle_rad) {
  /* Accumulate ink into rotated row bins without materialising the rotated
   * image: for a shear-free rotation the destination row of pixel (x,y) is
   * y*cos - x*sin, offset so every bin index stays non-negative. */
  const double ca = cos(angle_rad), sa = sin(angle_rad);
  const int extra = (int)(fabs(sa) * (double)w) + 2;
  const int bins = h + 2 * extra;
  int32_t *acc;
  int y, x, i;
  double mean = 0.0, var = 0.0;

  if (w <= 0 || h <= 0 || bins <= 0) return 0.0;
  acc = (int32_t *)calloc((size_t)bins, sizeof(int32_t));
  if (!acc) return 0.0;

  for (y = 0; y < h; y++) {
    const uint8_t *row = bin + (size_t)y * (size_t)w;
    const double yc = (double)y * ca;
    for (x = 0; x < w; x++) {
      if (row[x] < 128) {
        const int b = (int)lround(yc - (double)x * sa) + extra;
        if (b >= 0 && b < bins) acc[b]++;
      }
    }
  }

  for (i = 0; i < bins; i++) mean += (double)acc[i];
  mean /= (double)bins;
  for (i = 0; i < bins; i++) {
    const double d = (double)acc[i] - mean;
    var += d * d;
  }
  var /= (double)bins;
  free(acc);
  return var;
}
