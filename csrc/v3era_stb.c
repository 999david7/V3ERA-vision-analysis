/* v3era_stb.c -- the stb_image / stb_image_write implementation unit.
 *
 * Compiled only when the build defines `v3eraStb` (see config.nims). Run
 * `scripts/fetch_vendor.sh` first to place the public-domain headers into
 * vendor/stb/.
 *
 * The thin wrappers below exist so the Nim side never has to model stb's
 * callback-based writer API or its `stbi_failure_reason` thread-local: each
 * call is a plain buffer in, buffer out.
 */

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO       /* We always hand stb an in-memory buffer. */
#define STBI_NO_PSD
#define STBI_NO_PIC
#define STBI_NO_HDR
#define STBI_ASSERT(x) ((void)0)
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

#include <stdlib.h>
#include <string.h>

/* Decode any supported container. Returns a buffer owned by stb (free it with
 * v3e_stb_free) or NULL on failure, in which case *err points at a static
 * reason string. `desired` is 0 to keep the source channel count. */
unsigned char *v3e_stb_decode(const unsigned char *buf, int len, int *w, int *h,
                              int *ch, int desired, const char **err) {
  unsigned char *px = stbi_load_from_memory(buf, len, w, h, ch, desired);
  if (!px) {
    if (err) *err = stbi_failure_reason();
    return NULL;
  }
  /* stb reports the file's native channel count in *ch even when it converted
   * to `desired`; report what the caller actually got. */
  if (desired != 0) *ch = desired;
  return px;
}

void v3e_stb_free(void *p) { stbi_image_free(p); }

/* Probe dimensions without decoding the raster -- used to reject oversized
 * uploads before allocating for them. Returns 1 on success. */
int v3e_stb_info(const unsigned char *buf, int len, int *w, int *h, int *ch) {
  return stbi_info_from_memory(buf, len, w, h, ch);
}

typedef struct {
  unsigned char *data;
  int len;
  int cap;
  int failed;
} v3e_sink;

static void v3e_sink_write(void *ctx, void *data, int size) {
  v3e_sink *s = (v3e_sink *)ctx;
  if (s->failed || size <= 0) return;
  if (s->len + size > s->cap) {
    int ncap = s->cap ? s->cap * 2 : 65536;
    unsigned char *n;
    while (ncap < s->len + size) ncap *= 2;
    n = (unsigned char *)realloc(s->data, (size_t)ncap);
    if (!n) {
      s->failed = 1;
      return;
    }
    s->data = n;
    s->cap = ncap;
  }
  memcpy(s->data + s->len, data, (size_t)size);
  s->len += size;
}

/* Encode to PNG. On success returns 1 and sets *out (free with free()) and
 * *out_len. Returns 0 on failure. */
int v3e_stb_encode_png(const unsigned char *px, int w, int h, int ch,
                       unsigned char **out, int *out_len) {
  v3e_sink s = {NULL, 0, 0, 0};
  int ok = stbi_write_png_to_func(v3e_sink_write, &s, w, h, ch, px, w * ch);
  if (!ok || s.failed) {
    free(s.data);
    return 0;
  }
  *out = s.data;
  *out_len = s.len;
  return 1;
}

int v3e_stb_encode_jpg(const unsigned char *px, int w, int h, int ch,
                       int quality, unsigned char **out, int *out_len) {
  v3e_sink s = {NULL, 0, 0, 0};
  int ok;
  if (quality < 1) quality = 1;
  if (quality > 100) quality = 100;
  ok = stbi_write_jpg_to_func(v3e_sink_write, &s, w, h, ch, px, quality);
  if (!ok || s.failed) {
    free(s.data);
    return 0;
  }
  *out = s.data;
  *out_len = s.len;
  return 1;
}

void v3e_stb_encode_free(void *p) { free(p); }
