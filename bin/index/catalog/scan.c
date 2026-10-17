#define _GNU_SOURCE
#include <stdint.h>
#include <string.h>

#include <pthread.h>

typedef struct {
    const uint8_t *blob; int64_t n; const int64_t *starts; int64_t nlines;
    const uint8_t *term; int64_t m; uint8_t *out; int64_t l0, l1;
} job_t;

/* Marks the lines [l0, l1) that contain term. Terms hold no newline, so a match never spans lines. The line
   cursor only moves forward (no binary search per hit), and a one-byte term is a plain memchr. */
static void *worker(void *arg) {
    job_t *j = (job_t *)arg;
    int64_t pos = j->starts[j->l0];
    int64_t end = (j->l1 < j->nlines) ? j->starts[j->l1] : j->n;
    int64_t line = j->l0;
    while (pos + j->m <= end) {
        const uint8_t *f = (j->m == 1)
            ? (const uint8_t *)memchr(j->blob + pos, j->term[0], (size_t)(end - pos))
            : (const uint8_t *)memmem(j->blob + pos, (size_t)(end - pos), j->term, (size_t)j->m);
        if (!f) break;
        int64_t p = f - j->blob;
        while (line + 1 < j->l1 && j->starts[line + 1] <= p) line++;
        j->out[line] = 1;
        if (line + 1 >= j->l1) break;
        pos = j->starts[line + 1];
    }
    return NULL;
}

/* Marks every line of the blob that contains term. starts[i] is the offset of line i. The work is split over
   threads by line ranges (each writes only its own lines of out). */
void mark_lines(const uint8_t *blob, int64_t n, const int64_t *starts, int64_t nlines,
                const uint8_t *term, int64_t m, uint8_t *out) {
    if (nlines <= 0 || m <= 0) return;
    int64_t nt = nlines < 200000 ? 1 : 8;
    pthread_t th[8];
    job_t jobs[8];
    for (int64_t t = 0; t < nt; t++) {
        jobs[t] = (job_t){blob, n, starts, nlines, term, m, out, nlines * t / nt, nlines * (t + 1) / nt};
    }
    for (int64_t t = 1; t < nt; t++) pthread_create(&th[t], NULL, worker, &jobs[t]);
    worker(&jobs[0]);
    for (int64_t t = 1; t < nt; t++) pthread_join(th[t], NULL);
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
