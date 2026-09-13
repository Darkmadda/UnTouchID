/*
 * tb_peer_verify.c — daemon identity verification for pam_touchbridge
 *
 * See tb_peer_verify.h for the threat model and the checks performed.
 */

#include "tb_peer_verify.h"

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/ucred.h>
#include <libproc.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

static void set_err(char *errbuf, size_t errlen, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

static void set_err(char *errbuf, size_t errlen, const char *fmt, ...)
{
    if (errbuf == NULL || errlen == 0) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(errbuf, errlen, fmt, ap);
    va_end(ap);
}

/* A path component root owns and nobody else can write to. */
static int is_root_owned_unwritable(const struct stat *st)
{
    return st->st_uid == 0 && (st->st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

int tb_check_trusted_binary(const char *path, char *resolved,
                            char *errbuf, size_t errlen)
{
    char canon[PATH_MAX];
    char parent[PATH_MAX];
    struct stat st;

    if (path == NULL || path[0] != '/') {
        set_err(errbuf, errlen, "daemon path must be absolute");
        return TB_PEER_ERR_BINARY_UNTRUSTED;
    }

    if (realpath(path, canon) == NULL) {
        set_err(errbuf, errlen, "cannot resolve %s: %s", path, strerror(errno));
        return TB_PEER_ERR_BINARY_UNTRUSTED;
    }

    if (stat(canon, &st) != 0) {
        set_err(errbuf, errlen, "cannot stat %s: %s", canon, strerror(errno));
        return TB_PEER_ERR_BINARY_UNTRUSTED;
    }
    if (!S_ISREG(st.st_mode)) {
        set_err(errbuf, errlen, "%s is not a regular file", canon);
        return TB_PEER_ERR_BINARY_UNTRUSTED;
    }
    if (!is_root_owned_unwritable(&st)) {
        set_err(errbuf, errlen,
                "%s must be owned by root and not group/world writable "
                "(uid=%u mode=%04o)", canon, (unsigned)st.st_uid,
                (unsigned)(st.st_mode & 07777));
        return TB_PEER_ERR_BINARY_UNTRUSTED;
    }

    /* Parent directory: otherwise the file could simply be renamed away
     * and replaced. */
    strlcpy(parent, canon, sizeof(parent));
    char *slash = strrchr(parent, '/');
    if (slash == parent) {
        parent[1] = '\0';
    } else if (slash != NULL) {
        *slash = '\0';
    }
    if (stat(parent, &st) != 0 || !S_ISDIR(st.st_mode)) {
        set_err(errbuf, errlen, "cannot stat directory %s", parent);
        return TB_PEER_ERR_BINARY_UNTRUSTED;
    }
    if (!is_root_owned_unwritable(&st)) {
        set_err(errbuf, errlen,
                "directory %s must be owned by root and not group/world "
                "writable (uid=%u mode=%04o)", parent, (unsigned)st.st_uid,
                (unsigned)(st.st_mode & 07777));
        return TB_PEER_ERR_BINARY_UNTRUSTED;
    }

    if (resolved != NULL) {
        strlcpy(resolved, canon, PATH_MAX);
    }
    return TB_PEER_OK;
}

/*
 * Does the running code identified by `token` satisfy the designated
 * requirement of the binary at `binary_path`?
 */
static int check_code_identity(const audit_token_t *token,
                               const char *binary_path,
                               char *errbuf, size_t errlen)
{
    int rc = TB_PEER_ERR_CODE_IDENTITY;
    CFDataRef tokenData = NULL;
    CFDictionaryRef attrs = NULL;
    SecCodeRef peerCode = NULL;
    CFURLRef url = NULL;
    SecStaticCodeRef diskCode = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus status;

    tokenData = CFDataCreate(kCFAllocatorDefault,
                             (const UInt8 *)token, sizeof(*token));
    if (tokenData == NULL) {
        set_err(errbuf, errlen, "CFDataCreate failed");
        goto out;
    }

    const void *keys[] = { kSecGuestAttributeAudit };
    const void *values[] = { tokenData };
    attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                               &kCFTypeDictionaryKeyCallBacks,
                               &kCFTypeDictionaryValueCallBacks);
    if (attrs == NULL) {
        set_err(errbuf, errlen, "CFDictionaryCreate failed");
        goto out;
    }

    status = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags,
                                            &peerCode);
    if (status != errSecSuccess) {
        set_err(errbuf, errlen,
                "SecCodeCopyGuestWithAttributes failed: %d", (int)status);
        goto out;
    }

    url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)binary_path,
        (CFIndex)strlen(binary_path), false);
    if (url == NULL) {
        set_err(errbuf, errlen, "cannot build URL for %s", binary_path);
        goto out;
    }

    status = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &diskCode);
    if (status != errSecSuccess) {
        set_err(errbuf, errlen,
                "SecStaticCodeCreateWithPath(%s) failed: %d",
                binary_path, (int)status);
        goto out;
    }

    status = SecCodeCopyDesignatedRequirement(diskCode, kSecCSDefaultFlags,
                                              &requirement);
    if (status != errSecSuccess) {
        set_err(errbuf, errlen,
                "%s has no usable code signature (status %d); "
                "sign it (codesign -s -) and reinstall",
                binary_path, (int)status);
        goto out;
    }

    status = SecCodeCheckValidity(peerCode, kSecCSDefaultFlags, requirement);
    if (status != errSecSuccess) {
        set_err(errbuf, errlen,
                "peer code does not match %s (status %d); "
                "if the daemon was just upgraded, restart it",
                binary_path, (int)status);
        goto out;
    }

    rc = TB_PEER_OK;

