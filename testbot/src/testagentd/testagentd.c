/*
 * Provides a simple way to send/receive files and to run scripts.
 *
 * Copyright 2012 Francois Gouget
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#include <stdio.h>
#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "platform.h"

/* Increase the major version number when making backward-incompatible changes.
 * Otherwise increase the minor version number:
 * 1.0:  Initial release.
 * 1.1:  Added the wait2 RPC.
 * 1.2:  Add more redirection options to the run RPC.
 * 1.3:  Fix the zero / infinite timeouts in the wait2 RPC.
 * 1.4:  Add the settime RPC.
 * 1.5:  Add support for upgrading the server.
 * 1.6:  Add the rmchildproc and getcwd RPCs.
 * 1.7:  Add --show-restarts and the setproperty RPC.
 */
#define PROTOCOL_VERSION "testagentd 1.7"

#define BLOCK_SIZE       65536

static char** server_argv;
static const char *name0;
static int opt_debug = 0;


/*
 * Local error reporting
 */

void error(const char* format, ...)
{
    va_list valist;
    fprintf(stderr, "%s:error: ", name0);
    va_start(valist, format);
    vfprintf(stderr, format, valist);
    va_end(valist);
}

void debug(const char* format, ...)
{
    if (opt_debug)
    {
        va_list valist;
        va_start(valist, format);
        vfprintf(stderr, format, valist);
        va_end(valist);
    }
}


/*
 * Functions related to the list of known RPCs.
 */

enum rpc_ids_t
{
    RPCID_PING = 0,
    RPCID_GETFILE,
    RPCID_SENDFILE,
    RPCID_RUN,
    RPCID_WAIT,
    RPCID_RM,
    RPCID_WAIT2,
    RPCID_SETTIME,
    RPCID_GETPROPERTIES,
    RPCID_UPGRADE,
    RPCID_RMCHILDPROC,
    RPCID_GETCWD,
    RPCID_SETPROPERTY,
};

/* This is the RPC currently being processed */
#define NO_RPCID         (~((uint32_t)0))
static uint32_t rpcid = NO_RPCID;

static const char* rpc_name(uint32_t id)
{
    static char unknown[11];
    static const char* names[] = {
        "ping",
        "getfile",
        "sendfile",
        "run",
        "wait",
        "rm",
        "wait2",
        "settime",
        "getproperties",
        "upgrade",
        "rmchildproc",
        "getcwd",
        "setproperty",
    };

    if (id < sizeof(names) / sizeof(*names))
        return names[id];
    if (id == NO_RPCID)
        return "norpc";
    sprintf(unknown, "%u", id);
    return unknown;
}


/*
 * Functions to set the status of the last operation.
 * This is sort of like an errno variable which is meant to be sent to the
 * client to indicate the result of the last operation.
 */

/* status can take three values:
 * - ST_OK    indicates that the operation was successful
 * - ST_ERROR the operation failed but we can still perform other operations
 * - ST_FATAL the connection is in an undefined state and should be closed
 */
static int status = ST_OK;
const char* status_names[] = {"ok:", "error:", "fatal:"};

/* If true, then the current connection is in a broken state */
static int broken = 0;

/* If true, then the server should exit */
static int quit = 0;

static char* vformat_msg(char** buf, int* size, const char* format, va_list valist)
{
    int len;
    va_list args;
    len = 1;
    do
    {
        if (len >= *size)
        {
            /* len does not count the trailing '\0'. So add 1 and round up
             * to the next 16 bytes multiple.
             */
            *size = (len + 1 + 0xf) & ~0xf;
            *buf = realloc(*buf, *size);
        }
        va_copy(args, valist);
        len = vsnprintf(*buf, *size, format, args);
        va_end(args);
        if (len < 0)
            len = *size * 1.1;
    }
    while (len >= *size);
    return *buf;
}

static char* format_msg(char** buf, int* size, const char* format, ...)
{
    va_list valist;
    va_start(valist, format);
    vformat_msg(buf, size, format, valist);
    va_end(valist);
    return *buf;
}

/* This is a message which indicates the reason for the status */
static char* status_msg = NULL;
static int status_size = 0;
static void vset_status_msg(const char* format, va_list valist)
{
    vformat_msg(&status_msg, &status_size, format, valist);
    if (opt_debug || status != ST_OK)
        fprintf(stderr, "%s%s: %s\n", status_names[status], rpc_name(rpcid), status_msg);
}

void set_status(int newstatus, const char* format, ...)
{
    va_list valist;
    /* Don't let an error erase a fatal error */
    if (newstatus != ST_ERROR || status != ST_FATAL)
    {
        status = newstatus;
        if (newstatus == ST_FATAL)
            broken = 1;
        else if (newstatus == ST_OK)
            broken = 0;
        va_start(valist, format);
        vset_status_msg(format, valist);
        va_end(valist);
    }
}


