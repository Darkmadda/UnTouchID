/*
 * tb_peer_verify.h — daemon identity verification for pam_touchbridge
 *
 * The daemon socket lives in the user's home directory, so any process
 * running as that user can unlink it and bind an impostor that answers
 * every request with "success". Because sudo grants root on a PAM success,
 * that would turn user-level code execution into root.
 *
 * These helpers close that hole without a shared secret (which the daemon,
 * running as the user, could not keep from a same-user attacker anyway).
 * After connect(), the PAM module asks the kernel who is on the other end
 * of the socket and requires that:
 *
 *   1. the peer's uid is the user being authenticated;
 *   2. the peer's executable is the installed daemon binary, which along
 *      with its parent directory must be root-owned and not writable by
 *      group or other (so it cannot be replaced without root);
 *   3. the peer's running code satisfies the code-signing designated
 *      requirement of that on-disk binary (for an ad-hoc signed build this
 *      pins the exact cdhash; for a Developer ID build, the identity).
 *
 * Together these mean the only process the module will talk to is an
 * unmodified copy of the daemon that root installed.
 */

#ifndef TB_PEER_VERIFY_H
#define TB_PEER_VERIFY_H

#include <sys/types.h>
#include <stddef.h>

/* Where install.sh puts the daemon. Override per PAM line with daemon=/path. */
#define TB_DEFAULT_DAEMON_PATH "/usr/local/bin/touchbridged"

/* Result codes for tb_verify_peer / tb_check_trusted_binary. */
enum tb_peer_result {
    TB_PEER_OK = 0,
    TB_PEER_ERR_BINARY_UNTRUSTED,  /* expected binary missing, not root-owned, or writable */
    TB_PEER_ERR_PEERCRED,          /* kernel would not tell us who the peer is */
    TB_PEER_ERR_UID_MISMATCH,      /* peer runs as a different user */
    TB_PEER_ERR_PATH_MISMATCH,     /* peer executable is not the daemon binary */
    TB_PEER_ERR_CODE_IDENTITY,     /* peer code does not match the on-disk binary */
};

/*
 * Check that `path` names a regular file that root owns and that neither it
 * nor its parent directory is writable by group or other. Symlinks are
 * resolved first and the checks apply to the resolved file.
 *
 * On success writes the resolved path into `resolved` (if non-NULL, size
 * PATH_MAX). On failure writes a human-readable reason into errbuf.
 */
int tb_check_trusted_binary(const char *path, char *resolved,
                            char *errbuf, size_t errlen);

/*
 * Verify the peer of the connected AF_UNIX socket `fd` as described above.
 * `expected_path` is the daemon binary; `expected_uid` is the uid of the
 * user being authenticated. Returns TB_PEER_OK or an error code, with a
 * reason in errbuf. Never logs or copies anything secret.
 */
int tb_verify_peer(int fd, const char *expected_path, uid_t expected_uid,
                   char *errbuf, size_t errlen);

/*
 * Extract the value of the top-level "mode" field from a daemon JSON
 * response. Returns 1 and copies the (NUL-terminated, truncated to modelen-1)
 * value into `mode` when present; returns 0 when the field is absent.
 */
int tb_response_mode(const char *response, char *mode, size_t modelen);

#endif /* TB_PEER_VERIFY_H */
