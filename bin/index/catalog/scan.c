#define _GNU_SOURCE
#include <stdint.h>
#include <string.h>

/* Marks every line of the blob that contains term. starts[i] is the offset of line i. */
void mark_lines(const uint8_t *blob, int64_t n, const int64_t *starts, int64_t nlines,
                const uint8_t *term, int64_t m, uint8_t *out) {
    int64_t pos = 0;
    while (pos + m <= n) {
        const uint8_t *f = memmem(blob + pos, (size_t)(n - pos), term, (size_t)m);
        if (!f) break;
        int64_t p = f - blob;
        int64_t lo = 0, hi = nlines - 1;
        while (lo < hi) {
            int64_t mid = (lo + hi + 1) / 2;
            if (starts[mid] <= p) lo = mid; else hi = mid - 1;
        }
        out[lo] = 1;
        pos = (lo + 1 < nlines) ? starts[lo + 1] : n;
    }
}

/* keep[k] = 1 when candidate line cand[k] contains term. */
void filter_lines(const uint8_t *blob, int64_t n, const int64_t *starts, int64_t nlines,
                  const int64_t *cand, int64_t nc, const uint8_t *term, int64_t m, uint8_t *keep) {
    for (int64_t k = 0; k < nc; k++) {
        int64_t li = cand[k];
        int64_t s = starts[li];
        int64_t e = (li + 1 < nlines) ? starts[li + 1] - 1 : n;
        keep[k] = (e - s >= m) && memmem(blob + s, (size_t)(e - s), term, (size_t)m) != NULL;
    }
}
