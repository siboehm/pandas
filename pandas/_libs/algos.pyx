import cython
from cython import Py_ssize_t

from libc.math cimport (
    fabs,
    sqrt,
)
from libc.stdlib cimport (
    free,
    malloc,
)
from libc.string cimport memmove

import numpy as np

cimport numpy as cnp
from numpy cimport (
    NPY_FLOAT32,
    NPY_FLOAT64,
    NPY_INT8,
    NPY_INT16,
    NPY_INT32,
    NPY_INT64,
    NPY_OBJECT,
    NPY_UINT8,
    NPY_UINT16,
    NPY_UINT32,
    NPY_UINT64,
    float32_t,
    float64_t,
    int8_t,
    int16_t,
    int32_t,
    int64_t,
    intp_t,
    ndarray,
    uint8_t,
    uint16_t,
    uint32_t,
    uint64_t,
)

cnp.import_array()

cimport pandas._libs.util as util
from pandas._libs.khash cimport (
    kh_destroy_int64,
    kh_get_int64,
    kh_init_int64,
    kh_int64_t,
    kh_put_int64,
    kh_resize_int64,
    khiter_t,
)
from pandas._libs.util cimport (
    get_nat,
    numeric,
)

import pandas._libs.missing as missing

cdef:
    float64_t FP_ERR = 1e-13
    float64_t NaN = <float64_t>np.NaN
    int64_t NPY_NAT = get_nat()

cdef enum TiebreakEnumType:
    TIEBREAK_AVERAGE
    TIEBREAK_MIN,
    TIEBREAK_MAX
    TIEBREAK_FIRST
    TIEBREAK_FIRST_DESCENDING
    TIEBREAK_DENSE

tiebreakers = {
    "average": TIEBREAK_AVERAGE,
    "min": TIEBREAK_MIN,
    "max": TIEBREAK_MAX,
    "first": TIEBREAK_FIRST,
    "dense": TIEBREAK_DENSE,
}


cdef inline bint are_diff(object left, object right):
    try:
        return fabs(left - right) > FP_ERR
    except TypeError:
        return left != right


class Infinity:
    """
    Provide a positive Infinity comparison method for ranking.
    """
    __lt__ = lambda self, other: False
    __le__ = lambda self, other: isinstance(other, Infinity)
    __eq__ = lambda self, other: isinstance(other, Infinity)
    __ne__ = lambda self, other: not isinstance(other, Infinity)
    __gt__ = lambda self, other: (not isinstance(other, Infinity) and
                                  not missing.checknull(other))
    __ge__ = lambda self, other: not missing.checknull(other)


class NegInfinity:
    """
    Provide a negative Infinity comparison method for ranking.
    """
    __lt__ = lambda self, other: (not isinstance(other, NegInfinity) and
                                  not missing.checknull(other))
    __le__ = lambda self, other: not missing.checknull(other)
    __eq__ = lambda self, other: isinstance(other, NegInfinity)
    __ne__ = lambda self, other: not isinstance(other, NegInfinity)
    __gt__ = lambda self, other: False
    __ge__ = lambda self, other: isinstance(other, NegInfinity)


@cython.wraparound(False)
@cython.boundscheck(False)
cpdef ndarray[int64_t, ndim=1] unique_deltas(const int64_t[:] arr):
    """
    Efficiently find the unique first-differences of the given array.

    Parameters
    ----------
    arr : ndarray[in64_t]

    Returns
    -------
    ndarray[int64_t]
        An ordered ndarray[int64_t]
    """
    cdef:
        Py_ssize_t i, n = len(arr)
        int64_t val
        khiter_t k
        kh_int64_t *table
        int ret = 0
        list uniques = []
        ndarray[int64_t, ndim=1] result

    table = kh_init_int64()
    kh_resize_int64(table, 10)
    for i in range(n - 1):
        val = arr[i + 1] - arr[i]
        k = kh_get_int64(table, val)
        if k == table.n_buckets:
            kh_put_int64(table, val, &ret)
            uniques.append(val)
    kh_destroy_int64(table)

    result = np.array(uniques, dtype=np.int64)
    result.sort()
    return result


@cython.wraparound(False)
@cython.boundscheck(False)
def is_lexsorted(list_of_arrays: list) -> bint:
    cdef:
        Py_ssize_t i
        Py_ssize_t n, nlevels
        int64_t k, cur, pre
        ndarray arr
        bint result = True

    nlevels = len(list_of_arrays)
    n = len(list_of_arrays[0])

    cdef int64_t **vecs = <int64_t**>malloc(nlevels * sizeof(int64_t*))
    for i in range(nlevels):
        arr = list_of_arrays[i]
        assert arr.dtype.name == 'int64'
        vecs[i] = <int64_t*>cnp.PyArray_DATA(arr)

    # Assume uniqueness??
    with nogil:
        for i in range(1, n):
            for k in range(nlevels):
                cur = vecs[k][i]
                pre = vecs[k][i -1]
                if cur == pre:
                    continue
                elif cur > pre:
                    break
                else:
                    result = False
                    break
    free(vecs)
    return result


@cython.boundscheck(False)
@cython.wraparound(False)
def groupsort_indexer(const intp_t[:] index, Py_ssize_t ngroups):
    """
    Compute a 1-d indexer.

    The indexer is an ordering of the passed index,
    ordered by the groups.

    Parameters
    ----------
    index: np.ndarray[np.intp]
        Mappings from group -> position.
    ngroups: int64
        Number of groups.

    Returns
    -------
    ndarray[intp_t, ndim=1]
        Indexer
    ndarray[intp_t, ndim=1]
        Group Counts

    Notes
    -----
    This is a reverse of the label factorization process.
    """
    cdef:
        Py_ssize_t i, loc, label, n
        ndarray[intp_t] indexer, where, counts

    counts = np.zeros(ngroups + 1, dtype=np.intp)
    n = len(index)
    indexer = np.zeros(n, dtype=np.intp)
    where = np.zeros(ngroups + 1, dtype=np.intp)

    with nogil:

        # count group sizes, location 0 for NA
        for i in range(n):
            counts[index[i] + 1] += 1

        # mark the start of each contiguous group of like-indexed data
        for i in range(1, ngroups + 1):
            where[i] = where[i - 1] + counts[i - 1]

        # this is our indexer
        for i in range(n):
            label = index[i] + 1
            indexer[where[label]] = i
            where[label] += 1

    return indexer, counts


