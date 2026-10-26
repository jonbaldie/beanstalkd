/* Appended once before the manifest's fragments, in upstream testserv.c scope. */
static void
ckpeek(int fd, int id, char *body)
{
    char command[64], found[64], line[128];
    snprintf(command, sizeof(command), "peek %d\r\n", id);
    snprintf(found, sizeof(found), "FOUND %d %zu\r\n", id, strlen(body));
    snprintf(line, sizeof(line), "%s\r\n", body);
    mustsend(fd, command);
    ckresp(fd, found);
    ckresp(fd, line);
}

static void
ckjobstat(int fd, int id, char *stat)
{
    char command[64];
    snprintf(command, sizeof(command), "stats-job %d\r\n", id);
    mustsend(fd, command);
    ckrespsub(fd, "OK ");
    ckrespsub(fd, stat);
}
