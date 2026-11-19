/* Optional, integer-only measurement accelerator. Every K-ordered prefix is
 * included in extrema. Callers prove sum(abs(products)) <= INT32_MAX first. */
#include <stdint.h>
#include <stddef.h>
#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API
#endif
API void kwt_mac(const int32_t *a, const int32_t *b, int32_t *out,
                 int batches, int rows, int inner, int cols,
                 int shared_a, int shared_b, int32_t *extrema) {
    int32_t lo = 0, hi = 0;
    for (int batch=0; batch<batches; ++batch) {
        const int32_t *aa=a+(shared_a?0:(size_t)batch*rows*inner);
        const int32_t *bb=b+(shared_b?0:(size_t)batch*inner*cols);
        int32_t *cc=out+(size_t)batch*rows*cols;
        for (int i=0; i<rows; ++i) {
            int32_t *row=cc+(size_t)i*cols;
            for (int j=0; j<cols; ++j) row[j]=0;
            for (int k=0; k<inner; ++k) {
                int32_t av=aa[(size_t)i*inner+k];
                const int32_t *br=bb+(size_t)k*cols;
                for (int j=0; j<cols; ++j) {
                    int32_t v=row[j]+av*br[j];
                    row[j]=v;
                    if (v<lo) lo=v;
                    if (v>hi) hi=v;
                }
            }
        }
    }
    extrema[0]=lo; extrema[1]=hi;
}