cdef inline Py_ssize_t swap(numeric *a, numeric *b) nogil:
    cdef:
        numeric t

    # cython doesn't allow pointer dereference so use array syntax
    t = a[0]
    a[0] = b[0]
    b[0] = t
    return 0


cdef inline numeric kth_smallest_c(numeric* arr, Py_ssize_t k, Py_ssize_t n) nogil:
    """
    See kth_smallest.__doc__. The additional parameter n specifies the maximum
    number of elements considered in arr, needed for compatibility with usage
    in groupby.pyx
    """
    cdef:
        Py_ssize_t i, j, l, m
        numeric x

    l = 0
    m = n - 1

    while l < m:
        x = arr[k]
        i = l
        j = m

        while 1:
            while arr[i] < x: i += 1
            while x < arr[j]: j -= 1
            if i <= j:
                swap(&arr[i], &arr[j])
                i += 1; j -= 1

            if i > j: break

        if j < k: l = i
        if k < i: m = j
    return arr[k]


@cython.boundscheck(False)
@cython.wraparound(False)
def kth_smallest(numeric[::1] arr, Py_ssize_t k) -> numeric:
    """
    Compute the kth smallest value in arr. Note that the input
    array will be modified.

    Parameters
    ----------
    arr : numeric[::1]
        Array to compute the kth smallest value for, must be
        contiguous
    k : Py_ssize_t

    Returns
    -------
    numeric
        The kth smallest value in arr
    """
    cdef:
        numeric result

    with nogil:
        result = kth_smallest_c(&arr[0], k, arr.shape[0])

    return result


# ----------------------------------------------------------------------
# Pairwise correlation/covariance


@cython.boundscheck(False)
@cython.wraparound(False)
def nancorr(const float64_t[:, :] mat, bint cov=False, minp=None):
    cdef:
        Py_ssize_t i, j, xi, yi, N, K
        bint minpv
        ndarray[float64_t, ndim=2] result
        ndarray[uint8_t, ndim=2] mask
        int64_t nobs = 0
        float64_t vx, vy, meanx, meany, divisor, prev_meany, prev_meanx, ssqdmx
        float64_t ssqdmy, covxy

    N, K = (<object>mat).shape

    if minp is None:
        minpv = 1
    else:
        minpv = <int>minp

    result = np.empty((K, K), dtype=np.float64)
    mask = np.isfinite(mat).view(np.uint8)

    with nogil:
        for xi in range(K):
            for yi in range(xi + 1):
                # Welford's method for the variance-calculation
                # https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance
                nobs = ssqdmx = ssqdmy = covxy = meanx = meany = 0
                for i in range(N):
                    if mask[i, xi] and mask[i, yi]:
                        vx = mat[i, xi]
                        vy = mat[i, yi]
                        nobs += 1
                        prev_meanx = meanx
                        prev_meany = meany
                        meanx = meanx + 1 / nobs * (vx - meanx)
                        meany = meany + 1 / nobs * (vy - meany)
                        ssqdmx = ssqdmx + (vx - meanx) * (vx - prev_meanx)
                        ssqdmy = ssqdmy + (vy - meany) * (vy - prev_meany)
                        covxy = covxy + (vx - meanx) * (vy - prev_meany)

                if nobs < minpv:
                    result[xi, yi] = result[yi, xi] = NaN
                else:
                    divisor = (nobs - 1.0) if cov else sqrt(ssqdmx * ssqdmy)

                    if divisor != 0:
                        result[xi, yi] = result[yi, xi] = covxy / divisor
                    else:
                        result[xi, yi] = result[yi, xi] = NaN

    return result

# ----------------------------------------------------------------------
# Pairwise Spearman correlation


@cython.boundscheck(False)
@cython.wraparound(False)
def nancorr_spearman(ndarray[float64_t, ndim=2] mat, Py_ssize_t minp=1) -> ndarray:
    cdef:
        Py_ssize_t i, j, xi, yi, N, K
        ndarray[float64_t, ndim=2] result
        ndarray[float64_t, ndim=2] ranked_mat
        ndarray[float64_t, ndim=1] maskedx
        ndarray[float64_t, ndim=1] maskedy
        ndarray[uint8_t, ndim=2] mask
        int64_t nobs = 0
        float64_t vx, vy, sumx, sumxx, sumyy, mean, divisor
        const int64_t[:] labels_n, labels_nobs

    N, K = (<object>mat).shape
    # For compatibility when calling rank_1d
    labels_n = np.zeros(N, dtype=np.int64)

    result = np.empty((K, K), dtype=np.float64)
    mask = np.isfinite(mat).view(np.uint8)

    ranked_mat = np.empty((N, K), dtype=np.float64)

    for i in range(K):
        ranked_mat[:, i] = rank_1d(mat[:, i], labels=labels_n)

    for xi in range(K):
        for yi in range(xi + 1):
            nobs = 0
            # Keep track of whether we need to recompute ranks
            all_ranks = True
            for i in range(N):
                all_ranks &= not (mask[i, xi] ^ mask[i, yi])
                if mask[i, xi] and mask[i, yi]:
                    nobs += 1

            if nobs < minp:
                result[xi, yi] = result[yi, xi] = NaN
            else:
                maskedx = np.empty(nobs, dtype=np.float64)
                maskedy = np.empty(nobs, dtype=np.float64)
                j = 0

                for i in range(N):
                    if mask[i, xi] and mask[i, yi]:
                        maskedx[j] = ranked_mat[i, xi]
                        maskedy[j] = ranked_mat[i, yi]
                        j += 1

                if not all_ranks:
                    labels_nobs = np.zeros(nobs, dtype=np.int64)
                    maskedx = rank_1d(maskedx, labels=labels_nobs)
                    maskedy = rank_1d(maskedy, labels=labels_nobs)

                mean = (nobs + 1) / 2.

                # now the cov numerator
                sumx = sumxx = sumyy = 0

                for i in range(nobs):
                    vx = maskedx[i] - mean
                    vy = maskedy[i] - mean

                    sumx += vx * vy
                    sumxx += vx * vx
                    sumyy += vy * vy

                divisor = sqrt(sumxx * sumyy)

                if divisor != 0:
                    result[xi, yi] = result[yi, xi] = sumx / divisor
                else:
                    result[xi, yi] = result[yi, xi] = NaN

    return result


