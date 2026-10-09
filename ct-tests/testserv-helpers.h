static void
ckjobstat(int fd, int id, char *stat)
{
    char command[64];
    snprintf(command, sizeof(command), "stats-job %d\r\n", id);
    mustsend(fd, command);
    ckrespsub(fd, "OK ");
    ckrespsub(fd, stat);
}
