/*
 * Headless query benchmark for FSearch 0.3-dev (commit 1208a34).
 *
 * This driver links against FSearch's own core library (no GTK, no GUI) and
 * measures the exact per-query path used by the application:
 *
 *   fsearch_database_index_store_start()   -> scan + build in-memory index
 *   fsearch_database_index_store_search()  -> one full query over that index
 *
 * The search call splits the joined entry arrays across the store worker pool
 * and evaluates the parsed query tree per entry (fsearch_query_match), which is
 * the execution model described in the application document.  Query latency is
 * reported separately from index build time so it can be compared with
 * moonsearch's engine-only numbers on the same directory tree.
 *
 * Usage:
 *   bench_fsearch --root DIR [--root DIR ...] [--runs N] [--warmup N] QUERY...
 *
 * Output is TSV on stdout:
 *   META   fsearch  folders  files  build_ms  roots
 *   QUERY  fsearch  query    runs    median_ms  min_ms  max_ms  matches
 */

#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fsearch_database_exclude_manager.h"
#include "fsearch_database_include.h"
#include "fsearch_database_include_manager.h"
#include "fsearch_database_index_properties.h"
#include "fsearch_database_index_store.h"
#include "fsearch_database_search_info.h"
#include "fsearch_filter_manager.h"
#include "fsearch_query.h"

/* The build renames g_get_num_processors() to this function so the benchmark
 * can pin FSearch's worker pool to one thread for a same-core comparison with
 * moonsearch (which is single-threaded).  --threads 0 uses the host default. */
static int bench_threads = 0;

guint
g_bench_num_processors(void) {
    if (bench_threads > 0) {
        return (guint)bench_threads;
    }
    const long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    return cpus > 0 ? (guint)cpus : 1;
}

typedef struct {
    double *items;
    size_t len;
    size_t cap;
} Samples;

static void
samples_add(Samples *samples, double value) {
    if (samples->len == samples->cap) {
        samples->cap = samples->cap ? samples->cap * 2 : 16;
        samples->items = g_realloc(samples->items, samples->cap * sizeof(double));
    }
    samples->items[samples->len++] = value;
}

static int
compare_double(const void *a, const void *b) {
    const double da = *(const double *)a;
    const double db = *(const double *)b;
    return (da > db) - (da < db);
}

static double
samples_median(Samples *samples) {
    if (samples->len == 0) {
        return 0.0;
    }
    qsort(samples->items, samples->len, sizeof(double), compare_double);
    if (samples->len % 2 == 1) {
        return samples->items[samples->len / 2];
    }
    return (samples->items[samples->len / 2 - 1] + samples->items[samples->len / 2]) / 2.0;
}

static void
usage(const char *argv0) {
    fprintf(stderr,
            "Usage: %s --root DIR [--root DIR ...] [--runs N] [--warmup N] [--threads N] QUERY...\n",
            argv0);
}