# ----------------------------------------------------------------------
# Kendall correlation
# Wikipedia article: https://en.wikipedia.org/wiki/Kendall_rank_correlation_coefficient

@cython.boundscheck(False)
@cython.wraparound(False)
def nancorr_kendall(ndarray[float64_t, ndim=2] mat, Py_ssize_t minp=1) -> ndarray:
    """
    Perform kendall correlation on a 2d array

    Parameters
    ----------
    mat : np.ndarray[float64_t, ndim=2]
        Array to compute kendall correlation on
    minp : int, default 1
        Minimum number of observations required per pair of columns
        to have a valid result.

    Returns
    -------
    numpy.ndarray[float64_t, ndim=2]
        Correlation matrix
    """
    cdef:
        Py_ssize_t i, j, k, xi, yi, N, K
        ndarray[float64_t, ndim=2] result
        ndarray[float64_t, ndim=2] ranked_mat
        ndarray[uint8_t, ndim=2] mask
        float64_t currj
        ndarray[uint8_t, ndim=1] valid
        ndarray[int64_t] sorted_idxs
        ndarray[float64_t, ndim=1] col
        int64_t n_concordant
        int64_t total_concordant = 0
        int64_t total_discordant = 0
        float64_t kendall_tau
        int64_t n_obs
        const intp_t[:] labels_n

    N, K = (<object>mat).shape

    result = np.empty((K, K), dtype=np.float64)
    mask = np.isfinite(mat)

    ranked_mat = np.empty((N, K), dtype=np.float64)
    # For compatibility when calling rank_1d
    labels_n = np.zeros(N, dtype=np.intp)

    for i in range(K):
        ranked_mat[:, i] = rank_1d(mat[:, i], labels_n)

    for xi in range(K):
        sorted_idxs = ranked_mat[:, xi].argsort()
        ranked_mat = ranked_mat[sorted_idxs]
        mask = mask[sorted_idxs]
        for yi in range(xi + 1, K):
            valid = mask[:, xi] & mask[:, yi]
            if valid.sum() < minp:
                result[xi, yi] = NaN
                result[yi, xi] = NaN
            else:
                # Get columns and order second column using 1st column ranks
                if not valid.all():
                    col = ranked_mat[valid.nonzero()][:, yi]
                else:
                    col = ranked_mat[:, yi]
                n_obs = col.shape[0]
                total_concordant = 0
                total_discordant = 0
                for j in range(n_obs - 1):
                    currj = col[j]
                    # Count num concordant and discordant pairs
                    n_concordant = 0
                    for k in range(j, n_obs):
                        if col[k] > currj:
                            n_concordant += 1
                    total_concordant += n_concordant
                    total_discordant += (n_obs - 1 - j - n_concordant)
                # Note: we do total_concordant+total_discordant here which is
                # equivalent to the C(n, 2), the total # of pairs,
                # listed on wikipedia
                kendall_tau = (total_concordant - total_discordant) / \
                              (total_concordant + total_discordant)
                result[xi, yi] = kendall_tau
                result[yi, xi] = kendall_tau

        if mask[:, xi].sum() > minp:
            result[xi, xi] = 1
        else:
            result[xi, xi] = NaN

    return result


# ----------------------------------------------------------------------

ctypedef fused algos_t:
    float64_t
    float32_t
    object
    int64_t
    int32_t
    int16_t
    int8_t
    uint64_t
    uint32_t
    uint16_t
    uint8_t


def validate_limit(nobs: int, limit=None) -> int:
    """
    Check that the `limit` argument is a positive integer.

    Parameters
    ----------
    nobs : int
    limit : object

    Returns
    -------
    int
        The limit.
    """
    if limit is None:
        lim = nobs
    else:
        if not util.is_integer_object(limit):
            raise ValueError('Limit must be an integer')
        if limit < 1:
            raise ValueError('Limit must be greater than 0')
        lim = limit

    return lim


