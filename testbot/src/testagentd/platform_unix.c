/*
 * Provides Unix-specific implementations of some TestAgentd functions.
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
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <sys/time.h>

#include "platform.h"
#include "list.h"


struct child_t
{
    struct list entry;
    uint64_t pid;
    int reaped;
    uint32_t status;
};

static struct list children = LIST_INIT(children);


void reaper(int signum)
{
    struct child_t* child;
    pid_t pid;
    int status;

    pid = wait(&status);
    debug("process %u returned %u\n", pid, status);

    LIST_FOR_EACH_ENTRY(child, &children, struct child_t, entry)
    {
        if (child->pid == pid)
        {
            child->status = status;
            child->reaped = 1;
            break;
        }
    }
}

uint64_t platform_run(char** argv, uint32_t flags, char** redirects)
{
    pid_t pid;
    int fds[3] = {-1, -1, -1};
    int ofl, i;

    for (i = 0; i < 3; i++)
    {
        if (redirects[i][0] == '\0')
            continue;
        switch (i)
        {
        case 0:
            ofl = O_RDONLY;
            break;
        case 1:
            ofl = O_APPEND | O_CREAT | (flags & RUN_DNTRUNC_OUT ? 0 : O_TRUNC);
            break;
        case 2:
            ofl = O_APPEND | O_CREAT | (flags & RUN_DNTRUNC_ERR ? 0 : O_TRUNC);
            break;
        }
        fds[i] = open(redirects[i], ofl, 0666);
        if (fds[i] < 0)
        {
            set_status(ST_ERROR, "unable to open '%s' for %s: %s", redirects[i], i ? "writing" : "reading", strerror(errno));
            while (i > 0)
            {
                if (fds[i] != -1)
                    close(fds[i]);
                i--;
            }
            return 0;
        }
    }

    pid = fork();
    if (pid == 0)
    {
        for (i = 0; i < 3; i++)
        {
            if (fds[i] != -1)
            {
                dup2(fds[i], i);
                close(fds[i]);
            }
        }
        execvp(argv[0], argv);
        error("could not run '%s': %s\n", argv[0], strerror(errno));
        exit(1);
    }
    if (pid < 0)
    {
        set_status(ST_ERROR, "could not fork: %s", strerror(errno));
        pid = 0;
    }
    else
    {
        if (!(flags & RUN_DNT))
        {
            struct child_t* child;
            child = malloc(sizeof(*child));
            child->pid = pid;
            child->reaped = 0;
            list_add_head(&children, &child->entry);
        }
    }
    for (i = 0; i < 3; i++)
        if (fds[i] != -1)
            close(fds[i]);
    return pid;
}

int platform_wait(SOCKET client, uint64_t pid, uint32_t timeout, uint32_t *childstatus)
{
    struct child_t* child;
    time_t deadline;

    LIST_FOR_EACH_ENTRY(child, &children, struct child_t, entry)
    {
        if (child->pid == pid)
            break;
    }
    if (!child || child->pid != pid)
    {
        set_status(ST_ERROR, "the " U64FMT " process does not exist or is not a child process", pid);
        return 0;
    }

    if (timeout != RUN_NOTIMEOUT)
        deadline = time(NULL) + timeout;
    while (!child->reaped)
    {
        fd_set rfds;
        char buffer;
        struct timeval tv;
        int ready;

        /* select() blocks until either the client disconnects, or
         * the SIGCHLD signal indicates the child has exited. The recv() call
         * tells us if it is the former.
         */
        debug("Waiting for " U64FMT "\n", pid);
        FD_ZERO(&rfds);
        FD_SET(client, &rfds);
        if (timeout != RUN_NOTIMEOUT)
        {
            tv.tv_sec = deadline - time(NULL);
            if (tv.tv_sec < 0)
                tv.tv_sec = 0;
            tv.tv_usec = 0;
        }
        ready = select(client+1, &rfds, NULL, NULL, timeout != RUN_NOTIMEOUT ? &tv : NULL);
        if (ready == 0)
        {
            /* This is the timeout */
            set_status(ST_ERROR, "timed out waiting for the child process");
            return 0;
        }
        if (ready == 1 && FD_ISSET(client, &rfds) &&
            recv(client, &buffer, 1, MSG_PEEK | MSG_DONTWAIT) <= 0)
        {
            set_status(ST_FATAL, "connection closed");
            return 0;
        }
    }
    debug("process " U64FMT " returned status %u\n", pid, child->status);
    *childstatus = child->status;
    return 1;
}

int platform_rmchildproc(SOCKET client, uint64_t pid)
{
    struct child_t *child;

    LIST_FOR_EACH_ENTRY(child, &children, struct child_t, entry)
    {
        if (child->pid == pid)
            break;
    }
    if (!child || child->pid != pid)
    {
        set_status(ST_ERROR, "the " U64FMT " process does not exist or is not a child process", pid);
        return 0;
    }
    list_remove(&child->entry);
    free(child);
    return 1;
}