out:
    if (requirement) CFRelease(requirement);
    if (diskCode)    CFRelease(diskCode);
    if (url)         CFRelease(url);
    if (peerCode)    CFRelease(peerCode);
    if (attrs)       CFRelease(attrs);
    if (tokenData)   CFRelease(tokenData);
    return rc;
}

int tb_verify_peer(int fd, const char *expected_path, uid_t expected_uid,
                   char *errbuf, size_t errlen)
{
    char canon[PATH_MAX];
    char peer_path[PROC_PIDPATHINFO_MAXSIZE];
    struct xucred cred;
    audit_token_t token;
    socklen_t len;
    int rc;

    /* 1. The binary we are about to trust must itself be trustworthy. */
    rc = tb_check_trusted_binary(expected_path, canon, errbuf, errlen);
    if (rc != TB_PEER_OK) {
        return rc;
    }

    /* 2. Peer uid. */
    memset(&cred, 0, sizeof(cred));
    len = sizeof(cred);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) != 0
        || cred.cr_version != XUCRED_VERSION) {
        set_err(errbuf, errlen, "LOCAL_PEERCRED failed: %s", strerror(errno));
        return TB_PEER_ERR_PEERCRED;
    }
    if (cred.cr_uid != expected_uid) {
        set_err(errbuf, errlen, "peer uid %u, expected %u",
                (unsigned)cred.cr_uid, (unsigned)expected_uid);
        return TB_PEER_ERR_UID_MISMATCH;
    }

    /* 3. Peer executable, looked up by audit token so a recycled pid
     *    cannot be confused with the real peer. */
    memset(&token, 0, sizeof(token));
    len = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) != 0
        || len != sizeof(token)) {
        set_err(errbuf, errlen, "LOCAL_PEERTOKEN failed: %s", strerror(errno));
        return TB_PEER_ERR_PEERCRED;
    }
    if (proc_pidpath_audittoken(&token, peer_path, sizeof(peer_path)) <= 0) {
        set_err(errbuf, errlen, "cannot resolve peer executable: %s",
                strerror(errno));
        return TB_PEER_ERR_PEERCRED;
    }
    if (strcmp(peer_path, canon) != 0) {
        set_err(errbuf, errlen, "peer executable is %s, expected %s",
                peer_path, canon);
        return TB_PEER_ERR_PATH_MISMATCH;
    }

    /* 4. The running code is exactly what is on disk. */
    return check_code_identity(&token, canon, errbuf, errlen);
}

int tb_response_mode(const char *response, char *mode, size_t modelen)
{
    static const char key[] = "\"mode\":\"";
    const char *start;
    const char *end;
    size_t n;

    if (response == NULL || mode == NULL || modelen == 0) {
        return 0;
    }
    start = strstr(response, key);
    if (start == NULL) {
        return 0;
    }
    start += sizeof(key) - 1;
    end = strchr(start, '"');
    if (end == NULL) {
        return 0;
    }
    n = (size_t)(end - start);
    if (n >= modelen) {
        n = modelen - 1;
    }
    memcpy(mode, start, n);
    mode[n] = '\0';
    return 1;
}