int
main(int argc, char **argv) {
    GPtrArray *roots = g_ptr_array_new_with_free_func(g_free);
    GPtrArray *queries = g_ptr_array_new_with_free_func(g_free);
    int runs = 5;
    int warmup = 1;

    for (int i = 1; i < argc; ++i) {
        if (g_strcmp0(argv[i], "--root") == 0) {
            if (i + 1 >= argc) {
                usage(argv[0]);
                return 2;
            }
            g_ptr_array_add(roots, g_strdup(argv[++i]));
        }
        else if (g_strcmp0(argv[i], "--runs") == 0) {
            if (i + 1 >= argc) {
                usage(argv[0]);
                return 2;
            }
            runs = atoi(argv[++i]);
        }
        else if (g_strcmp0(argv[i], "--warmup") == 0) {
            if (i + 1 >= argc) {
                usage(argv[0]);
                return 2;
            }
            warmup = atoi(argv[++i]);
        }
        else if (g_strcmp0(argv[i], "--threads") == 0) {
            if (i + 1 >= argc) {
                usage(argv[0]);
                return 2;
            }
            bench_threads = atoi(argv[++i]);
        }
        else if (g_strcmp0(argv[i], "--help") == 0 || g_strcmp0(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        }
        else if (argv[i][0] == '-') {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 2;
        }
        else {
            g_ptr_array_add(queries, g_strdup(argv[i]));
        }
    }

    if (roots->len == 0) {
        usage(argv[0]);
        return 2;
    }
    if (runs < 1) {
        runs = 1;
    }
    if (warmup < 0) {
        warmup = 0;
    }

    FsearchDatabaseIncludeManager *include_manager = fsearch_database_include_manager_new();
    for (guint i = 0; i < roots->len; ++i) {
        const char *path = g_ptr_array_index(roots, i);
        FsearchDatabaseInclude *include =
            fsearch_database_include_new(path, TRUE, FALSE, FALSE, FALSE, 0);
        if (!include) {
            fprintf(stderr, "failed to create include for %s\n", path);
            return 2;
        }
        fsearch_database_include_manager_add(include_manager, include);
        fsearch_database_include_unref(include);
    }

    FsearchDatabaseExcludeManager *exclude_manager = fsearch_database_exclude_manager_new();
    FsearchDatabaseIndexStore *store = fsearch_database_index_store_new(
        include_manager,
        exclude_manager,
        DATABASE_INDEX_PROPERTY_FLAG_DEFAULT,
        NULL,
        NULL);
    GCancellable *cancellable = g_cancellable_new();

    const gint64 build_start = g_get_monotonic_time();
    fsearch_database_index_store_start(store, cancellable);
    const gint64 build_end = g_get_monotonic_time();
    const double build_ms = (build_end - build_start) / 1000.0;

    const uint32_t num_folders = fsearch_database_index_store_get_num_folders(store);
    const uint32_t num_files = fsearch_database_index_store_get_num_files(store);
    printf("META\tfsearch\t%u\t%u\t%.3f\t%u\t%u\n",
           num_folders,
           num_files,
           build_ms,
           roots->len,
           (guint)g_bench_num_processors());

    FsearchFilterManager *filters = fsearch_filter_manager_new_with_defaults();

    for (guint i = 0; i < queries->len; ++i) {
        const char *query_text = g_ptr_array_index(queries, i);
        FsearchQuery *query = fsearch_query_new(query_text, NULL, filters, 0, "benchmark");
        if (!query) {
            fprintf(stderr, "failed to parse query: %s\n", query_text);
            continue;
        }

        uint32_t matches = 0;
        for (int w = 0; w < warmup; ++w) {
            fsearch_database_index_store_search(store,
                                                1,
                                                query,
                                                DATABASE_INDEX_PROPERTY_NAME,
                                                FSEARCH_SORT_DIRECTION_ASCENDING,
                                                cancellable);
        }

        Samples samples = {};
        for (int r = 0; r < runs; ++r) {
            const gint64 start = g_get_monotonic_time();
            fsearch_database_index_store_search(store,
                                                1,
                                                query,
                                                DATABASE_INDEX_PROPERTY_NAME,
                                                FSEARCH_SORT_DIRECTION_ASCENDING,
                                                cancellable);
            const gint64 end = g_get_monotonic_time();
            samples_add(&samples, (end - start) / 1000.0);

            FsearchDatabaseSearchInfo *info =
                fsearch_database_index_store_get_search_info(store, 1);
            if (info) {
                matches = fsearch_database_search_info_get_num_entries(info);
            }
        }

        double min_ms = samples.items[0];
        double max_ms = samples.items[0];
        for (size_t s = 1; s < samples.len; ++s) {
            if (samples.items[s] < min_ms) {
                min_ms = samples.items[s];
            }
            if (samples.items[s] > max_ms) {
                max_ms = samples.items[s];
            }
        }
        const double median_ms = samples_median(&samples);
        printf("QUERY\tfsearch\t%s\t%d\t%.3f\t%.3f\t%.3f\t%u\n",
               query_text,
               runs,
               median_ms,
               min_ms,
               max_ms,
               matches);

        g_free(samples.items);
        fsearch_query_unref(query);
    }

    fsearch_filter_manager_unref(filters);
    fsearch_database_index_store_unref(store);
    g_object_unref(exclude_manager);
    g_object_unref(include_manager);
    g_object_unref(cancellable);
    g_ptr_array_unref(queries);
    g_ptr_array_unref(roots);
    return 0;
}