int platform_settime(uint64_t epoch, uint32_t leeway)
{
    struct timeval tv;

    if (leeway)
    {
        uint64_t offset;
        gettimeofday(&tv, NULL);
        offset = llabs(tv.tv_sec-epoch);
        if (offset <= leeway)
            return 2;
    }

    tv.tv_sec = epoch;
    tv.tv_usec = 0;
    if (!settimeofday(&tv, NULL))
    {
        set_status(ST_ERROR, "failed to set the time: %s", strerror(errno));
        return 0;
    }
    return 1;
}


int platform_upgrade(const char* tmpserver, char** argv)
{
    static const char* oldserver = "testagentd.old";
    int pipefds[2];
    pid_t pid;

    if (rename(argv[0], oldserver))
    {
        set_status(ST_ERROR, "unable to move the current server file out of the way: %s", strerror(errno));
        return 0;
    }

    if (rename(tmpserver, argv[0]))
    {
        set_status(ST_ERROR, "unable to move the currentnew server file into place: %s", strerror(errno));
        rename(oldserver, argv[0]);
        return 0;
    }
    if (pipe(pipefds))
    {
        set_status(ST_ERROR, "could not synchronize with the new process: %s", strerror(errno));
        rename(oldserver, argv[0]);
        return 0;
    }

    pid = fork();
    if (pid < 0)
    {
        set_status(ST_ERROR, "unable to start the new server: %s", strerror(errno));
        close(pipefds[0]);
        close(pipefds[1]);
        rename(oldserver, argv[0]);
        return 0;
    }

    unlink(oldserver);
    if (!pid)
    {
        /* The child process is responsible for cleanly closing the connection
         * to the client.
         */
        close(pipefds[0]);
        return 1;
    }
    close(pipefds[1]);

    /* Wait for the read to fail which means the child exited and released the
     * TestAgentd port.
     */
    read(pipefds[0], &pid, 1);
    close(pipefds[0]);

    execvp(argv[0], argv);
    return 1;
}

void platform_show_message(const char* message, message_dismissed_func dismissed)
{
    /* Don't bother trying to pop up a GUI. There may not be one anyway.
     * Since the user has no way to dismiss the dialog the dismissed function
     * is not called.
     */
    fprintf(stderr, "%s", message);
}

int sockeintr(void)
{
    return errno == EINTR;
}

const char* sockerror(void)
{
    return strerror(errno);
}

char* sockaddr_to_string(struct sockaddr* sa, socklen_t len)
{
    /* Store the name in a buffer large enough for DNS hostnames */
    static char name[256+6];
    void* addr;
    u_short port;

    addr = sockaddr_getaddr(sa, NULL);
    if (!addr || !inet_ntop(sa->sa_family, addr, name, sizeof(name)))
    {
        sprintf(name, "unknown host (family %d)", sa->sa_family);
        return NULL;
    }
    switch (sa->sa_family)
    {
    case AF_INET:
        port = htons(((struct sockaddr_in*)sa)->sin_port);
        break;
    case AF_INET6:
        port = htons(((struct sockaddr_in6*)sa)->sin6_port);
        break;
    default:
        port = 0;
    }
    if (port)
    {
        snprintf(name+strlen(name), sizeof(name)-strlen(name), ":%hu", port);
        name[sizeof(name)-1] = '\0';
    }
    return name;
}

int ta_getaddrinfo(const char *node, const char *service,
                   struct addrinfo **addresses)
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_flags = AI_PASSIVE;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    return getaddrinfo(node, service, &hints, addresses);
}

void ta_freeaddrinfo(struct addrinfo *addresses)
{
    return freeaddrinfo(addresses);
}

void platform_detach_console(void)
{
    pid_t pid;

    pid = fork();
    if (pid != 0)
        exit(0);

    /* Daemonize */
    signal(SIGHUP, SIG_IGN);
    pid = fork();
    if (pid != 0)
        exit(0);
}

int platform_init(void)
{
    struct sigaction sa, osa;

    /* Catch SIGCHLD so we can keep track of child processes */
    sa.sa_handler = reaper;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    if (sigaction(SIGCHLD, &sa, &osa) < 0)
    {
        error("could not set up the SIGCHLD handler: %s\n", strerror(errno));
        return 0;
    }

    /* Catch SIGPIPE so we don't die if the client disconnects at an
     * inconvenient time
     */
    sa.sa_handler = SIG_IGN;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    if (sigaction(SIGPIPE, &sa, &osa) < 0)
    {
        error("could not set up the SIGPIPE handler: %s\n", strerror(errno));
        return 0;
    }

    return 1;
}
