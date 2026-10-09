void
cttest_ttr_expiry_returns_job_to_ready_queue()
{
    enum { JobCount = 32 };
    int workers[JobCount];
    char command[64], response[64];

    job_data_size_limit = 1;
    int port = SERVER();
    int producer = mustdiallocal(port);
    int i;

    for (i = 1; i <= JobCount; i++) {
        mustsend(producer, "put 0 0 1 1\r\n");
        mustsend(producer, "A\r\n");
        snprintf(response, sizeof(response), "INSERTED %d\r\n", i);
        ckresp(producer, response);
    }

    for (i = 0; i < JobCount; i++) {
        workers[i] = mustdiallocal(port);
        snprintf(command, sizeof(command), "reserve-job %d\r\n", i + 1);
        mustsend(workers[i], command);
        snprintf(response, sizeof(response), "RESERVED %d 1\r\n", i + 1);
        ckresp(workers[i], response);
        ckresp(workers[i], "A\r\n");
    }

    usleep(1200000);
    for (i = 1; i <= JobCount; i++) {
        snprintf(command, sizeof(command), "stats-job %d\r\n", i);
        mustsend(producer, command);
        ckrespsub(producer, "OK ");
        ckrespsub(producer, "\nstate: ready\n");
    }
}