@cython.boundscheck(False)
@cython.wraparound(False)
def pad(ndarray[algos_t] old, ndarray[algos_t] new, limit=None) -> ndarray:
    # -> ndarray[intp_t, ndim=1]
    cdef:
        Py_ssize_t i, j, nleft, nright
        ndarray[intp_t, ndim=1] indexer
        algos_t cur, next_val
        int lim, fill_count = 0

    nleft = len(old)
    nright = len(new)
    indexer = np.empty(nright, dtype=np.intp)
    indexer[:] = -1

    lim = validate_limit(nright, limit)

    if nleft == 0 or nright == 0 or new[nright - 1] < old[0]:
        return indexer

    i = j = 0

    cur = old[0]

    while j <= nright - 1 and new[j] < cur:
        j += 1

    while True:
        if j == nright:
            break

        if i == nleft - 1:
            while j < nright:
                if new[j] == cur:
                    indexer[j] = i
                elif new[j] > cur and fill_count < lim:
                    indexer[j] = i
                    fill_count += 1
                j += 1
            break

        next_val = old[i + 1]

        while j < nright and cur <= new[j] < next_val:
            if new[j] == cur:
                indexer[j] = i
            elif fill_count < lim:
                indexer[j] = i
                fill_count += 1
            j += 1

        fill_count = 0
        i += 1
        cur = next_val

    return indexer


@cython.boundscheck(False)
@cython.wraparound(False)
def pad_inplace(algos_t[:] values, uint8_t[:] mask, limit=None):
    cdef:
        Py_ssize_t i, N
        algos_t val
        uint8_t prev_mask
        int lim, fill_count = 0

    N = len(values)

    # GH#2778
    if N == 0:
        return

    lim = validate_limit(N, limit)

    val = values[0]
    prev_mask = mask[0]
    for i in range(N):
        if mask[i]:
            if fill_count >= lim:
                continue
            fill_count += 1
            values[i] = val
            mask[i] = prev_mask
        else:
            fill_count = 0
            val = values[i]
            prev_mask = mask[i]


@cython.boundscheck(False)
@cython.wraparound(False)
def pad_2d_inplace(algos_t[:, :] values, const uint8_t[:, :] mask, limit=None):
    cdef:
        Py_ssize_t i, j, N, K
        algos_t val
        int lim, fill_count = 0

    K, N = (<object>values).shape

    # GH#2778
    if N == 0:
        return

    lim = validate_limit(N, limit)

    for j in range(K):
        fill_count = 0
        val = values[j, 0]
        for i in range(N):
            if mask[j, i]:
                if fill_count >= lim:
                    continue
                fill_count += 1
                values[j, i] = val
            else:
                fill_count = 0
                val = values[j, i]


"""
Backfilling logic for generating fill vector

Diagram of what's going on

Old      New    Fill vector    Mask
         .        0               1
         .        0               1
         .        0               1
A        A        0               1
         .        1               1
         .        1               1
         .        1               1
         .        1               1
         .        1               1
B        B        1               1
         .        2               1
         .        2               1
         .        2               1
C        C        2               1
         .                        0
         .                        0
D
"""


@cython.boundscheck(False)
@cython.wraparound(False)
def backfill(ndarray[algos_t] old, ndarray[algos_t] new, limit=None) -> ndarray:
    # -> ndarray[intp_t, ndim=1]
    cdef:
        Py_ssize_t i, j, nleft, nright
        ndarray[intp_t, ndim=1] indexer
        algos_t cur, prev
        int lim, fill_count = 0

    nleft = len(old)
    nright = len(new)
    indexer = np.empty(nright, dtype=np.intp)
    indexer[:] = -1

    lim = validate_limit(nright, limit)

    if nleft == 0 or nright == 0 or new[0] > old[nleft - 1]:
        return indexer

    i = nleft - 1
    j = nright - 1

    cur = old[nleft - 1]

    while j >= 0 and new[j] > cur:
        j -= 1

    while True:
        if j < 0:
            break

        if i == 0:
            while j >= 0:
                if new[j] == cur:
                    indexer[j] = i
                elif new[j] < cur and fill_count < lim:
                    indexer[j] = i
                    fill_count += 1
                j -= 1
            break

        prev = old[i - 1]

        while j >= 0 and prev < new[j] <= cur:
            if new[j] == cur:
                indexer[j] = i
            elif new[j] < cur and fill_count < lim:
                indexer[j] = i
                fill_count += 1
            j -= 1

        fill_count = 0
        i -= 1
        cur = prev

    return indexer


def backfill_inplace(algos_t[:] values, uint8_t[:] mask, limit=None):
    pad_inplace(values[::-1], mask[::-1], limit=limit)


def backfill_2d_inplace(algos_t[:, :] values,
                        const uint8_t[:, :] mask,
                        limit=None):
    pad_2d_inplace(values[:, ::-1], mask[:, ::-1], limit)


@cython.boundscheck(False)
@cython.wraparound(False)
def is_monotonic(ndarray[algos_t, ndim=1] arr, bint timelike):
    """
    Returns
    -------
    tuple
        is_monotonic_inc : bool
        is_monotonic_dec : bool
        is_unique : bool
    """
    cdef:
        Py_ssize_t i, n
        algos_t prev, cur
        bint is_monotonic_inc = 1
        bint is_monotonic_dec = 1
        bint is_unique = 1
        bint is_strict_monotonic = 1

    n = len(arr)

    if n == 1:
        if arr[0] != arr[0] or (timelike and <int64_t>arr[0] == NPY_NAT):
            # single value is NaN
            return False, False, True
        else:
            return True, True, True
    elif n < 2:
        return True, True, True

    if timelike and <int64_t>arr[0] == NPY_NAT:
        return False, False, True

    if algos_t is not object:
        with nogil:
            prev = arr[0]
            for i in range(1, n):
                cur = arr[i]
                if timelike and <int64_t>cur == NPY_NAT:
                    is_monotonic_inc = 0
                    is_monotonic_dec = 0
                    break
                if cur < prev:
                    is_monotonic_inc = 0
                elif cur > prev:
                    is_monotonic_dec = 0
                elif cur == prev:
                    is_unique = 0
                else:
                    # cur or prev is NaN
                    is_monotonic_inc = 0
                    is_monotonic_dec = 0
                    break
                if not is_monotonic_inc and not is_monotonic_dec:
                    is_monotonic_inc = 0
                    is_monotonic_dec = 0
                    break
                prev = cur
    else:
        # object-dtype, identical to above except we cannot use `with nogil`
        prev = arr[0]
        for i in range(1, n):
            cur = arr[i]
            if timelike and <int64_t>cur == NPY_NAT:
                is_monotonic_inc = 0
                is_monotonic_dec = 0
                break
            if cur < prev:
                is_monotonic_inc = 0
            elif cur > prev:
                is_monotonic_dec = 0
            elif cur == prev:
                is_unique = 0
            else:
                # cur or prev is NaN
                is_monotonic_inc = 0
                is_monotonic_dec = 0
                break
            if not is_monotonic_inc and not is_monotonic_dec:
                is_monotonic_inc = 0
                is_monotonic_dec = 0
                break
            prev = cur

    is_strict_monotonic = is_unique and (is_monotonic_inc or is_monotonic_dec)
    return is_monotonic_inc, is_monotonic_dec, is_strict_monotonic


