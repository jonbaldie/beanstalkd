void
cttest_ttr_expiry_persists_timeout_count()
{
    srv.wal.dir = ctdir();
    srv.wal.use = 1;

    int port = SERVER();
    int producer = mustdiallocal(port);
    int worker = mustdiallocal(port);
    mustsend(producer, "put 0 0 1 1\r\n");
    mustsend(producer, "A\r\n");
    ckresp(producer, "INSERTED 1\r\n");
    mustsend(worker, "reserve\r\n");
    ckresp(worker, "RESERVED 1 1\r\n");
    ckresp(worker, "A\r\n");

    usleep(1200000);
    mustsend(producer, "peek-ready\r\n");
    ckresp(producer, "FOUND 1 1\r\n");
    ckresp(producer, "A\r\n");
    ckjobstat(producer, 1, "\nstate: ready\n");
    ckjobstat(producer, 1, "\ntimeouts: 1\n");

    kill_srvpid();
    port = SERVER();
    producer = mustdiallocal(port);
    ckjobstat(producer, 1, "\nstate: ready\n");
    ckjobstat(producer, 1, "\ntimeouts: 1\n");
}
