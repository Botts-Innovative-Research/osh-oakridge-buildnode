#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif

static int safe_name(const char *value) {
    return value && *value && !strchr(value, '/') && strcmp(value, ".") && strcmp(value, "..");
}

int main(int argc, char **argv) {
    struct stat source;
    int directory;
    if (argc != 4 || !safe_name(argv[2]) || !safe_name(argv[3])) {
        fputs("usage: oscar-atomic-publish PARENT SOURCE_NAME DESTINATION_NAME\n", stderr);
        return 2;
    }
    directory = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory < 0) {
        fprintf(stderr, "cannot open publication parent: %s\n", strerror(errno));
        return 1;
    }
    if (fstatat(directory, argv[2], &source, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISDIR(source.st_mode)) {
        fputs("publication source is not a directory\n", stderr);
        close(directory);
        return 1;
    }
    if (syscall(SYS_renameat2, directory, argv[2], directory, argv[3], RENAME_NOREPLACE) != 0) {
        fprintf(stderr, "atomic no-replace publication failed: %s\n", strerror(errno));
        close(directory);
        return 1;
    }
    if (fsync(directory) != 0) {
        fprintf(stderr, "publication directory fsync failed: %s\n", strerror(errno));
        close(directory);
        return 1;
    }
    if (close(directory) != 0) {
        fprintf(stderr, "publication directory close failed: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}