/*
 * Low-level functions to receive raw data
 */

static int skip_raw_data(SOCKET client, uint64_t size)
{
    char buf[BLOCK_SIZE];

    if (broken)
        return 0;

    while (size)
    {
        int s = size < sizeof(buf) ? size : sizeof(buf);
        int r = recv(client, buf, s, 0);
        if (r < 0)
        {
            set_status(ST_FATAL, "skip_raw_data() failed: %s", sockerror());
            return 0;
        }
        size -= r;
    }
    return 1;
}

static int recv_raw_data(SOCKET client, void* data, uint64_t size)
{
    char* d = data;

    if (broken)
        return 0;

    while (size)
    {
        int r = recv(client, d, size, 0);
        if (r == 0)
        {
            set_status(ST_FATAL, "recv_raw_data() got a premature EOF");
            return 0;
        }
        if (r < 0)
        {
            set_status(ST_FATAL, "recv_raw_data() failed: %s", sockerror());
            return 0;
        }
        d += r;
        size -= r;
    }
    return 1;
}

static int recv_raw_uint32(SOCKET client, uint32_t *u32)
{
    if (!recv_raw_data(client, u32, sizeof(*u32)))
        return 0;
    *u32 = ntohl(*u32);
    return 1;
}

static int recv_raw_uint64(SOCKET client, uint64_t *u64)
{
    uint32_t high, low;

    if (!recv_raw_uint32(client, &high) || !recv_raw_uint32(client, &low))
        return 0;
    *u64 = ((uint64_t)high) << 32 | low;
    return 1;
}


/*
 * Functions to receive argument lists
 */

static int recv_entry_header(SOCKET client, char *type, uint64_t *size)
{
    return recv_raw_data(client, type, sizeof(*type)) &&
           recv_raw_uint64(client, size);
}

#define ANY_SIZE   (~((uint64_t)0))

static int expect_entry_header(SOCKET client, char type, uint64_t *size)
{
    char htype;
    uint64_t hsize;
    int success;

    if (!recv_entry_header(client, &htype, &hsize))
        return 0;

    if (type != htype)
    {
        set_status(ST_ERROR, "Expected a parameter of type %c but got %c instead", type, htype);
        success = 0;
    }
    else if (*size != ANY_SIZE && *size != hsize)
    {
        set_status(ST_ERROR, "Expected a parameter of size " U64FMT " but got " U64FMT " instead", *size, hsize);
        success = 0;
    }
    else
    {
        *size = hsize;
        success = 1;
    }
    if (!success)
        skip_raw_data(client, hsize);
    return success;
}

static int recv_uint32(SOCKET client, uint32_t *u32)
{
    uint64_t size = sizeof(*u32);
    int success = expect_entry_header(client, 'I', &size) &&
                  recv_raw_uint32(client, u32);
    if (success)
        debug("  recv_uint32() -> %u\n", *u32);
    return success;
}

static int recv_uint64(SOCKET client, uint64_t *u64)
{
    uint64_t size = sizeof(*u64);
    int success = expect_entry_header(client, 'Q', &size) &&
                  recv_raw_uint64(client, u64);
    if (success)
        debug("  recv_uint64() -> " U64FMT "\n", *u64);
    return success;
}

static int recv_string(SOCKET client, char* *str)
{
    uint64_t size = ANY_SIZE;
    int success;

    *str = NULL;
    if (!expect_entry_header(client, 's', &size))
        return 0;

    *str = malloc(size);
    if (!*str)
    {
        set_status(ST_ERROR, "malloc() failed: %s", strerror(errno));
        skip_raw_data(client, size);
        return 0;
    }
    success = recv_raw_data(client, *str, size);
    if (success)
        debug("  recv_string() -> '%s'\n", *str);
    else
    {
        free(*str);
        *str = NULL;
    }
    return success;
}

static int recv_file(SOCKET client, int fd, const char* filename)
{
    uint64_t size = ANY_SIZE;

    debug("  recv_file(%s)\n", filename);
    if (!expect_entry_header(client, 'd', &size))
        return 0;

    while (size)
    {
        char buffer[BLOCK_SIZE];
        int c, r, w;
        c = size < sizeof(buffer) ? size : sizeof(buffer);
        r = recv(client, buffer, c, 0);
        if (r == 0)
        {
            debug("  got disconnected with " U64FMT " bytes still to be read!\n", size);
            set_status(ST_FATAL, "got disconnected prematurely");
            return 0;
        }
        if (r < 0)
        {
            set_status(ST_FATAL, "an error occurred while reading: %s", sockerror());
            return 0;
        }
        size -= r;
        w = write(fd, buffer, r);
        if (w != r)
        {
            set_status(ST_ERROR, "an error occurred while writing to '%s': %s", filename, strerror(errno));
            debug("  could only write %d bytes out of %d: %s\n", w, r, strerror(errno));
            skip_raw_data(client, size);
            return 0;
        }
    }
    debug("  File reception complete\n");
    return 1;
}

