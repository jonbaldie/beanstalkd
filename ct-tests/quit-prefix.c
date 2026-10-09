void
cttest_quit_rejects_trailing_garbage()
{
    int port = SERVER();
    int fd = mustdiallocal(port);

    mustsend(fd, "quitgarbage\r\n");
    ckresp(fd, "BAD_FORMAT\r\n");
}
