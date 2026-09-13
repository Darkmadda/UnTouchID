/*
 * pam_touchbridge.c — TouchBridge PAM module
 *
 * Connects to the TouchBridge daemon via a Unix domain socket and
 * requests biometric authentication on the user's paired iOS device.
 *
 * PAM config line:
 *   auth  sufficient  pam_touchbridge.so [timeout=15] [daemon=/path]
 *                                        [allow_mode=simulator] ...
 *
 * Options:
 *   timeout=N        Seconds to wait for the phone (1-300, default 15).
 *   daemon=PATH      Installed daemon binary the module will trust
 *                    (default /usr/local/bin/touchbridged).
 *   allow_mode=MODE  Accept a daemon running in a non-production mode
 *                    ("simulator" or "web"). Repeatable. Off by default,
 *                    because those modes approve requests without a paired
 *                    phone: any same-user process could start one and use
 *                    it to obtain root through sudo.
 *
 * If "sufficient", a successful TouchBridge auth skips the password prompt.
 * If TouchBridge fails (timeout, no device, etc.), PAM falls through to
 * the next module (typically password).
 *
 * When the calling application has already collected a password (GUI
 * dialogs such as the lock screen and Authorization Services prompts set
 * PAM_AUTHTOK before running the stack), the module steps aside with
 * PAM_IGNORE so the password modules run immediately. Leave the password
 * field empty and submit to authenticate with the phone instead.
 *
 * Logging goes through openpam_log(3), which libpam forwards to the unified
 * log with the text intact. (Plain syslog(3) from inside sudo, loginwindow or
 * authorizationhost is stored redacted as <private> and is useless for
 * diagnosis.) Read it with:
 *   log show --last 10m --info --predicate 'eventMessage CONTAINS "pam_touchbridge"'
 *
 * Security notes:
 * - Never logs nonces, keys, or passwords (only whether a password was
 *   supplied at all)
 * - Socket path derived from target user's home directory (not env vars)
 * - The peer on the socket must be the root-installed daemon binary,
 *   running as the target user, with code matching the file on disk
 *   (see tb_peer_verify.h) — an impostor socket cannot mint approvals
 * - Fixed-size buffers prevent overflow
 * - All socket fds closed on all code paths
 */

#include "pam_touchbridge.h"
#include "tb_peer_verify.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pwd.h>
#include <errno.h>
#include <security/openpam.h>

/*
 * Send an info message to the user's terminal via PAM conversation.
 * This is how PAM modules display "Check your phone..." type messages.
 */
static void pam_notify(pam_handle_t *pamh, const char *msg)
{
    const struct pam_conv *conv = NULL;
    struct pam_message pmsg;
    const struct pam_message *pmsgp = &pmsg;
    struct pam_response *resp = NULL;

    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) != PAM_SUCCESS
        || conv == NULL || conv->conv == NULL) {
        return;
    }

    pmsg.msg_style = PAM_TEXT_INFO;
    pmsg.msg = (char *)msg;

    conv->conv(1, &pmsgp, &resp, conv->appdata_ptr);

    if (resp != NULL) {
        free(resp);
    }
}

/* Maximum sizes */
#define MAX_SOCK_PATH   256
#define MAX_REQUEST     512
#define MAX_RESPONSE    512
#define MAX_ERR         512
#define MAX_MODE        32
#define MAX_ALLOW_MODES 4
#define DEFAULT_TIMEOUT 15

/* Parsed module options. */
struct tb_options {
    int timeout;
    const char *daemon_path;
    const char *allow_modes[MAX_ALLOW_MODES];
    int n_allow_modes;
};

/*
 * Parse module arguments. Unknown arguments are logged and ignored so a
 * typo in pam.d degrades to defaults rather than breaking authentication.
 */
static void parse_options(int argc, const char **argv, struct tb_options *opts)
{
    opts->timeout = DEFAULT_TIMEOUT;
    opts->daemon_path = TB_DEFAULT_DAEMON_PATH;
    opts->n_allow_modes = 0;

    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            int t = atoi(argv[i] + 8);
            if (t > 0 && t <= 300) {
                opts->timeout = t;
            }
        } else if (strncmp(argv[i], "daemon=", 7) == 0) {
            if (argv[i][7] == '/') {
                opts->daemon_path = argv[i] + 7;
            } else {
                openpam_log(PAM_LOG_ERROR,
                    "pam_touchbridge: ignoring non-absolute daemon= option");
            }
        } else if (strncmp(argv[i], "allow_mode=", 11) == 0) {
            if (opts->n_allow_modes < MAX_ALLOW_MODES && argv[i][11] != '\0') {
                opts->allow_modes[opts->n_allow_modes++] = argv[i] + 11;
            }
        } else {
            openpam_log(PAM_LOG_ERROR,
                "pam_touchbridge: ignoring unknown option '%s'", argv[i]);
        }
    }
}

static int mode_allowed(const struct tb_options *opts, const char *mode)
{
    if (strcmp(mode, "production") == 0) {
        return 1;
    }
    for (int i = 0; i < opts->n_allow_modes; i++) {
        if (strcmp(opts->allow_modes[i], mode) == 0) {
            return 1;
        }
    }
    return 0;
}