# ----------------------------------------------------------------------
# rank_1d, rank_2d
# ----------------------------------------------------------------------

ctypedef fused rank_t:
    object
    float64_t
    uint64_t
    int64_t


@cython.wraparound(False)
@cython.boundscheck(False)
def rank_1d(
    ndarray[rank_t, ndim=1] values,
    const intp_t[:] labels,
    bint is_datetimelike=False,
    ties_method="average",
    bint ascending=True,
    bint pct=False,
    na_option="keep",
):
    """
    Fast NaN-friendly version of ``scipy.stats.rankdata``.

    Parameters
    ----------
    values : array of rank_t values to be ranked
    labels : np.ndarray[np.intp]
        Array containing unique label for each group, with its ordering
        matching up to the corresponding record in `values`. If not called
        from a groupby operation, will be an array of 0's
    is_datetimelike : bool, default False
        True if `values` contains datetime-like entries.
    ties_method : {'average', 'min', 'max', 'first', 'dense'}, default
        'average'
        * average: average rank of group
        * min: lowest rank in group
        * max: highest rank in group
        * first: ranks assigned in order they appear in the array
        * dense: like 'min', but rank always increases by 1 between groups
    ascending : boolean, default True
        False for ranks by high (1) to low (N)
        na_option : {'keep', 'top', 'bottom'}, default 'keep'
    pct : boolean, default False
        Compute percentage rank of data within each group
    na_option : {'keep', 'top', 'bottom'}, default 'keep'
        * keep: leave NA values where they are
        * top: smallest rank if ascending
        * bottom: smallest rank if descending
    """
    cdef:
        TiebreakEnumType tiebreak
        Py_ssize_t i, j, N, grp_start=0, dups=0, sum_ranks=0
        Py_ssize_t grp_vals_seen=1, grp_na_count=0
        ndarray[int64_t, ndim=1] lexsort_indexer
        ndarray[float64_t, ndim=1] grp_sizes, out
        ndarray[rank_t, ndim=1] masked_vals
        ndarray[uint8_t, ndim=1] mask
        bint keep_na, at_end, next_val_diff, check_labels, group_changed
        rank_t nan_fill_val

    tiebreak = tiebreakers[ties_method]
    if tiebreak == TIEBREAK_FIRST:
        if not ascending:
            tiebreak = TIEBREAK_FIRST_DESCENDING

    keep_na = na_option == 'keep'

    N = len(values)
    # TODO Cython 3.0: cast won't be necessary (#2992)
    assert <Py_ssize_t>len(labels) == N
    out = np.empty(N)
    grp_sizes = np.ones(N)

    # If all 0 labels, can short-circuit later label
    # comparisons
    check_labels = np.any(labels)

    # Copy values into new array in order to fill missing data
    # with mask, without obfuscating location of missing data
    # in values array
    if rank_t is object and values.dtype != np.object_:
        masked_vals = values.astype('O')
    else:
        masked_vals = values.copy()

    if rank_t is object:
        mask = missing.isnaobj(masked_vals)
    elif rank_t is int64_t and is_datetimelike:
        mask = (masked_vals == NPY_NAT).astype(np.uint8)
    elif rank_t is float64_t:
        mask = np.isnan(masked_vals).astype(np.uint8)
    else:
        mask = np.zeros(shape=len(masked_vals), dtype=np.uint8)

    # If `na_option == 'top'`, we want to assign the lowest rank
    # to NaN regardless of ascending/descending. So if ascending,
    # fill with lowest value of type to end up with lowest rank.
    # If descending, fill with highest value since descending
    # will flip the ordering to still end up with lowest rank.
    # Symmetric logic applies to `na_option == 'bottom'`
    if ascending ^ (na_option == 'top'):
        if rank_t is object:
            nan_fill_val = Infinity()
        elif rank_t is int64_t:
            nan_fill_val = np.iinfo(np.int64).max
        elif rank_t is uint64_t:
            nan_fill_val = np.iinfo(np.uint64).max
        else:
            nan_fill_val = np.inf
        order = (masked_vals, mask, labels)
    else:
        if rank_t is object:
            nan_fill_val = NegInfinity()
        elif rank_t is int64_t:
            nan_fill_val = NPY_NAT
        elif rank_t is uint64_t:
            nan_fill_val = 0
        else:
            nan_fill_val = -np.inf

        order = (masked_vals, ~mask, labels)

    np.putmask(masked_vals, mask, nan_fill_val)

    # lexsort using labels, then mask, then actual values
    # each label corresponds to a different group value,
    # the mask helps you differentiate missing values before
    # performing sort on the actual values
    lexsort_indexer = np.lexsort(order).astype(np.int64, copy=False)

    if not ascending:
        lexsort_indexer = lexsort_indexer[::-1]

    # Loop over the length of the value array
    # each incremental i value can be looked up in the lexsort_indexer
    # array that we sorted previously, which gives us the location of
    # that sorted value for retrieval back from the original
    # values / masked_vals arrays
    # TODO: de-duplicate once cython supports conditional nogil
    if rank_t is object:
        for i in range(N):
            at_end = i == N - 1

            # dups and sum_ranks will be incremented each loop where
            # the value / group remains the same, and should be reset
            # when either of those change. Used to calculate tiebreakers
            dups += 1
            sum_ranks += i - grp_start + 1

            next_val_diff = at_end or are_diff(masked_vals[lexsort_indexer[i]],
                                               masked_vals[lexsort_indexer[i+1]])

            # We'll need this check later anyway to determine group size, so just
            # compute it here since shortcircuiting won't help
            group_changed = at_end or (check_labels and
                                       (labels[lexsort_indexer[i]]
                                        != labels[lexsort_indexer[i+1]]))

            # Update out only when there is a transition of values or labels.
            # When a new value or group is encountered, go back #dups steps(
            # the number of occurrence of current value) and assign the ranks
            # based on the starting index of the current group (grp_start)
            # and the current index
            if (next_val_diff or group_changed
                    or (mask[lexsort_indexer[i]] ^ mask[lexsort_indexer[i+1]])):

                # If keep_na, check for missing values and assign back
                # to the result where appropriate
                if keep_na and mask[lexsort_indexer[i]]:
                    grp_na_count = dups
                    for j in range(i - dups + 1, i + 1):
                        out[lexsort_indexer[j]] = NaN
                elif tiebreak == TIEBREAK_AVERAGE:
                    for j in range(i - dups + 1, i + 1):
                        out[lexsort_indexer[j]] = sum_ranks / <float64_t>dups
                elif tiebreak == TIEBREAK_MIN:
                    for j in range(i - dups + 1, i + 1):
                        out[lexsort_indexer[j]] = i - grp_start - dups + 2
                elif tiebreak == TIEBREAK_MAX:
                    for j in range(i - dups + 1, i + 1):
                        out[lexsort_indexer[j]] = i - grp_start + 1

                # With n as the previous rank in the group and m as the number
                # of duplicates in this stretch, if TIEBREAK_FIRST and ascending,
                # then rankings should be n + 1, n + 2 ... n + m
                elif tiebreak == TIEBREAK_FIRST:
                    for j in range(i - dups + 1, i + 1):
                        out[lexsort_indexer[j]] = j + 1 - grp_start

                # If TIEBREAK_FIRST and descending, the ranking should be
                # n + m, n + (m - 1) ... n + 1. This is equivalent to
                # (i - dups + 1) + (i - j + 1) - grp_start
                elif tiebreak == TIEBREAK_FIRST_DESCENDING:
                    for j in range(i - dups + 1, i + 1):
                        out[lexsort_indexer[j]] = 2 * i - j - dups + 2 - grp_start
                elif tiebreak == TIEBREAK_DENSE:
                    for j in range(i - dups + 1, i + 1):
                        out[lexsort_indexer[j]] = grp_vals_seen

                # Look forward to the next value (using the sorting in lexsort_indexer)
                # if the value does not equal the current value then we need to
                # reset the dups and sum_ranks, knowing that a new value is
                # coming up. The conditional also needs to handle nan equality
                # and the end of iteration
                if next_val_diff or (mask[lexsort_indexer[i]]
                                     ^ mask[lexsort_indexer[i+1]]):
                    dups = sum_ranks = 0
                    grp_vals_seen += 1

                # Similar to the previous conditional, check now if we are
                # moving to a new group. If so, keep track of the index where
                # the new group occurs, so the tiebreaker calculations can
                # decrement that from their position. Fill in the size of each
                # group encountered (used by pct calculations later). Also be
                # sure to reset any of the items helping to calculate dups
                if group_changed:
                    if tiebreak != TIEBREAK_DENSE:
                        for j in range(grp_start, i + 1):
                            grp_sizes[lexsort_indexer[j]] = \
                                (i - grp_start + 1 - grp_na_count)
                    else:
                        for j in range(grp_start, i + 1):
                            grp_sizes[lexsort_indexer[j]] = \
                                (grp_vals_seen - 1 - (grp_na_count > 0))
                    dups = sum_ranks = 0
                    grp_na_count = 0
                    grp_start = i + 1
                    grp_vals_seen = 1
    else:
        with nogil:
            for i in range(N):
                at_end = i == N - 1

                # dups and sum_ranks will be incremented each loop where
                # the value / group remains the same, and should be reset
                # when either of those change. Used to calculate tiebreakers
                dups += 1
                sum_ranks += i - grp_start + 1

                next_val_diff = at_end or (masked_vals[lexsort_indexer[i]]
                                           != masked_vals[lexsort_indexer[i+1]])

                # We'll need this check later anyway to determine group size, so just
                # compute it here since shortcircuiting won't help
                group_changed = at_end or (check_labels and
                                           (labels[lexsort_indexer[i]]
                                            != labels[lexsort_indexer[i+1]]))

                # Update out only when there is a transition of values or labels.
                # When a new value or group is encountered, go back #dups steps(
                # the number of occurrence of current value) and assign the ranks
                # based on the starting index of the current group (grp_start)
                # and the current index
                if (next_val_diff or group_changed
                        or (mask[lexsort_indexer[i]] ^ mask[lexsort_indexer[i+1]])):

                    # If keep_na, check for missing values and assign back
                    # to the result where appropriate
                    if keep_na and mask[lexsort_indexer[i]]:
                        grp_na_count = dups
                        for j in range(i - dups + 1, i + 1):
                            out[lexsort_indexer[j]] = NaN
                    elif tiebreak == TIEBREAK_AVERAGE:
                        for j in range(i - dups + 1, i + 1):
                            out[lexsort_indexer[j]] = sum_ranks / <float64_t>dups
                    elif tiebreak == TIEBREAK_MIN:
                        for j in range(i - dups + 1, i + 1):
                            out[lexsort_indexer[j]] = i - grp_start - dups + 2
                    elif tiebreak == TIEBREAK_MAX:
                        for j in range(i - dups + 1, i + 1):
                            out[lexsort_indexer[j]] = i - grp_start + 1

                    # With n as the previous rank in the group and m as the number
                    # of duplicates in this stretch, if TIEBREAK_FIRST and ascending,
                    # then rankings should be n + 1, n + 2 ... n + m
                    elif tiebreak == TIEBREAK_FIRST:
                        for j in range(i - dups + 1, i + 1):
                            out[lexsort_indexer[j]] = j + 1 - grp_start

                    # If TIEBREAK_FIRST and descending, the ranking should be
                    # n + m, n + (m - 1) ... n + 1. This is equivalent to
                    # (i - dups + 1) + (i - j + 1) - grp_start
                    elif tiebreak == TIEBREAK_FIRST_DESCENDING:
                        for j in range(i - dups + 1, i + 1):
                            out[lexsort_indexer[j]] = 2 * i - j - dups + 2 - grp_start
                    elif tiebreak == TIEBREAK_DENSE:
                        for j in range(i - dups + 1, i + 1):
                            out[lexsort_indexer[j]] = grp_vals_seen

                    # Look forward to the next value (using the sorting in
                    # lexsort_indexer) if the value does not equal the current
                    # value then we need to reset the dups and sum_ranks, knowing
                    # that a new value is coming up. The conditional also needs
                    # to handle nan equality and the end of iteration
                    if next_val_diff or (mask[lexsort_indexer[i]]
                                         ^ mask[lexsort_indexer[i+1]]):
                        dups = sum_ranks = 0
                        grp_vals_seen += 1

                    # Similar to the previous conditional, check now if we are
                    # moving to a new group. If so, keep track of the index where
                    # the new group occurs, so the tiebreaker calculations can
                    # decrement that from their position. Fill in the size of each
                    # group encountered (used by pct calculations later). Also be
                    # sure to reset any of the items helping to calculate dups
                    if group_changed:
                        if tiebreak != TIEBREAK_DENSE:
                            for j in range(grp_start, i + 1):
                                grp_sizes[lexsort_indexer[j]] = \
                                    (i - grp_start + 1 - grp_na_count)
                        else:
                            for j in range(grp_start, i + 1):
                                grp_sizes[lexsort_indexer[j]] = \
                                    (grp_vals_seen - 1 - (grp_na_count > 0))
                        dups = sum_ranks = 0
                        grp_na_count = 0
                        grp_start = i + 1
                        grp_vals_seen = 1

    if pct:
        for i in range(N):
            if grp_sizes[i] != 0:
                out[i] = out[i] / grp_sizes[i]

    return out


