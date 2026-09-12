/*
 * test_peer_verify.c — tests for the daemon identity checks in tb_peer_verify.c
 *
 * Build and run with `make test` (from the pam/ directory). No root needed.
 *
 * The socket tests use /usr/bin/nc as a stand-in daemon: it is a root-owned,
 * Apple-signed binary that can listen on a Unix socket, so it exercises the
 * same uid / executable-path / code-identity path the PAM module uses
 * against touchbridged. If a TouchBridge daemon is running for this user,
 * one informational check is run against its real socket as well.
 */

#include "tb_peer_verify.h"

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <signal.h>
#include <spawn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pwd.h>

extern char **environ;

static int failures = 0;

#define CHECK(cond, ...) do { \
    if (cond) { printf("  ok   - " __VA_ARGS__); printf("\n"); } \
    else { printf("  FAIL - " __VA_ARGS__); printf("\n"); failures++; } \
} while (0)

static int connect_unix(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Retry connect() until the listener is up (nc takes a moment). */
static int connect_unix_retry(const char *path, int attempts)
{
    for (int i = 0; i < attempts; i++) {
        int fd = connect_unix(path);
        if (fd >= 0) return fd;
        usleep(50 * 1000);
    }
    return -1;
}

static void test_response_mode(void)
{
    char mode[32];
    printf("tb_response_mode:\n");

    CHECK(tb_response_mode("{\"mode\":\"production\",\"result\":\"success\"}", mode, sizeof(mode)) == 1
          && strcmp(mode, "production") == 0, "parses production");
    CHECK(tb_response_mode("{\"mode\":\"simulator\",\"result\":\"success\"}\n", mode, sizeof(mode)) == 1
          && strcmp(mode, "simulator") == 0, "parses simulator");
    CHECK(tb_response_mode("{\"result\":\"success\"}", mode, sizeof(mode)) == 0,
          "absent mode reports 0");
    CHECK(tb_response_mode("{\"mode\":\"unterminated", mode, sizeof(mode)) == 0,
          "unterminated value reports 0");
    CHECK(tb_response_mode("{\"mode\":\"averyveryveryverylongmodename\"}", mode, 8) == 1
          && strlen(mode) == 7, "long value truncates safely");
}

static void test_trusted_binary(void)
{
    char err[512];
    char resolved[PATH_MAX];
    printf("tb_check_trusted_binary:\n");

    err[0] = '\0';
    CHECK(tb_check_trusted_binary("/usr/bin/nc", resolved, err, sizeof(err)) == TB_PEER_OK,
          "root-owned system binary is trusted (%s)", err);
    CHECK(strcmp(resolved, "/usr/bin/nc") == 0, "resolved path is canonical");

    /* A user-owned file in a user-owned directory must be rejected. */
    char tmpl[] = "/tmp/tbpv-XXXXXX";
    char *dir = mkdtemp(tmpl);
    char userfile[PATH_MAX];
    snprintf(userfile, sizeof(userfile), "%s/fake-daemon", dir);
    FILE *f = fopen(userfile, "w");
    if (f) { fputs("#!/bin/sh\n", f); fclose(f); chmod(userfile, 0755); }

    err[0] = '\0';
    CHECK(tb_check_trusted_binary(userfile, NULL, err, sizeof(err)) == TB_PEER_ERR_BINARY_UNTRUSTED,
          "user-owned binary is rejected: %s", err);

    err[0] = '\0';
    CHECK(tb_check_trusted_binary("/nonexistent/touchbridged", NULL, err, sizeof(err)) == TB_PEER_ERR_BINARY_UNTRUSTED,
          "missing binary is rejected: %s", err);

    err[0] = '\0';
    CHECK(tb_check_trusted_binary("relative/path", NULL, err, sizeof(err)) == TB_PEER_ERR_BINARY_UNTRUSTED,
          "relative path is rejected: %s", err);

    /* A symlink in the user's directory pointing at a trusted binary resolves
     * to the trusted target — the check is on what actually runs. */
    char link[PATH_MAX];
    snprintf(link, sizeof(link), "%s/nc-link", dir);
    symlink("/usr/bin/nc", link);
    err[0] = '\0';
    CHECK(tb_check_trusted_binary(link, resolved, err, sizeof(err)) == TB_PEER_OK
          && strcmp(resolved, "/usr/bin/nc") == 0,
          "symlink resolves to its trusted target (%s)", err);

    unlink(link);
    unlink(userfile);
    rmdir(dir);
}

static void test_peer_against_nc(void)
{
    char err[512];
    printf("tb_verify_peer (peer = /usr/bin/nc):\n");

    char tmpl[] = "/tmp/tbpv-XXXXXX";
    char *dir = mkdtemp(tmpl);
    char sock[PATH_MAX];
    snprintf(sock, sizeof(sock), "%s/s.sock", dir);

    /* Serve the socket with nc: a root-owned, Apple-signed binary. */
    pid_t nc = 0;
    char *argv[] = { "/usr/bin/nc", "-l", "-U", sock, NULL };
    int rc = posix_spawn(&nc, "/usr/bin/nc", NULL, NULL, argv, environ);
    if (rc != 0) {
        printf("  FAIL - could not spawn nc: %s\n", strerror(rc));
        failures++;
        rmdir(dir);
        return;
    }

    int fd = connect_unix_retry(sock, 60);
    CHECK(fd >= 0, "connected to nc's socket");
    if (fd >= 0) {
        err[0] = '\0';
        rc = tb_verify_peer(fd, "/usr/bin/nc", getuid(), err, sizeof(err));
        CHECK(rc == TB_PEER_OK, "genuine peer accepted (uid + path + code identity) %s", err);

        err[0] = '\0';
        rc = tb_verify_peer(fd, "/usr/bin/nc", getuid() + 1, err, sizeof(err));
        CHECK(rc == TB_PEER_ERR_UID_MISMATCH, "wrong uid rejected: %s", err);

        /* Expecting a different trusted binary: the impostor case. If the
         * daemon is installed the failure is a path mismatch; if not, the
         * expected binary itself is untrusted. Either way: refused. */
        err[0] = '\0';
        rc = tb_verify_peer(fd, "/usr/bin/true", getuid(), err, sizeof(err));
        CHECK(rc == TB_PEER_ERR_PATH_MISMATCH, "peer that is not the expected binary rejected: %s", err);

        err[0] = '\0';
        rc = tb_verify_peer(fd, TB_DEFAULT_DAEMON_PATH, getuid(), err, sizeof(err));
        CHECK(rc == TB_PEER_ERR_PATH_MISMATCH || rc == TB_PEER_ERR_BINARY_UNTRUSTED,
              "impostor serving the daemon socket rejected: %s", err);

        close(fd);
    }

    kill(nc, SIGTERM);
    waitpid(nc, NULL, 0);
    unlink(sock);
    rmdir(dir);
}

/* Informational: if the real daemon is running, its peer check must pass. */
static void test_live_daemon(void)
{
    char err[512];
    struct passwd *pw = getpwuid(getuid());
    if (pw == NULL) return;

    char sock[PATH_MAX];
    snprintf(sock, sizeof(sock),
             "%s/Library/Application Support/TouchBridge/daemon.sock", pw->pw_dir);

    printf("live daemon (%s):\n", sock);
    int fd = connect_unix(sock);
    if (fd < 0) {
        printf("  skip - no daemon listening (%s)\n", strerror(errno));
        return;
    }
    err[0] = '\0';
    int rc = tb_verify_peer(fd, TB_DEFAULT_DAEMON_PATH, getuid(), err, sizeof(err));
    close(fd);
    if (rc == TB_PEER_OK) {
        printf("  ok   - running daemon matches %s\n", TB_DEFAULT_DAEMON_PATH);
    } else {
        printf("  WARN - running daemon would be REFUSED by the PAM module: %s\n", err);
        printf("         (expected if the daemon binary was rebuilt but not restarted,\n");
        printf("          or if %s is not root-owned)\n", TB_DEFAULT_DAEMON_PATH);
    }
}

int main(void)
{
    test_response_mode();
    test_trusted_binary();
    test_peer_against_nc();
    test_live_daemon();

    if (failures) {
        printf("\n%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("\nall peer verification tests passed\n");
    return 0;
}
