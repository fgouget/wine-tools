/*
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


/*
 * Compatibility definitions.
 */

#ifdef WIN32
# include <ws2tcpip.h>
# include <windows.h>

# ifndef SHUT_RD
#  define SHUT_RD SD_RECEIVE
# endif

typedef unsigned int uint32_t;
typedef ULONGLONG uint64_t;
#define U64FMT "%I64u"

#else

# include <arpa/inet.h>
# include <sys/types.h>
# include <sys/socket.h>
# include <sys/select.h>
# include <netdb.h>

typedef int SOCKET;
# define closesocket(sock) close((sock))

#define U64FMT "%lu"
#endif

#ifndef O_BINARY
# define O_BINARY 0
#endif


/*
 * Platform-specific functions.
 */

int platform_init(void);

/* Detach from the console so closing it won't kill testagentd. */
void platform_detach_console(void);

enum run_flags_t {
    RUN_DNT = 1,
    RUN_DNTRUNC_OUT = 2,
    RUN_DNTRUNC_ERR = 4,
};

#define RUN_NOTIMEOUT  ((uint32_t)0xffffffff)

/* Starts the specified command in the background and reports the status to
 * the client.
 */
uint64_t platform_run(char** argv, uint32_t flags, char** redirects);

/* If a command was started in the background, waits until either that command
 * terminates, the specified timeout (in seconds) expires, or the client
 * disconnects (typically because it got tired of waiting).
 * Note that this does not cause the child process to be forgotten, even if it
 * did exit. This is so that the client can retrieve the information again if
 * needed (e.g. in case it did not receive it due to a network issue).
 * If no command was started in the background, then reports an error
 * immediately.
 */
int platform_wait(SOCKET client, uint64_t pid, uint32_t timeout, uint32_t *childstatus);

/* Causes the given child process to be forgotten, which means it will no longer
 * be possible to wait for it or retrieve its exit status.
 */
int platform_rmchildproc(SOCKET client, uint64_t pid);

/* Sets the system time to the specified Unix epoch. If the system time is
 * already within leeway seconds of the specified time, then consider that
 * the system clock is already correct.
 */
int platform_settime(uint64_t epoch, uint32_t leeway);

/* Creates a script to be invoked to upgrade the current server.
 * The current server is responsible for starting the script and quickly exit.
 * The script will wait a bit, replace the server file and restart the server
 * with the same arguments as the original server.
 */
int platform_upgrade_script(const char* script, const char* tmpserver, char** argv);

/* Returns a string describing the last socket-related error */
int sockeintr(void);
const char* sockerror(void);

/* Converts a socket address into a string stored in a static buffer. */
char* sockaddr_to_string(struct sockaddr* sa, socklen_t len);

int ta_getaddrinfo(const char *node, const char *service,
                   struct addrinfo **addresses);

void ta_freeaddrinfo(struct addrinfo *addresses);


/*
 * testagentd functions
 */

#ifdef __GNUC__
# define FORMAT(fmt, arg1)    __attribute__((format (printf, fmt, arg1) ))
#else
# define FORMAT(fmt, arg1)
#endif

void error(const char* format, ...) FORMAT(1,2);
void debug(const char* format, ...) FORMAT(1,2);

#define ST_OK       0
#define ST_ERROR    1
#define ST_FATAL    2
void set_status(int status, const char* format, ...) FORMAT(2,3);

void* sockaddr_getaddr(const struct sockaddr* sa, socklen_t* len);