/*
 * Build the socket path for the target user.
 * Path: <homedir>/Library/Application Support/TouchBridge/daemon.sock
 * Also returns the user's uid, which the daemon must be running as.
 */
static int build_socket_path(const char *username, char *path, size_t pathlen,
                             uid_t *uid_out)
{
    struct passwd *pw = getpwnam(username);
    if (pw == NULL) {
        openpam_log(PAM_LOG_ERROR, "pam_touchbridge: getpwnam failed for user %s", username);
        return -1;
    }

    int ret = snprintf(path, pathlen,
        "%s/Library/Application Support/TouchBridge/daemon.sock",
        pw->pw_dir);

    if (ret < 0 || (size_t)ret >= pathlen) {
        openpam_log(PAM_LOG_ERROR, "pam_touchbridge: socket path too long");
        return -1;
    }

    *uid_out = pw->pw_uid;
    return 0;
}

/*
 * Connect to the daemon's Unix domain socket.
 * Returns the socket fd on success, -1 on failure.
 */
static int connect_to_daemon(const char *sock_path, int timeout_sec)
{
    int fd = -1;
    struct sockaddr_un addr;
    struct timeval tv;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        openpam_log(PAM_LOG_ERROR, "pam_touchbridge: socket() failed: %s", strerror(errno));
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    if (strlen(sock_path) >= sizeof(addr.sun_path)) {
        openpam_log(PAM_LOG_ERROR, "pam_touchbridge: socket path too long");
        close(fd);
        return -1;
    }
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        openpam_log(PAM_LOG_ERROR,
            "pam_touchbridge: connect failed: %s (daemon may not be running)",
            strerror(errno));
        close(fd);
        return -1;
    }

    /* Set receive timeout with a 2s grace margin over the daemon's auth
     * window (both default to 15s). Without the margin they race: PAM can
     * give up at the exact moment the daemon sends its result, losing an
     * approval that already happened. */
    tv.tv_sec = timeout_sec + 2;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    return fd;
}

/*
 * Whether the application already collected a password from the user.
 * Only the presence of a non-empty token is examined; its value is never
 * copied, compared, or logged.
 */
enum authtok_state { AUTHTOK_UNSET, AUTHTOK_EMPTY, AUTHTOK_SUPPLIED };

static enum authtok_state authtok_state(pam_handle_t *pamh)
{
    const char *authtok = NULL;

    if (pam_get_item(pamh, PAM_AUTHTOK, (const void **)&authtok) != PAM_SUCCESS
        || authtok == NULL) {
        return AUTHTOK_UNSET;
    }
    return authtok[0] == '\0' ? AUTHTOK_EMPTY : AUTHTOK_SUPPLIED;
}

static const char *authtok_state_name(enum authtok_state st)
{
    switch (st) {
    case AUTHTOK_UNSET:    return "unset";
    case AUTHTOK_EMPTY:    return "empty";
    case AUTHTOK_SUPPLIED: return "supplied";
    }
    return "?";
}

/*
 * pam_sm_authenticate — main authentication entry point.
 *
 * Connects to the TouchBridge daemon socket, verifies the daemon's identity,
 * sends an auth request, and waits for the daemon to verify the user via
 * their companion device.
 */
PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    const char *user = NULL;
    const char *service = NULL;
    char sock_path[MAX_SOCK_PATH];
    char request[MAX_REQUEST];
    char response[MAX_RESPONSE];
    char errbuf[MAX_ERR];
    char mode[MAX_MODE];
    struct tb_options opts;
    uid_t target_uid = 0;
    int fd = -1;
    int ret = PAM_AUTH_ERR;
    ssize_t bytes;

    (void)flags; /* unused */

    /* Get the target username */
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        openpam_log(PAM_LOG_ERROR, "pam_touchbridge: failed to get username");
        return PAM_AUTH_ERR;
    }

    /* Get the PAM service name */
    if (pam_get_item(pamh, PAM_SERVICE, (const void **)&service) != PAM_SUCCESS
        || service == NULL) {
        service = "unknown";
    }

    parse_options(argc, argv, &opts);

    /* One line per invocation saying who called us and in what state, so a
     * surface that never reaches the daemon can be diagnosed from the log. */
    enum authtok_state tok = authtok_state(pamh);
    openpam_log(PAM_LOG_NOTICE,
        "pam_touchbridge: entry user=%s service=%s host_uid=%u host_euid=%u "
        "authtok=%s timeout=%d daemon=%s",
        user, service, (unsigned)getuid(), (unsigned)geteuid(),
        authtok_state_name(tok), opts.timeout, opts.daemon_path);

    /* GUI dialogs hand us the typed password up front. If there is one, the
     * user chose the password path — let it run without a phone round trip. */
    if (tok == AUTHTOK_SUPPLIED) {
        openpam_log(PAM_LOG_NOTICE,
            "pam_touchbridge: password supplied by application for user=%s "
            "service=%s — deferring to password modules", user, service);
        return PAM_IGNORE;
    }

    /* Build socket path from the target user's home directory */
    if (build_socket_path(user, sock_path, sizeof(sock_path), &target_uid) != 0) {
        goto cleanup;
    }

    /* Connect to daemon */
    fd = connect_to_daemon(sock_path, opts.timeout);
    if (fd < 0) {
        pam_notify(pamh, "TouchBridge: daemon not running — falling through to password");
        goto cleanup;
    }

    /* Refuse to talk to anything that is not the installed daemon. Do this
     * before sending the request so an impostor never even sees it. */
    errbuf[0] = '\0';
    if (tb_verify_peer(fd, opts.daemon_path, target_uid, errbuf, sizeof(errbuf))
        != TB_PEER_OK) {
        openpam_log(PAM_LOG_ERROR,
            "pam_touchbridge: REFUSING socket peer for user=%s service=%s: %s "
            "(possible daemon.sock spoofing)", user, service, errbuf);
        pam_notify(pamh,
            "TouchBridge: daemon identity check failed — falling through to password");
        goto cleanup;
    }

    pam_notify(pamh, "TouchBridge: check your phone or watch...");

    /* Build JSON request — simple snprintf, no JSON library needed */
    bytes = snprintf(request, sizeof(request),
        "{\"action\":\"authenticate\",\"user\":\"%s\",\"service\":\"%s\",\"pid\":%d}\n",
        user, service, getpid());

    if (bytes < 0 || (size_t)bytes >= sizeof(request)) {
        openpam_log(PAM_LOG_ERROR, "pam_touchbridge: request too large");
        goto cleanup;
    }

    /* Send request */
    if (send(fd, request, (size_t)bytes, 0) != bytes) {
        openpam_log(PAM_LOG_ERROR, "pam_touchbridge: send failed: %s", strerror(errno));
        goto cleanup;
    }

    /* Receive response */
    memset(response, 0, sizeof(response));
    bytes = recv(fd, response, sizeof(response) - 1, 0);

    if (bytes <= 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            openpam_log(PAM_LOG_ERROR,
                "pam_touchbridge: timeout waiting for companion device");
            pam_notify(pamh, "TouchBridge: timed out — no response from phone");
        } else {
            openpam_log(PAM_LOG_ERROR,
                "pam_touchbridge: recv failed: %s", strerror(errno));
            pam_notify(pamh, "TouchBridge: connection error");
        }
        goto cleanup;
    }

    response[bytes] = '\0';

    /* The daemon reports which mode it is running in. Simulator and web
     * modes approve without a paired phone, so they are only honoured when
     * root opted in with allow_mode=. A response with no mode comes from a
     * daemon older than this module — fail closed and ask for a reinstall. */
    if (!tb_response_mode(response, mode, sizeof(mode))) {
        openpam_log(PAM_LOG_ERROR,
            "pam_touchbridge: daemon response has no mode field — daemon is "
            "older than the PAM module; reinstall TouchBridge");
        pam_notify(pamh, "TouchBridge: daemon out of date — falling through to password");
        goto cleanup;
    }
    if (!mode_allowed(&opts, mode)) {
        openpam_log(PAM_LOG_ERROR,
            "pam_touchbridge: daemon is running in '%s' mode, which approves "
            "without a paired phone; ignoring its answer. Add allow_mode=%s "
            "to the PAM line to permit this on a development machine.",
            mode, mode);
        pam_notify(pamh,
            "TouchBridge: daemon mode not permitted by PAM config — falling through to password");
        goto cleanup;
    }

    /* Check for success — simple string search, no JSON parser needed */
    if (strstr(response, "\"result\":\"success\"") != NULL) {
        openpam_log(PAM_LOG_NOTICE,
            "pam_touchbridge: authentication succeeded for user=%s service=%s mode=%s",
            user, service, mode);
        pam_notify(pamh, "TouchBridge: ✓ authenticated");
        ret = PAM_SUCCESS;
    } else {
        openpam_log(PAM_LOG_NOTICE,
            "pam_touchbridge: authentication failed for user=%s service=%s reason=%s",
            user, service, response);

        /*
         * Show a reason-specific message so the user knows what happened
         * and what to do, rather than a generic "denied" for all failures.
         */
        if (strstr(response, "\"key_invalidated\"") != NULL) {
            pam_notify(pamh,
                "TouchBridge: ✗ signing key invalid — open TouchBridge on your "
                "phone and re-pair (Settings → Unpair → Pair)");
        } else if (strstr(response, "\"invalid_signature\"") != NULL) {
            pam_notify(pamh,
                "TouchBridge: ✗ signature verification failed — try again or re-pair");
        } else if (strstr(response, "\"challenge_expired\"") != NULL) {
            pam_notify(pamh,
                "TouchBridge: ✗ request timed out on phone — try again");
        } else {
            pam_notify(pamh, "TouchBridge: ✗ denied — falling through to password");
        }
        ret = PAM_AUTH_ERR;
    }

cleanup:
    if (fd >= 0) {
        close(fd);
    }
    return ret;
}

/*
 * pam_sm_setcred — credential management (no-op for TouchBridge).
 */
PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}

/*
 * pam_sm_acct_mgmt — account management (no-op for TouchBridge).
 */
PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
