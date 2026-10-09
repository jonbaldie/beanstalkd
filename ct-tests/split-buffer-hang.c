void
cttest_split_crlf_at_command_buffer_boundary()
{
    int port = SERVER();
    int fd = mustdiallocal(port);
    char command[226];

    memset(command, 'x', 223);
    command[223] = '\r';
    command[224] = '\n';
    command[225] = '\0';
    mustsend(fd, command);
    ckresp(fd, "BAD_FORMAT\r\n");
}
