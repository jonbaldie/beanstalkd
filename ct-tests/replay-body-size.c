#include <stddef.h>

enum {
    Issue107Walver5 = 5,
    Issue107InitialBodySize = 3,
    Issue107ChangedBodySize = 34,
    Issue107ChangedBodyDataSize = Issue107ChangedBodySize - 2
};

typedef struct Issue107Jobrec5 Issue107Jobrec5;
struct Issue107Jobrec5 {
    uint64 id;
    uint32 pri;
    uint64 delay;
    uint64 ttr;
    int32 body_size;
    uint64 created_at;
    uint64 deadline_at;
    uint32 reserve_ct;
    uint32 timeout_ct;
    uint32 release_ct;
    uint32 bury_ct;
    uint32 kick_ct;
    byte state;
    char pad[1];
};

static void
issue107_write_bytes(FILE *file, const void *bytes, size_t size)
{
    assertf(fwrite(bytes, 1, size, file) == size,
            "could not write WAL fixture bytes");
}

static void
issue107_write_record(FILE *file, int version, int full, int32 body_size)
{
    char body[Issue107ChangedBodyDataSize];
    memset(body, 'x', sizeof(body));

    if (version == Walver) {
        int namelen = full ? (int)(sizeof("default") - 1) : 0;
        Jobrec jr;
        memset(&jr, 0, sizeof(jr));
        jr.id = 1;
        jr.pri = 1;
        jr.body_size = body_size;
        jr.state = Ready;

        issue107_write_bytes(file, &namelen, sizeof(namelen));
        if (namelen)
            issue107_write_bytes(file, "default", (size_t)namelen);
        issue107_write_bytes(file, &jr, sizeof(jr));
    } else {
        size_t namelen = full ? sizeof("default") - 1 : 0;
        Issue107Jobrec5 jr;
        memset(&jr, 0, sizeof(jr));
        jr.id = 1;
        jr.pri = 1;
        jr.body_size = body_size;
        jr.state = Ready;

        issue107_write_bytes(file, &namelen, sizeof(namelen));
        if (namelen)
            issue107_write_bytes(file, "default", namelen);
        issue107_write_bytes(file, &jr, offsetof(Issue107Jobrec5, pad));
    }

    if (full) {
        if (body_size == Issue107InitialBodySize) {
            issue107_write_bytes(file, "A\r\n", Issue107InitialBodySize);
        } else {
            issue107_write_bytes(file, body, sizeof(body));
            issue107_write_bytes(file, "\r\n", 2);
        }
    }
}

static void
issue107_write_fixture(int version, int full_update)
{
    char *path = fmtalloc("%s/binlog.1", ctdir());
    FILE *file = fopen(path, "wb");
    int header = version;

    assertf(file != NULL, "could not create WAL fixture %s", path);
    if (!file) {
        free(path);
        return;
    }

    issue107_write_bytes(file, &header, sizeof(header));
    issue107_write_record(file, version, 1, Issue107InitialBodySize);
    issue107_write_record(file, version, full_update, Issue107ChangedBodySize);
    if (!full_update)
        issue107_write_record(file, version, 1, Issue107ChangedBodySize);
    assertf(fclose(file) == 0, "could not close WAL fixture %s", path);
    free(path);
}

static void
issue107_replay_rejects_body_size_change(int version, int full_update)
{
    srv.wal.dir = ctdir();
    srv.wal.use = 1;
    job_data_size_limit = Issue107ChangedBodyDataSize;
    issue107_write_fixture(version, full_update);

    int port = SERVER();
    int fd = mustdiallocal(port);
    mustsend(fd, "peek 1\r\n");
    ckresp(fd, "NOT_FOUND\r\n");
    kill_srvpid();
}

void
cttest_wal_v7_rejects_full_record_body_size_change()
{
    issue107_replay_rejects_body_size_change(Walver, 1);
}

void
cttest_wal_v7_rejects_short_record_body_size_change()
{
    issue107_replay_rejects_body_size_change(Walver, 0);
}

void
cttest_wal_v5_rejects_full_record_body_size_change()
{
    issue107_replay_rejects_body_size_change(Issue107Walver5, 1);
}

void
cttest_wal_v5_rejects_short_record_body_size_change()
{
    issue107_replay_rejects_body_size_change(Issue107Walver5, 0);
}
