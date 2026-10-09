void
cttest_reserve_timeout_rejects_trailing_garbage()
{
    int port = SERVER();
    int fd = mustdiallocal(port);

    mustsend(fd, "put 0 0 1 1\r\n");
    mustsend(fd, "A\r\n");
    ckresp(fd, "INSERTED 1\r\n");
    mustsend(fd, "reserve-with-timeout 0garbage\r\n");
    ckresp(fd, "BAD_FORMAT\r\n");
    mustsend(fd, "peek-ready\r\n");
    ckresp(fd, "FOUND 1 1\r\n");
    ckresp(fd, "A\r\n");
}
