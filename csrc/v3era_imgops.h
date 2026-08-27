/* v3era_imgops.h -- scalar image kernels for the V3ERA preprocessing pipeline.
 *
 * These are the inner loops that dominate wall-clock time on a document page:
 * integral-image binarisation, separable blur, resampling and rotation. They
 * live in C rather than Nim because they are trivially auto-vectorisable and we
 * want -O3 -ffast-math applied to them regardless of how the Nim side is built.
 *
 * Conventions used throughout:
 *   - Buffers are tightly packed, row-major, `w * h * channels` bytes.
 *   - `ch` is 1 (gray), 2 (gray+alpha), 3 (RGB) or 4 (RGBA).
 *   - Binary images are 8-bit with 0 = ink and 255 = background.
 *   - Callers own all memory; nothing here allocates except where documented.
 */
#ifndef V3ERA_IMGOPS_H
#define V3ERA_IMGOPS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- colour ---------------------------------------------------------- */

/* Rec.601 luma. `dst` holds w*h bytes. Alpha channels are ignored. */
void v3e_to_gray(const uint8_t *src, int w, int h, int ch, uint8_t *dst);

/* Expand a single channel to `ch` interleaved channels (alpha set to 255). */
void v3e_gray_to_channels(const uint8_t *src, int w, int h, int ch, uint8_t *dst);

/* Per-channel histogram stretch that clips `lo_pct`/`hi_pct` of the mass at
 * each end. Operates in place. Percentages are 0..100. */
void v3e_autocontrast(uint8_t *buf, int w, int h, int ch, double lo_pct, double hi_pct);

/* ---- integral images -------------------------------------------------- */

/* Summed-area tables for a grayscale plane. Both output buffers must hold
 * (w+1)*(h+1) elements. `sqsum` may be NULL if variance is not needed. */
void v3e_integral(const uint8_t *gray, int w, int h, uint64_t *sum, uint64_t *sqsum);

/* ---- thresholding ------------------------------------------------------ */

/* Otsu's method. Returns the threshold in 0..255, or -1 for an empty image. */
int v3e_otsu_threshold(const uint8_t *gray, int w, int h);

/* Apply a global threshold. Output is 0/255; `invert` swaps the polarity. */
void v3e_threshold_apply(const uint8_t *gray, int w, int h, int thr, int invert,
                         uint8_t *dst);

/* Sauvola adaptive threshold: t = mean * (1 + k * (stddev / r - 1)).
 * `window` is the full side length of the neighbourhood (odd, >= 3);
 * k defaults to 0.34 and r to 128.0 for 8-bit input. Allocates two internal
 * summed-area tables; returns 0 on success and -1 if allocation failed. */
int v3e_sauvola(const uint8_t *gray, int w, int h, int window, double k,
                double r, uint8_t *dst);

/* ---- filtering --------------------------------------------------------- */

/* Separable box blur of the given radius, applied per channel. Uses a running
 * sum so cost is independent of radius. `scratch` must hold w*h*ch bytes. */
void v3e_box_blur(const uint8_t *src, int w, int h, int ch, int radius,
                  uint8_t *scratch, uint8_t *dst);

/* 3x3 median, per channel. Good for salt-and-pepper noise on scans. */
void v3e_median3(const uint8_t *src, int w, int h, int ch, uint8_t *dst);

/* Unsharp mask: dst = src + amount * (src - blur(src)). `amount` is typically
 * 0.5..1.5. Returns 0 on success, -1 on allocation failure. */
int v3e_unsharp(const uint8_t *src, int w, int h, int ch, int radius,
                double amount, uint8_t *dst);

/* ---- geometry ---------------------------------------------------------- */

/* Bilinear resample to dw x dh. Handles up- and down-scaling; downscaling by
 * more than 2x should be preceded by a blur to avoid aliasing. */
void v3e_resize_bilinear(const uint8_t *src, int sw, int sh, int ch,
                         uint8_t *dst, int dw, int dh);

/* Box-filtered (area-average) downscale, correct for large reduction ratios.
 * Requires dw <= sw and dh <= sh. */
void v3e_resize_area(const uint8_t *src, int sw, int sh, int ch,
                     uint8_t *dst, int dw, int dh);

/* Rotate by a multiple of 90 degrees clockwise. `turns` is 1, 2 or 3. The
 * caller sizes `dst` accordingly (dimensions swap for odd turns). */
void v3e_rotate_quadrant(const uint8_t *src, int w, int h, int ch, int turns,
                         uint8_t *dst);

/* Rotate about the centre by `angle_rad` (positive = counter-clockwise) into a
 * dw x dh canvas, sampling bilinearly. Out-of-bounds samples take `fill`. */
void v3e_rotate_bilinear(const uint8_t *src, int w, int h, int ch,
                         double angle_rad, uint8_t *dst, int dw, int dh,
                         uint8_t fill);

/* ---- analysis ---------------------------------------------------------- */

/* Variance of the 3x3 Laplacian: a cheap, well-behaved focus/blur metric.
 * Values below ~100 on a 300 DPI scan usually mean the page is too soft
 * for reliable OCR. */
double v3e_laplacian_variance(const uint8_t *gray, int w, int h);

/* Mean luma in 0..255. */
double v3e_mean_luma(const uint8_t *gray, int w, int h);

/* Fraction of pixels that are ink (value < 128) in a binary or gray image. */
double v3e_ink_coverage(const uint8_t *gray, int w, int h);

/* Sum of ink pixels per row of a binarised image. `out` holds h int32s.
 * This is the projection profile the deskew search maximises variance over. */
void v3e_row_projection(const uint8_t *bin, int w, int h, int32_t *out);

/* Variance of the row projection profile after rotating `bin` by `angle_rad`.
 * The rotation is applied analytically during accumulation, so no intermediate
 * image is materialised -- this is what makes the deskew sweep cheap. */
double v3e_projection_variance(const uint8_t *bin, int w, int h, double angle_rad);

#ifdef __cplusplus
}
#endif

#endif /* V3ERA_IMGOPS_H */