def rank_2d(
    ndarray[rank_t, ndim=2] in_arr,
    int axis=0,
    bint is_datetimelike=False,
    ties_method="average",
    bint ascending=True,
    na_option="keep",
    bint pct=False,
):
    """
    Fast NaN-friendly version of ``scipy.stats.rankdata``.
    """
    cdef:
        Py_ssize_t i, j, z, k, n, dups = 0, total_tie_count = 0
        Py_ssize_t infs
        ndarray[float64_t, ndim=2] ranks
        ndarray[rank_t, ndim=2] values
        ndarray[intp_t, ndim=2] argsort_indexer
        ndarray[uint8_t, ndim=2] mask
        rank_t val, nan_value
        float64_t count, sum_ranks = 0.0
        int tiebreak = 0
        int64_t idx
        bint check_mask, condition, keep_na

    tiebreak = tiebreakers[ties_method]

    keep_na = na_option == 'keep'

    # For cases where a mask is not possible, we can avoid mask checks
    check_mask = not (rank_t is uint64_t or (rank_t is int64_t and not is_datetimelike))

    if axis == 0:
        values = np.asarray(in_arr).T.copy()
    else:
        values = np.asarray(in_arr).copy()

    if rank_t is object:
        if values.dtype != np.object_:
            values = values.astype('O')

    if check_mask:
        if ascending ^ (na_option == 'top'):
            if rank_t is object:
                nan_value = Infinity()
            elif rank_t is float64_t:
                nan_value = np.inf

            # int64 and datetimelike
            else:
                nan_value = np.iinfo(np.int64).max

        else:
            if rank_t is object:
                nan_value = NegInfinity()
            elif rank_t is float64_t:
                nan_value = -np.inf

            # int64 and datetimelike
            else:
                nan_value = NPY_NAT

        if rank_t is object:
            mask = missing.isnaobj2d(values)
        elif rank_t is float64_t:
            mask = np.isnan(values)

        # int64 and datetimelike
        else:
            mask = values == NPY_NAT

        np.putmask(values, mask, nan_value)
    else:
        mask = np.zeros_like(values, dtype=bool)

    n, k = (<object>values).shape
    ranks = np.empty((n, k), dtype='f8')

    if tiebreak == TIEBREAK_FIRST:
        # need to use a stable sort here
        argsort_indexer = values.argsort(axis=1, kind='mergesort')
        if not ascending:
            tiebreak = TIEBREAK_FIRST_DESCENDING
    else:
        argsort_indexer = values.argsort(1)

    if not ascending:
        argsort_indexer = argsort_indexer[:, ::-1]

    values = _take_2d(values, argsort_indexer)

    for i in range(n):
        dups = sum_ranks = infs = 0

        total_tie_count = 0
        count = 0.0
        for j in range(k):
            val = values[i, j]
            idx = argsort_indexer[i, j]
            if keep_na and check_mask and mask[i, idx]:
                ranks[i, idx] = NaN
                infs += 1
                continue

            count += 1.0

            sum_ranks += (j - infs) + 1
            dups += 1

            if rank_t is object:
                condition = (
                    j == k - 1 or
                    are_diff(values[i, j + 1], val) or
                    (keep_na and check_mask and mask[i, argsort_indexer[i, j + 1]])
                )
            else:
                condition = (
                    j == k - 1 or
                    values[i, j + 1] != val or
                    (keep_na and check_mask and mask[i, argsort_indexer[i, j + 1]])
                )

            if condition:
                if tiebreak == TIEBREAK_AVERAGE:
                    for z in range(j - dups + 1, j + 1):
                        ranks[i, argsort_indexer[i, z]] = sum_ranks / dups
                elif tiebreak == TIEBREAK_MIN:
                    for z in range(j - dups + 1, j + 1):
                        ranks[i, argsort_indexer[i, z]] = j - dups + 2
                elif tiebreak == TIEBREAK_MAX:
                    for z in range(j - dups + 1, j + 1):
                        ranks[i, argsort_indexer[i, z]] = j + 1
                elif tiebreak == TIEBREAK_FIRST:
                    if rank_t is object:
                        raise ValueError('first not supported for non-numeric data')
                    else:
                        for z in range(j - dups + 1, j + 1):
                            ranks[i, argsort_indexer[i, z]] = z + 1
                elif tiebreak == TIEBREAK_FIRST_DESCENDING:
                    for z in range(j - dups + 1, j + 1):
                        ranks[i, argsort_indexer[i, z]] = 2 * j - z - dups + 2
                elif tiebreak == TIEBREAK_DENSE:
                    total_tie_count += 1
                    for z in range(j - dups + 1, j + 1):
                        ranks[i, argsort_indexer[i, z]] = total_tie_count
                sum_ranks = dups = 0
        if pct:
            if tiebreak == TIEBREAK_DENSE:
                ranks[i, :] /= total_tie_count
            else:
                ranks[i, :] /= count
    if axis == 0:
        return ranks.T
    else:
        return ranks


