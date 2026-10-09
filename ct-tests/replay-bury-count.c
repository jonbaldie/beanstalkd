void
cttest_wal_replay_does_not_increment_bury_count()
{
    srv.wal.dir = ctdir();
    srv.wal.use = 1;

    int port = SERVER();
    int fd = mustdiallocal(port);
    mustsend(fd, "put 0 0 100 1\r\n");
    mustsend(fd, "A\r\n");
    ckresp(fd, "INSERTED 1\r\n");
    mustsend(fd, "reserve\r\n");
    ckresp(fd, "RESERVED 1 1\r\n");
    ckresp(fd, "A\r\n");
    mustsend(fd, "bury 1 0\r\n");
    ckresp(fd, "BURIED\r\n");

    kill_srvpid();
    port = SERVER();
    fd = mustdiallocal(port);
    mustsend(fd, "stats-job 1\r\n");
    ckrespsub(fd, "OK ");
    ckrespsub(fd, "\nburies: 1\n");
}
