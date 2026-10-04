#include <stddef.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include <slu_ddefs.h>

int cerealgrain_solve_sparse_lu(
    size_t n,
    const size_t* row_offsets,
    const size_t* columns,
    const double* values,
    size_t nnz,
    size_t channels,
    const double* rhs,
    double* output
) {
    if (n == 0 || channels == 0 || row_offsets == NULL || columns == NULL ||
        values == NULL || rhs == NULL || output == NULL ||
        row_offsets[n] != nnz || n > (size_t)INT_MAX ||
        nnz > (size_t)INT_MAX || channels > (size_t)INT_MAX) {
        return -1;
    }

    int n_int = (int)n;
    int nnz_int = (int)nnz;
    int channels_int = (int)channels;
    int* col_counts = (int*)calloc(n, sizeof(int));
    int* colptr = (int*)malloc((n + 1) * sizeof(int));
    int* next = (int*)malloc(n * sizeof(int));
    int* rowind = (int*)malloc(nnz * sizeof(int));
    double* nzval = (double*)malloc(nnz * sizeof(double));
    double* b_values = (double*)malloc(n * channels * sizeof(double));
    int* perm_c = (int*)malloc(n * sizeof(int));
    int* perm_r = (int*)malloc(n * sizeof(int));
    if (col_counts == NULL || colptr == NULL || next == NULL || rowind == NULL ||
        nzval == NULL || b_values == NULL || perm_c == NULL || perm_r == NULL) {
        free(col_counts);
        free(colptr);
        free(next);
        free(rowind);
        free(nzval);
        free(b_values);
        free(perm_c);
        free(perm_r);
        return -1;
    }

    for (size_t row = 0; row < n; ++row) {
        if (row_offsets[row] > row_offsets[row + 1] || row_offsets[row + 1] > nnz) {
            free(col_counts);
            free(colptr);
            free(next);
            free(rowind);
            free(nzval);
            free(b_values);
            free(perm_c);
            free(perm_r);
            return -1;
        }
        for (size_t index = row_offsets[row]; index < row_offsets[row + 1]; ++index) {
            if (columns[index] >= n) {
                free(col_counts);
                free(colptr);
                free(next);
                free(rowind);
                free(nzval);
                free(b_values);
                free(perm_c);
                free(perm_r);
                return -1;
            }
            col_counts[columns[index]] += 1;
        }
    }

    colptr[0] = 0;
    for (size_t col = 0; col < n; ++col) {
        colptr[col + 1] = colptr[col] + col_counts[col];
        next[col] = colptr[col];
    }

    for (size_t row = 0; row < n; ++row) {
        for (size_t index = row_offsets[row]; index < row_offsets[row + 1]; ++index) {
            size_t col = columns[index];
            int dest = next[col]++;
            rowind[dest] = (int)row;
            nzval[dest] = values[index];
        }
    }

    for (size_t row = 0; row < n; ++row) {
        for (size_t channel = 0; channel < channels; ++channel) {
            b_values[channel * n + row] = rhs[row * channels + channel];
        }
    }

    SuperMatrix A;
    SuperMatrix B;
    SuperMatrix L;
    SuperMatrix U;
    superlu_options_t options;
    SuperLUStat_t stat;
    int info = 0;
    dCreate_CompCol_Matrix(&A, n_int, n_int, nnz_int, nzval, rowind, colptr,
                           SLU_NC, SLU_D, SLU_GE);
    dCreate_Dense_Matrix(&B, n_int, channels_int, b_values, n_int,
                         SLU_DN, SLU_D, SLU_GE);
    set_default_options(&options);
    options.ColPerm = MMD_ATA;
    StatInit(&stat);
    dgssv(&options, &A, perm_c, perm_r, &L, &U, &B, &stat, &info);

    if (info == 0) {
        for (size_t row = 0; row < n; ++row) {
            for (size_t channel = 0; channel < channels; ++channel) {
                output[row * channels + channel] = b_values[channel * n + row];
            }
        }
    }

    StatFree(&stat);
    if (info == 0) {
        Destroy_SuperNode_Matrix(&L);
        Destroy_CompCol_Matrix(&U);
    }
    Destroy_SuperMatrix_Store(&A);
    Destroy_SuperMatrix_Store(&B);
    free(col_counts);
    free(colptr);
    free(next);
    free(rowind);
    free(nzval);
    free(b_values);
    free(perm_c);
    free(perm_r);

    return info;
}
