void
cttest_pause_tube_requires_space_delimiter()
{
    int port = SERVER();
    int fd = mustdiallocal(port);

    mustsend(fd, "pause-tubedefault 5\r\n");
    ckresp(fd, "UNKNOWN_COMMAND\r\n");
}