static int skip_entries(SOCKET client, uint32_t count)
{
    while (count)
    {
        char type;
        uint64_t size;
        if (!recv_entry_header(client, &type, &size) ||
            !skip_raw_data(client, size))
            return 0;
        count--;
    }
    return 1;
}

static int recv_list_size(SOCKET client, uint32_t *u32)
{
    if (!recv_raw_uint32(client, u32))
        return 0;
    debug("  recv_list_size() -> %u\n", *u32);

    if (*u32 >= 1048576)
    {
        /* The client is in fact most likely not speaking the right protocol */
        set_status(ST_FATAL, "the list size is too big (%d)", *u32);
        return 0;
    }
    return 1;
}

static int expect_list_size(SOCKET client, uint32_t expected)
{
    uint32_t size;

    if (!recv_list_size(client, &size))
        return 0;

    if (size == expected)
        return 1;

    set_status(ST_ERROR, "Invalid number of parameters (%u instead of %u)", size, expected);
    skip_entries(client, size);
    return 0;
}


/*
 * Low-level functions to send raw data
 */


static int send_raw_data(SOCKET client, const void* data, uint64_t size)
{
    const char* d = data;

    if (broken)
        return 0;

    while (size)
    {
        int w = send(client, d, size, 0);
        if (w < 0)
        {
            set_status(ST_FATAL, "send_raw_data() failed: %s", sockerror());
            return 0;
        }
        d += w;
        size -= w;
    }
    return 1;
}

static int send_raw_uint32(SOCKET client, uint32_t u32)
{
    u32 = htonl(u32);
    return send_raw_data(client, &u32, sizeof(u32));
}

static int send_raw_uint64(SOCKET client, uint64_t u64)
{
    return send_raw_uint32(client, u64 >> 32) &&
           send_raw_uint32(client, u64 & 0xffffffff);
}


/*
 * Functions to send argument lists
 */

static int send_list_size(SOCKET client, uint32_t u32)
{
    debug("  send_list_size(%u)\n", u32);
    return send_raw_uint32(client, u32);
}

static int send_entry_header(SOCKET client, char type, uint64_t size)
{
    return send_raw_data(client, &type, sizeof(type)) &&
           send_raw_uint64(client, size);
}

static int _send_status(SOCKET client, char type)
{
    int stlen, msglen;

    msglen = strlen(status_msg);
    if (status == ST_ERROR)
    {
        /* Omit the 'error' prefix */
        debug("  send_status('%c', '%s')\n", type, status_msg);
        return send_entry_header(client, type, msglen + 1) &&
               send_raw_data(client, status_msg, msglen + 1);
    }
    else
    {
        /* Include the 'fatal' prefix for fatal errors */
        stlen = strlen(status_names[status]);
        debug("  send_status('%c', '%s %s')\n", type, status_names[status], status_msg);
        return send_entry_header(client, type, stlen + 1 + msglen + 1) &&
            send_raw_data(client, status_names[status], stlen) &&
            send_raw_data(client, " ", 1) &&
            send_raw_data(client, status_msg, msglen + 1);
    }
}

static int send_status(SOCKET client)
{
    return _send_status(client, 's');
}

static int send_error(SOCKET client)
{
    /* We send only one result string */
    return send_list_size(client, 1) &&
           _send_status(client, 'e');
}

static int send_undef(SOCKET client)
{
    debug("  send_undef()\n");
    return send_entry_header(client, 'u', 0);
}

static int send_uint32(SOCKET client, uint32_t u32)
{
    debug("  send_uint32(%u)\n", u32);
    return send_entry_header(client, 'I', sizeof(u32)) &&
           send_raw_uint32(client, u32);
}

static int send_uint64(SOCKET client, uint64_t u64)
{
    debug("  send_uint64(" U64FMT ")\n", u64);
    return send_entry_header(client, 'Q', sizeof(u64)) &&
           send_raw_uint64(client, u64);
}

static int send_string(SOCKET client, const char* str)
{
    uint64_t size;

    debug("  send_string(%s)\n", str);
    size = strlen(str) + 1;
    return send_entry_header(client, 's', size) &&
           send_raw_data(client, str, size);
}

