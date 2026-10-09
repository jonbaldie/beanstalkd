void
cttest_oversize_put_rejects_trailing_arguments()
{
    job_data_size_limit = 10;
    int port = SERVER();
    int fd = mustdiallocal(port);

    mustsend(fd, "put 0 0 1 11 garbage\r\n");
    ckresp(fd, "BAD_FORMAT\r\n");
}
