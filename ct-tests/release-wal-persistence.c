void
cttest_release_with_zero_delay_persists_job_stats()
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
    mustsend(fd, "release 1 7 0\r\n");
    ckresp(fd, "RELEASED\r\n");

    kill_srvpid();
    port = SERVER();
    fd = mustdiallocal(port);
    ckjobstat(fd, 1, "\nstate: ready\n");
    ckjobstat(fd, 1, "\npri: 7\n");
    ckjobstat(fd, 1, "\nreserves: 1\n");
    ckjobstat(fd, 1, "\nreleases: 1\n");
}