static int send_file(SOCKET client, int fd, const char* filename)
{
    char buffer[BLOCK_SIZE];
    struct stat st;
    uint64_t size;

    if (broken)
        return 0;

    debug("  send_file(%s)\n", filename);
    if (fstat(fd, &st))
    {
        set_status(ST_ERROR, "unable to get the size of '%s': %s", filename, strerror(errno));
        return 0;
    }
    size = st.st_size;
    if (!send_entry_header(client, 'd', size))
        return 0;

    while (size)
    {
        int r, w;
        int c;
        c = size < sizeof(buffer) ? size : sizeof(buffer);
        r = read(fd, buffer, c);
        if (r == 0)
        {
            debug("  reached EOF with " U64FMT " bytes still to be read!\n", size);
            set_status(ST_FATAL, "reached the '%s' EOF prematurely", filename);
            return 0;
        }
        if (r < 0)
        {
            set_status(ST_FATAL, "an error occurred while reading '%s': %s", filename, strerror(errno));
            return 0;
        }
        size -= r;
        w = send(client, buffer, r, 0);
        if (w != r)
        {
            set_status(ST_FATAL, "an error occurred while sending: %s", sockerror());
            debug("  could only send %d bytes out of %d: %s\n", w, r, sockerror());
            return 0;
        }
    }
    debug("  File successfully sent\n");
    return 1;
}


/*
 * TestAgentd restart / Windows reboot tracking.
 */

static unsigned int start_count = 0;

static char* start_count_filename(void)
{
    char* filename = malloc(strlen(name0) + 5 + 1);
    sprintf(filename, "%s.data", name0);
    return filename;
}

static void load_start_count(void)
{
    FILE *fh;
    char* filename = start_count_filename();
    fh = fopen(filename, "r");
    if (fh)
    {
        if (!fscanf(fh, "%d", &start_count))
            start_count = 0;
        fclose(fh);
    }
    free(filename);
}

static void save_start_count(void)
{
    FILE *fh;
    char* filename = start_count_filename();
    fh = fopen(filename, "w");
    if (fh)
    {
        fprintf(fh, "%d\n", start_count);
        fclose(fh);
    }
    free(filename);
}


/*
 * High-level operations.
 */

static void do_ping(SOCKET client)
{
    if (expect_list_size(client, 0))
        send_list_size(client, 0);
    else
        send_error(client);
}

static void do_getfile(SOCKET client)
{
    char* filename;
    int fd;

    if (!expect_list_size(client, 1) ||
        !recv_string(client, &filename))
    {
        send_error(client);
        return;
    }

    fd = open(filename, O_RDONLY | O_BINARY);
    if (fd < 0)
    {
        set_status(ST_ERROR, "unable to open '%s' for reading: %s", filename, strerror(errno));
        send_error(client);
    }
    else
    {
        if (!send_list_size(client, 1) ||
            !send_file(client, fd, filename))
        {
            /* If the file is not accessible then send_file() will fail and we
             * can still salvage the connection by sending the error message
             * in place of the file content. In all the other cases the
             * connection is broken anyway which send_error() will deal with
             * just fine.
             */
            send_error(client);
        }
        close(fd);
    }
    free(filename);
}

enum sendfile_flags_t {
    SF_EXECUTABLE = 1,
};

static void do_sendfile(SOCKET client)
{
    char *filename;
    uint32_t flags;
    mode_t mode;
    int fd, success;

    if (!expect_list_size(client, 3) ||
        !recv_string(client, &filename) ||
        !recv_uint32(client, &flags)
        /* Next entry is the file data */
        )
    {
        free(filename); /* filename is either NULL or malloc()-ed here */
        send_error(client);
        return;
    }

    unlink(filename); /* To force re-setting the mode */
    mode = (flags & SF_EXECUTABLE) ? 0700 : 0600;
    fd = open(filename, O_WRONLY | O_CREAT | O_TRUNC | O_BINARY, mode);
    if (fd < 0)
    {
        skip_entries(client, 1);
        set_status(ST_ERROR, "unable to open '%s' for writing: %s", filename, strerror(errno));
        success = 0;
    }
    else
    {
        success = recv_file(client, fd, filename);
        close(fd);
    }

    if (!success)
        unlink(filename);
    free(filename);

    if (success)
        send_list_size(client, 0);
    else
        send_error(client);
}

