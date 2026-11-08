#include "dat.h"
#include <inttypes.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

static int readfull(File *, void *, int, int *, char *);
static void warnpos(File *f, int adj, char *fmt, ...) {}
void warn(const char *fmt, ...) {}
#include "readers.inc"

size_t job_data_size_limit;
static Job recovered;
static Tube tube;
static Jobrec record;
static Jobrec5 record5;
static unsigned read_step;
static unsigned allocations;
static unsigned body_reads;
static _Bool legacy;

ssize_t read(int fd, void *buf, size_t count)
{
    switch (read_step++) {
    case 0:
        if (legacy) {
            __CPROVER_assert(count == sizeof(size_t), "v5 name width");
            *(size_t *)buf = 1;
        } else {
            __CPROVER_assert(count == sizeof(int), "current name width");
            *(int *)buf = 1;
        }
        break;
    case 1:
        __CPROVER_assert(count == 1, "one byte tube name");
        *(char *)buf = 'x';
        break;
    case 2:
        if (legacy) {
            __CPROVER_assert(count == Jobrec5size, "v5 record width");
            memcpy(buf, &record5, Jobrec5size);
        } else {
            __CPROVER_assert(count == sizeof(Jobrec), "current record width");
            memcpy(buf, &record, sizeof(Jobrec));
        }
        break;
    case 3:
        __CPROVER_assert(count == record.body_size, "body read size");
        body_reads++;
        break;
    default:
        __CPROVER_assert(0, "unexpected extra read");
    }
    return count;
}

Job *job_find(uint64 id) { return NULL; }
Tube *tube_find_or_make(const char *name) { return &tube; }
Job *make_job_with_id(uint pri, int64 delay, int64 ttr,
                     int body_size, Tube *t, uint64 id)
{
    allocations++;
    recovered.r.body_size = body_size;
    return &recovered;
}
void job_list_reset(Job *j) {}
void job_list_insert(Job *list, Job *j) {}
Job *job_list_remove(Job *j) { return j; }
void filermjob(File *f, Job *j) {}
void fileaddjob(File *f, Job *j) { j->file = f; }
void job_free(Job *j) {}

unsigned nondet_unsigned(void);
int nondet_int(void);
_Bool nondet_bool(void);

int main(void)
{
    job_data_size_limit = nondet_unsigned();
    __CPROVER_assume(job_data_size_limit <= JOB_DATA_SIZE_LIMIT_MAX);
    int stored_size = nondet_int();
    __CPROVER_assume(stored_size >= 2);
    unsigned state = nondet_unsigned();
    __CPROVER_assume(state == Ready || state == Reserved ||
                     state == Buried || state == Delayed);
    legacy = nondet_bool();
    record.id = record5.id = 1;
    record.body_size = record5.body_size = stored_size;
    record.state = record5.state = state;
    Wal wal = {0};
    File file = {0};
    file.w = &wal;
    Job list = {0};
    int err = 0;
    int result = legacy ? readrec5(&file, &list, &err) : readrec(&file, &list, &err);
    if ((size_t)(stored_size - 2) <= job_data_size_limit) {
        __CPROVER_assert(result == 1 && err == 0 && allocations == 1 && body_reads == 1,
                         "legal stored size replays");
    } else {
        __CPROVER_assert(result == 0 && err == 1 && allocations == 0 && body_reads == 0,
                         "oversize rejected before allocation");
    }
}