ctypedef fused diff_t:
    float64_t
    float32_t
    int8_t
    int16_t
    int32_t
    int64_t

ctypedef fused out_t:
    float32_t
    float64_t
    int64_t


@cython.boundscheck(False)
@cython.wraparound(False)
def diff_2d(
    ndarray[diff_t, ndim=2] arr,  # TODO(cython 3) update to "const diff_t[:, :] arr"
    ndarray[out_t, ndim=2] out,
    Py_ssize_t periods,
    int axis,
    bint datetimelike=False,
):
    cdef:
        Py_ssize_t i, j, sx, sy, start, stop
        bint f_contig = arr.flags.f_contiguous
        # bint f_contig = arr.is_f_contig()  # TODO(cython 3)
        diff_t left, right

    # Disable for unsupported dtype combinations,
    #  see https://github.com/cython/cython/issues/2646
    if (out_t is float32_t
            and not (diff_t is float32_t or diff_t is int8_t or diff_t is int16_t)):
        raise NotImplementedError
    elif (out_t is float64_t
          and (diff_t is float32_t or diff_t is int8_t or diff_t is int16_t)):
        raise NotImplementedError
    elif out_t is int64_t and diff_t is not int64_t:
        # We only have out_t of int64_t if we have datetimelike
        raise NotImplementedError
    else:
        # We put this inside an indented else block to avoid cython build
        #  warnings about unreachable code
        sx, sy = (<object>arr).shape
        with nogil:
            if f_contig:
                if axis == 0:
                    if periods >= 0:
                        start, stop = periods, sx
                    else:
                        start, stop = 0, sx + periods
                    for j in range(sy):
                        for i in range(start, stop):
                            left = arr[i, j]
                            right = arr[i - periods, j]
                            if out_t is int64_t and datetimelike:
                                if left == NPY_NAT or right == NPY_NAT:
                                    out[i, j] = NPY_NAT
                                else:
                                    out[i, j] = left - right
                            else:
                                out[i, j] = left - right
                else:
                    if periods >= 0:
                        start, stop = periods, sy
                    else:
                        start, stop = 0, sy + periods
                    for j in range(start, stop):
                        for i in range(sx):
                            left = arr[i, j]
                            right = arr[i, j - periods]
                            if out_t is int64_t and datetimelike:
                                if left == NPY_NAT or right == NPY_NAT:
                                    out[i, j] = NPY_NAT
                                else:
                                    out[i, j] = left - right
                            else:
                                out[i, j] = left - right
            else:
                if axis == 0:
                    if periods >= 0:
                        start, stop = periods, sx
                    else:
                        start, stop = 0, sx + periods
                    for i in range(start, stop):
                        for j in range(sy):
                            left = arr[i, j]
                            right = arr[i - periods, j]
                            if out_t is int64_t and datetimelike:
                                if left == NPY_NAT or right == NPY_NAT:
                                    out[i, j] = NPY_NAT
                                else:
                                    out[i, j] = left - right
                            else:
                                out[i, j] = left - right
                else:
                    if periods >= 0:
                        start, stop = periods, sy
                    else:
                        start, stop = 0, sy + periods
                    for i in range(sx):
                        for j in range(start, stop):
                            left = arr[i, j]
                            right = arr[i, j - periods]
                            if out_t is int64_t and datetimelike:
                                if left == NPY_NAT or right == NPY_NAT:
                                    out[i, j] = NPY_NAT
                                else:
                                    out[i, j] = left - right
                            else:
                                out[i, j] = left - right


# generated from template
include "algos_common_helper.pxi"
include "algos_take_helper.pxi"