static void do_run(SOCKET client)
{
    uint32_t argc, i;
    char** argv;
    uint32_t flags;
    int failed;
    char *redirects[3];
    uint64_t pid;

    /* Get and check argc */
    if (!recv_list_size(client, &argc))
    {
        send_error(client);
        return;
    }
    argv = NULL;
    if (argc < 5)
        set_status(ST_ERROR, "expected 5 or more parameters");
    else
    {
        /* Allocate an extra entry for the trailing NULL pointer */
        argv = malloc((argc - 4 + 1) * sizeof(*argv));
        if (!argv)
            set_status(ST_ERROR, "malloc() failed: %s", strerror(errno));
    }
    if (!argv)
    {
        skip_entries(client, argc);
        send_error(client);
        return;
    }
    argc -= 4;

    /* Retrieve the parameters */
    failed = 0;
    memset(redirects, 0, sizeof(redirects));
    memset(argv, 0, (argc + 1) * sizeof(*argv));
    if (recv_uint32(client, &flags) &&
        recv_string(client, &redirects[0]) &&
        recv_string(client, &redirects[1]) &&
        recv_string(client, &redirects[2]))
    {
        for (i = 0; i < argc; i++)
            if (!recv_string(client, &argv[i]))
            {
                failed = 1;
                break;
            }
    }
    else
        failed = 1;

    if (!failed)
    {
        debug("  run '%s", argv[0]);
        for (i = 1; i < argc; i++)
            debug("' '%s", argv[i]);
        debug("'%s%s%s%s%s%s\n",
              !redirects[0][0] ? "" : " <", redirects[0],
              !redirects[1][0] ? "" : (flags & RUN_DNTRUNC_OUT) ? " >>" : " >", redirects[1],
              !redirects[2][0] ? "" : (flags & RUN_DNTRUNC_ERR) ? " 2>>" : " 2>", redirects[2]);

        pid = platform_run(argv, flags, redirects);
        if (!pid)
            failed = 1;
    }

    /* Free all the memory */
    free(redirects[0]);
    free(redirects[1]);
    free(redirects[2]);
    for (i = 0; i < argc; i++)
        free(argv[i]);
    free(argv);

    if (failed)
        send_error(client);
    else
    {
        send_list_size(client, 1);
        send_uint64(client, pid);
    }
}

static void do_wait(SOCKET client)
{
    uint64_t pid;
    uint32_t childstatus;

    if (!expect_list_size(client, 1) ||
        !recv_uint64(client, &pid))
    {
        send_error(client);
        return;
    }

    if (platform_wait(client, pid, RUN_NOTIMEOUT, &childstatus))
    {
        send_list_size(client, 1);
        send_uint32(client, childstatus);
    }
    else
        send_error(client);
}

static void do_wait2(SOCKET client)
{
    uint64_t pid;
    uint32_t timeout;
    uint32_t childstatus;

    if (!expect_list_size(client, 2) ||
        !recv_uint64(client, &pid) ||
        !recv_uint32(client, &timeout))
    {
        send_error(client);
        return;
    }

    if (platform_wait(client, pid, timeout, &childstatus))
    {
        send_list_size(client, 1);
        send_uint32(client, childstatus);
    }
    else
        send_error(client);
}

static void do_rmchildproc(SOCKET client)
{
    uint64_t pid;

    if (!expect_list_size(client, 1) ||
        !recv_uint64(client, &pid))
    {
        send_error(client);
        return;
    }

    if (platform_rmchildproc(client, pid))
        send_list_size(client, 0);
    else
        send_error(client);
}

static void do_rm(SOCKET client)
{
    int got_errors;
    uint32_t argc, i;
    char** filenames;

    /* Get and check the parameter count */
    if (!recv_list_size(client, &argc))
    {
        send_error(client);
        return;
    }

    filenames = malloc(argc * sizeof(*filenames));
    if (!filenames)
    {
        set_status(ST_ERROR, "malloc() failed: %s", strerror(errno));
        skip_entries(client, argc);
        send_error(client);
        return;
    }

    /* Retrieve the parameters */
    memset(filenames, 0, argc * sizeof(*filenames));
    got_errors = 0;
    for (i = 0; i < argc; i++)
    {
        if (!recv_string(client, &filenames[i]))
        {
            got_errors = 1;
            send_error(client);
            break;
        }
    }

    if (!got_errors)
    {
        for (i = 0; i < argc; i++)
        {
            debug("rm '%s'\n", filenames[i]);
            if (unlink(filenames[i]) < 0 && errno != ENOENT && errno != ENOTDIR)
            {
                int err = errno;
                if (!got_errors)
                {
                    int f;
                    got_errors = 1;
                    /* In case of error report on the success / failure
                     * for each file.
                     */
                    send_list_size(client, argc);
                    for (f = 0; f < i; f++)
                        if (!send_undef(client))
                            break;
                }
                set_status(ST_ERROR, "Could not delete '%s': %s", filenames[i], strerror(err));
                if (!send_status(client))
                    break;
            }
            else if (got_errors)
            {
                if (!send_undef(client))
                    break;
            }
        }
    }

    /* Free all the memory */
    for (i = 0; i < argc; i++)
        free(filenames[i]);
    free(filenames);

    if (!got_errors)
    {
        /* If all the deletions succeeded, then return an empty list to mean
         * nothing to report
         */
        send_list_size(client, 0);
    }
}

