static void
ckpeek(int fd, int id, char *body)
{
    char command[64], found[64], line[128];
    snprintf(command, sizeof(command), "peek %d\r\n", id);
    snprintf(found, sizeof(found), "FOUND %d %zu\r\n", id, strlen(body));
    snprintf(line, sizeof(line), "%s\r\n", body);
    mustsend(fd, command);
    ckresp(fd, found);
    ckresp(fd, line);
}

void
cttest_wal_replay_keeps_jobs_at_max_job_size()
{
    srv.wal.dir = ctdir();
    srv.wal.use = 1;
    job_data_size_limit = 10;

    int port = SERVER();
    int fd = mustdiallocal(port);
    mustsend(fd, "put 1 0 100 1\r\n");
    mustsend(fd, "A\r\n");
    ckresp(fd, "INSERTED 1\r\n");
    mustsend(fd, "put 0 0 100 10\r\n");
    mustsend(fd, "0123456789\r\n");
    ckresp(fd, "INSERTED 2\r\n");
    mustsend(fd, "reserve\r\n");
    ckresp(fd, "RESERVED 2 10\r\n");
    ckresp(fd, "0123456789\r\n");
    mustsend(fd, "bury 2 0\r\n");
    ckresp(fd, "BURIED\r\n");
    mustsend(fd, "put 0 0 100 10\r\n");
    mustsend(fd, "abcdefghij\r\n");
    ckresp(fd, "INSERTED 3\r\n");
    mustsend(fd, "put 0 0 100 9\r\n");
    mustsend(fd, "abcdefghi\r\n");
    ckresp(fd, "INSERTED 4\r\n");
    mustsend(fd, "put 0 1000 100 10\r\n");
    mustsend(fd, "ABCDEFGHIJ\r\n");
    ckresp(fd, "INSERTED 5\r\n");
    mustsend(fd, "put 0 0 100 11\r\n");
    mustsend(fd, "ABCDEFGHIJK\r\n");
    ckresp(fd, "JOB_TOO_BIG\r\n");
    mustsend(fd, "put 0 0 100 1\r\n");
    mustsend(fd, "Z\r\n");
    ckresp(fd, "INSERTED 6\r\n");

    kill_srvpid();
    port = SERVER();
    fd = mustdiallocal(port);
    ckpeek(fd, 1, "A");
    ckpeek(fd, 2, "0123456789");
    ckpeek(fd, 3, "abcdefghij");
    ckpeek(fd, 4, "abcdefghi");
    ckpeek(fd, 5, "ABCDEFGHIJ");
    ckpeek(fd, 6, "Z");
    ckjobstat(fd, 2, "\nstate: buried\n");
    ckjobstat(fd, 5, "\nstate: delayed\n");
    mustsend(fd, "peek 7\r\n");
    ckresp(fd, "NOT_FOUND\r\n");
}

void
cttest_wal_replay_rejects_job_over_max_job_size()
{
    srv.wal.dir = ctdir();
    srv.wal.use = 1;
    job_data_size_limit = 11;

    int port = SERVER();
    int fd = mustdiallocal(port);
    mustsend(fd, "put 0 0 100 1\r\n");
    mustsend(fd, "A\r\n");
    ckresp(fd, "INSERTED 1\r\n");
    mustsend(fd, "put 0 0 100 11\r\n");
    mustsend(fd, "ABCDEFGHIJK\r\n");
    ckresp(fd, "INSERTED 2\r\n");

    // Replay under a smaller limit: job 2 is bigger than any put could have
    // stored, so it must still be rejected.
    kill_srvpid();
    job_data_size_limit = 10;
    port = SERVER();
    fd = mustdiallocal(port);
    ckpeek(fd, 1, "A");
    mustsend(fd, "peek 2\r\n");
    ckresp(fd, "NOT_FOUND\r\n");
}
