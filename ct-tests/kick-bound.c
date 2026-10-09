void
cttest_kick_rejects_trailing_garbage()
{
    int port = SERVER();
    int fd = mustdiallocal(port);

    mustsend(fd, "put 0 0 1 1\r\n");
    mustsend(fd, "A\r\n");
    ckresp(fd, "INSERTED 1\r\n");
    mustsend(fd, "reserve\r\n");
    ckresp(fd, "RESERVED 1 1\r\n");
    ckresp(fd, "A\r\n");
    mustsend(fd, "bury 1 0\r\n");
    ckresp(fd, "BURIED\r\n");

    mustsend(fd, "kick 1garbage\r\n");
    ckresp(fd, "BAD_FORMAT\r\n");
    mustsend(fd, "peek-buried\r\n");
    ckresp(fd, "FOUND 1 1\r\n");
    ckresp(fd, "A\r\n");
}