static void do_settime(SOCKET client)
{
    uint64_t epoch;
    uint32_t leeway;

    if (!expect_list_size(client, 2) ||
        !recv_uint64(client, &epoch) ||
        !recv_uint32(client, &leeway))
    {
        send_error(client);
        return;
    }
    if (platform_settime(epoch, leeway))
        send_list_size(client, 0);
    else
        send_error(client);
}

static void do_getproperties(SOCKET client)
{
    const char* arch;
    char* buf = NULL;
    int size = 0;

    if (!expect_list_size(client, 0))
    {
        send_error(client);
        return;
    }
    send_list_size(client, 3);

    format_msg(&buf, &size, "protocol.version=%s", PROTOCOL_VERSION);
    send_string(client, buf);

#ifdef WIN32
    arch = "win32";
#else
    if (sizeof(void*) == 4)
        arch = "linux32";
    else
        arch = "linux64";
#endif
    format_msg(&buf, &size, "server.arch=%s", arch);
    send_string(client, buf);

    format_msg(&buf, &size, "start.count=%u", start_count);
    send_string(client, buf);

    free(buf);
}

static void do_setproperty(SOCKET client)
{
    char *name = NULL, *value = NULL;

    if (!expect_list_size(client, 2) ||
        !recv_string(client, &name) ||
        !recv_string(client, &value))
    {
        send_error(client);
        return;
    }

    if (strcmp(name, "start.count") == 0)
    {
        unsigned int val;
        if (sscanf(value, "%u", &val) == 1)
        {
            start_count = val;
            save_start_count();
            send_list_size(client, 0);
        }
        else
        {
            set_status(ST_ERROR, "'%s' is not a valid %s value", value, name);
            send_error(client);
        }
    }
    else if (strcmp(name, "protocol.version") == 0 ||
             strcmp(name, "server.arch") == 0)
    {
        set_status(ST_ERROR, "%s is read-only", name);
        send_error(client);
    }
    else
    {
        set_status(ST_ERROR, "unknown property %s", name);
        send_error(client);
    }
}

static void do_upgrade(SOCKET client)
{
    static const char *filename = "testagentd.tmp";
    static const char* upgrade_script = "./replace.bat";
    int fd, success;

    if (!expect_list_size(client, 1)
        /* Next entry is the file data */
        )
    {
        send_error(client);
        return;
    }

    unlink(filename); /* To force re-setting the mode */
    fd = open(filename, O_WRONLY | O_CREAT | O_TRUNC | O_BINARY, 0700);
    if (fd < 0)
    {
        skip_entries(client, 1);
        set_status(ST_ERROR, "unable to open '%s' for writing: %s", filename, strerror(errno));
        success = 0;
    }
    else
    {
        success = recv_file(client, fd, filename);
        close(fd);
    }

    if (!success)
        unlink(filename);
    else
        success = platform_upgrade_script(upgrade_script, filename, server_argv);

    if (success)
    {
        char* args[2];
        char* redirects[3] = {"", "", ""};

        send_list_size(client, 0);

        args[0] = strdup(upgrade_script);
        args[1] = NULL;
        success = platform_run(args, RUN_DNT, redirects);
        free(args[0]);
        if (success)
        {
            /* Decrement the start count since this one is intentional */
            start_count--;
            save_start_count();

            broken = 1;
            quit = 1;
        }
    }
    else
        send_error(client);
}

static void do_getcwd(SOCKET client)
{
    char curdir[261];

    if (expect_list_size(client, 0))
    {
        send_list_size(client, 1);
        send_string(client, getcwd(curdir, sizeof(curdir)));
    }
    else
        send_error(client);
}

static void do_unknown(SOCKET client, uint32_t id)
{
    uint32_t argc;

    if (recv_list_size(client, &argc) &&
        skip_entries(client, argc))
    {
        set_status(ST_ERROR, "unknown RPC %s", rpc_name(id));
        send_error(client);
    }
}

static void process_rpc(SOCKET client)
{
    int r;

    debug("Waiting for an RPC\n");
    r = recv(client, (void*)&rpcid, 1, MSG_PEEK);
    if (r == 0)
    {
        /* The client disconnected normally */
        broken = 1;
        return;
    }
    else if (r < 0)
    {
        /* Some error occurred */
        debug("No RPC: %s\n", sockerror());
        broken = 1;
        return;
    }
    if (!recv_raw_uint32(client, &rpcid))
    {
        set_status(ST_FATAL, "no RPC id");
        return;
    }

    debug("-> %s\n", rpc_name(rpcid));
    switch (rpcid)
    {
    case RPCID_PING:
        do_ping(client);
        break;
    case RPCID_GETFILE:
        do_getfile(client);
        break;
    case RPCID_SENDFILE:
        do_sendfile(client);
        break;
    case RPCID_RUN:
        do_run(client);
        break;
    case RPCID_WAIT:
        do_wait(client);
        break;
    case RPCID_WAIT2:
        do_wait2(client);
        break;
    case RPCID_RM:
        do_rm(client);
        break;
    case RPCID_SETTIME:
        do_settime(client);
        break;
    case RPCID_GETPROPERTIES:
        do_getproperties(client);
        break;
    case RPCID_UPGRADE:
        do_upgrade(client);
    case RPCID_GETCWD:
        do_getcwd(client);
        break;
    case RPCID_RMCHILDPROC:
        do_rmchildproc(client);
        break;
    case RPCID_SETPROPERTY:
        do_setproperty(client);
        break;
    default:
        do_unknown(client, rpcid);
    }
}

void* sockaddr_getaddr(const struct sockaddr* sa, socklen_t* len)
{
    switch (sa->sa_family)
    {
    case AF_INET:
        if (len)
            *len = sizeof(struct in_addr);
        return &((struct sockaddr_in*)sa)->sin_addr;
    case AF_INET6:
        if (len)
            *len = sizeof(struct in6_addr);
        return &((struct sockaddr_in6*)sa)->sin6_addr;
    }
    if (len)
        *len = 0;
    return NULL;
}

static int sockaddr_equal(struct sockaddr* sa1, struct sockaddr* sa2)
{
    void *addr1, *addr2;
    socklen_t len;

    if (sa1->sa_family != sa2->sa_family)
        return 0;

    addr1 = sockaddr_getaddr(sa1, &len);
    addr2 = sockaddr_getaddr(sa2, &len);
    if (!addr1 || !addr2)
        return 0;
    return memcmp(addr1, addr2, len) == 0;
}

static int is_host_allowed(SOCKET client, const char* srchost, int addrlen)
{
    struct addrinfo *addresses, *addrp;
    struct sockaddr *peeraddr;
    socklen_t peerlen;
    int rc;

    debug("checking source address\n");
    if (!srchost)
        return 1;

    peerlen = addrlen;
    peeraddr = malloc(peerlen);
    if (getpeername(client, peeraddr, &peerlen))
    {
        error("unable to get the peer address: %s\n", sockerror());
        free(peeraddr);
        return 0;
    }
    debug("Received connection from %s\n", sockaddr_to_string(peeraddr, peerlen));
    rc = ta_getaddrinfo(srchost, NULL, &addresses);
    if (rc)
    {
        error("unable to resolve '%s': %s\n", srchost, gai_strerror(rc));
        free(peeraddr);
        return 0;
    }

    addrp = addresses;
    do
    {
        debug("  checking against %s\n", sockaddr_to_string(addrp->ai_addr, addrp->ai_addrlen));
        if (sockaddr_equal(peeraddr, addrp->ai_addr))
        {
            free(peeraddr);
            ta_freeaddrinfo(addresses);
            return 1;
        }
    }
    while ((addrp = addrp->ai_next) != NULL);
    ta_freeaddrinfo(addresses);

    debug("  -> rejecting connection\n");
    free(peeraddr);
    return 0;
}


static void reset_start_count(void)
{
    start_count = 1;
    save_start_count();
}

static void check_start_count(void)
{
    load_start_count();
    start_count++;
    save_start_count();

    if (start_count > 1)
    {
        char msg[255];
        sprintf(msg, "%s was restarted (%d). Did Windows reboot?\n", name0, start_count);
        platform_show_message(msg, &reset_start_count);
    }
}

int main(int argc, char** argv)
{
    const char* p;
    char** arg;
    int opt_detach = 0;
    int opt_show_restarts = 0;
    char* opt_port = NULL;
    char* opt_srchost = NULL;
    struct addrinfo *addresses, *addrp;
    int rc, sockflags, addrlen;
    int opt_usage = 0;
    SOCKET master;
    int on = 1;

    server_argv = argv;
    name0 = p = argv[0];
    while (*p != '\0')
    {
        if (*p == '/' || *p == '\\')
            name0 = p + 1;
        p++;
    }

    arg = argv + 1;
    while (*arg)
    {
        if (strcmp(*arg, "--debug") == 0)
        {
            opt_debug = 1;
        }
        else if (strcmp(*arg, "--detach") == 0)
        {
            opt_detach = 1;
        }
        else if (strcmp(*arg, "--show-restarts") == 0)
        {
            opt_show_restarts = 1;
        }
        else if (strcmp(*arg, "--help") == 0)
        {
            opt_usage = 1;
        }
        else if (**arg == '-')
        {
            error("unknown option '%s'\n", *arg);
            opt_usage = 2;
            break;
        }
        else if (opt_port == NULL)
        {
            opt_port = *arg;
        }
        else if (opt_srchost == NULL)
        {
            opt_srchost = *arg;
        }
        else
        {
            error("unexpected option '%s'\n", *arg);
            opt_usage = 2;
            break;
        }
        arg++;
    }
    if (!opt_usage)
    {
        if (!opt_port)
        {
            error("you must specify the port to listen on\n");
            opt_usage = 2;
        }

        if (!platform_init())
        {
            if (!opt_usage)
                exit(1);
            /* else opt_usage will force us to exit early anyway */
        }
        else if (opt_srchost)
        {
            /* Verify that the specified source host is valid */
            rc = ta_getaddrinfo(opt_srchost, NULL, &addresses);
            if (rc)
            {
                error("unable to resolve '%s': %s\n", opt_srchost, gai_strerror(rc));
                opt_usage = 2;
            }
            else
            {
                if (opt_debug)
                {
                    addrp = addresses;
                    do
                    {
                        debug("Accepting connections from %s\n", sockaddr_to_string(addrp->ai_addr, addrp->ai_addrlen));
                    }
                    while ((addrp = addrp->ai_next) != NULL);
                }
                ta_freeaddrinfo(addresses);
            }
        }
    }
    if (opt_usage == 2)
    {
        error("try '%s --help' for more information\n", name0);
        exit(2);
    }
    if (opt_usage)
    {
        printf("Usage: %s [--debug] [--detach] [--help] PORT [SRCHOST]\n", name0);
        printf("\n");
        printf("Provides a simple way to send/receive files and to run scripts on this host.\n");
        printf("\n");
        printf("Where:\n");
        printf("  PORT     The port to listen on for connections.\n");
        printf("  SRCHOST  If specified, only connections from this host will be accepted.\n");
        printf("  --debug  Prints detailed information about what happens.\n");
        printf("  --detach Detach from the console / terminal. Note that on Windows you should\n");
        printf("           combine this with start: start %s --detach ...\n", name0);
        printf("  --show-restarts Shows a message if %s has been restarted (for instance\n", name0);
        printf("           because of a Windows reboot).\n");
        printf("  --help   Shows this usage message.\n");
        exit(0);
    }
    if (opt_detach)
        platform_detach_console();
    if (opt_show_restarts)
        check_start_count();

    /* Bind to the host in a protocol neutral way */
#ifdef SOCK_CLOEXEC
    sockflags = SOCK_CLOEXEC;
#else
    sockflags = 0;
#endif
    rc = ta_getaddrinfo(NULL, opt_port, &addresses);
    if (rc)
    {
        error("unable to get the host address for port %s: %s\n", opt_port, gai_strerror(rc));
        exit(1);
    }
    for (addrp = addresses; addrp; addrp = addrp->ai_next)
    {
        debug("trying family=%d\n", addrp->ai_family);
        if (addrp->ai_family != PF_INET)
            continue;
        master = socket(addrp->ai_family, addrp->ai_socktype | sockflags,
                        addrp->ai_protocol);
        if (master < 0)
            continue;
        setsockopt(master, SOL_SOCKET, SO_REUSEADDR, (void*)&on, sizeof(on));
#ifdef HANDLE_FLAG_INHERIT
        SetHandleInformation((HANDLE)master, HANDLE_FLAG_INHERIT, 0);
#endif

        debug("Trying to bind to %s\n", sockaddr_to_string(addrp->ai_addr, addrp->ai_addrlen));
        if (bind(master, addrp->ai_addr, addrp->ai_addrlen) == 0)
            break;
        closesocket(master);
    };
    if (addrp)
        addrlen = addrp->ai_addrlen;
    ta_freeaddrinfo(addresses);
    if (addrp == NULL)
    {
        error("unable to bind the server socket: %s\n", sockerror());
        exit(1);
    }

    if (listen(master, 1) < 0)
    {
        error("listen() failed: %s\n", sockerror());
        exit(1);
    }
    printf("Starting %s\n", PROTOCOL_VERSION);
    while (!quit)
    {
        SOCKET client;
        debug("Waiting in accept()\n");
        client = accept(master, NULL, NULL);
#ifdef O_CLOEXEC
        fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) | O_CLOEXEC);
#endif
#ifdef HANDLE_FLAG_INHERIT
        SetHandleInformation((HANDLE)client, HANDLE_FLAG_INHERIT, 0);
#endif
        if (client >= 0)
        {
            if (is_host_allowed(client, opt_srchost, addrlen))
            {
                /* Reset the status so new non-fatal errors can be set */
                set_status(ST_OK, "ok");

                /* Send the version right away */
                send_string(client, PROTOCOL_VERSION);

                while (!broken)
                    process_rpc(client);
            }
            debug("closing client socket\n");
            closesocket(client);
        }
        else if (!sockeintr())
        {
            error("accept() failed: %s\n", sockerror());
            exit(1);
        }
    }
    debug("stopping\n");
    closesocket(master);

    return 0;
}
