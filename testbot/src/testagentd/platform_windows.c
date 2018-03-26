/*
 * Provides Windows-specific implementations of some TestAgentd functions.
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

#include "platform.h"
#include "list.h"

struct child_t
{
    struct list entry;
    DWORD pid;
    HANDLE handle;
};

static struct list children = LIST_INIT(children);


uint64_t platform_run(char** argv, uint32_t flags, char** redirects)
{
    DWORD stdhandles[3] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE};
    HANDLE fhs[3] = {INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE};
    SECURITY_ATTRIBUTES sa;
    STARTUPINFO si;
    PROCESS_INFORMATION pi;
    int has_redirects, i, cmdsize;
    char *cmdline, *d, **arg;

    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = TRUE;

    /* Build the windows command line */
    cmdsize = 0;
    for (arg = argv; *arg; arg++)
    {
        char* s = *arg;
        while (*s)
            cmdsize += (*s++ == '"' ? 2 : 1);
        cmdsize += 3; /* 2 quotes and either a space or trailing '\0' */
    }
    cmdline = malloc(cmdsize);
    if (!cmdline)
    {
        set_status(ST_ERROR, "malloc() failed: %s", strerror(errno));
        return 0;
    }
    d = cmdline;
    for (arg = argv; *arg; arg++)
    {
        char* s = *arg;
        *d++ = '"';
        while (*s)
        {
            if (*s == '"')
                *d++ = '\\';
            *d++ = *s++;
        }
        *d++ = '"';
        *d++ = ' ';
    }
    *(d-1) = '\0';

    /* Prepare the redirections */
    has_redirects = 0;
    for (i = 0; i < 3; i++)
    {
        DWORD access, creation;
        if (redirects[i][0] == '\0')
        {
            fhs[i] = GetStdHandle(stdhandles[i]);
            continue;
        }
        has_redirects = 1;
        switch (i)
        {
        case 0:
            access = GENERIC_READ;
            creation = OPEN_EXISTING;
            break;
        case 1:
            access = FILE_APPEND_DATA;
            creation = (flags & RUN_DNTRUNC_OUT ? OPEN_ALWAYS : CREATE_ALWAYS);
            break;
        case 2:
            access = FILE_APPEND_DATA;
            creation = (flags & RUN_DNTRUNC_ERR ? OPEN_ALWAYS : CREATE_ALWAYS);
            break;
        }
        fhs[i] = CreateFile(redirects[i], access, FILE_SHARE_DELETE | FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, creation, FILE_ATTRIBUTE_NORMAL, NULL);
        debug("  %d redirected -> %p\n", i, fhs[i]);
        if (fhs[i] == INVALID_HANDLE_VALUE)
        {
            set_status(ST_ERROR, "unable to open '%s' for %s: %lu", redirects[i], i ? "writing" : "reading", GetLastError());
            free(cmdline);
            while (i > 0)
            {
                if (fhs[i] != INVALID_HANDLE_VALUE)
                    CloseHandle(fhs[i]);
                i--;
            }
            return 0;
        }
    }

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = has_redirects ? STARTF_USESTDHANDLES : 0;
    si.hStdInput = fhs[0];
    si.hStdOutput = fhs[1];
    si.hStdError = fhs[2];
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, NORMAL_PRIORITY_CLASS,
                        NULL, NULL, &si, &pi))
    {
        set_status(ST_ERROR, "could not run '%s': %lu", cmdline, GetLastError());
        return 0;
    }
    CloseHandle(pi.hThread);

    if (flags & RUN_DNT)
        CloseHandle(pi.hProcess);
    else
    {
        struct child_t* child;
        child = malloc(sizeof(*child));
        child->pid = pi.dwProcessId;
        child->handle = pi.hProcess;
        list_add_head(&children, &child->entry);
    }

    free(cmdline);
    for (i = 0; i < 3; i++)
        if (redirects[i][0])
            CloseHandle(fhs[i]);

    return pi.dwProcessId;
}

int platform_wait(SOCKET client, uint64_t pid, uint32_t timeout, uint32_t *childstatus)
{
    struct child_t *child;
    HANDLE handles[2];
    u_long nbio;
    DWORD r, success;

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

    /* Wait for either the socket to be closed, indicating a client-side
     * timeout, or for the child process to exit.
     */
    handles[0] = WSACreateEvent();
    WSAEventSelect(client, handles[0], FD_CLOSE);
    handles[1] = child->handle;
    r = WaitForMultipleObjects(2, handles, FALSE, timeout == RUN_NOTIMEOUT ? INFINITE : timeout * 1000);

    success = 0;
    switch (r)
    {
    case WAIT_OBJECT_0:
        set_status(ST_ERROR, "connection closed");
        break;

    case WAIT_OBJECT_0 + 1:
        if (GetExitCodeProcess(child->handle, &r))
        {
            debug("  process %lu returned status %lu\n", child->pid, r);
            *childstatus = r;
            success = 1;
        }
        else
            debug("GetExitCodeProcess() failed (%lu). Giving up!\n", GetLastError());
        break;
    case WAIT_TIMEOUT:
        set_status(ST_ERROR, "timed out waiting for the child process");
        success = 0;
        goto cleanup;
    default:
        debug("WaitForMultipleObjects() returned %lu (le=%lu). Giving up!\n", r, GetLastError());
        break;
    }
    /* Don't close child->handle so we can retrieve the exit status again if
     * needed.
     */

 cleanup:
    /* We must reset WSAEventSelect before we can make
     * the socket blocking again.
     */
    WSAEventSelect(client, handles[0], 0);
    CloseHandle(handles[0]);
    nbio = 0;
    if (WSAIoctl(client, FIONBIO, &nbio, sizeof(nbio), &nbio, sizeof(nbio), &r, NULL, NULL) == SOCKET_ERROR)
        debug("WSAIoctl(FIONBIO) failed: %s\n", sockerror());

    return success;
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

    CloseHandle(child->handle);
    list_remove(&child->entry);
    free(child);
    return 1;
}

int platform_settime(uint64_t epoch, uint32_t leeway)
{
    FILETIME filetime;
    SYSTEMTIME systemtime;

    /* Where 134774 is the number of days from 1601/1/1 to 1970/1/1 */
    epoch = (epoch + ((uint64_t)134774) * 24 * 3600 ) * 10000000;

    if (leeway)
    {
        ULARGE_INTEGER ul;
        GetSystemTime(&systemtime);
        /* in case of an error set the time unconditionally */
        if (SystemTimeToFileTime(&systemtime, &filetime))
        {
            ul.LowPart = filetime.dwLowDateTime;
            ul.HighPart = filetime.dwHighDateTime;
            if (llabs(ul.QuadPart-epoch)/10000000 < leeway)
                return 1;
        }
    }

    filetime.dwLowDateTime = (DWORD)epoch;
    filetime.dwHighDateTime = epoch >> 32;
    if (!FileTimeToSystemTime(&filetime, &systemtime))
    {
        set_status(ST_ERROR, "failed to oconvert the time (%lu)", GetLastError());
        return 0;
    }
    if (!SetSystemTime(&systemtime))
    {
        set_status(ST_ERROR, "failed to set the time (%lu)", GetLastError());
        return 0;
    }
    return 1;
}


int platform_upgrade_script(const char* script, const char* tmpserver, char** argv)
{
    char testagentd[MAX_PATH];
    DWORD rc;
    FILE* fh;

    rc = GetModuleFileName(NULL, testagentd, sizeof(testagentd));
    if (!rc || rc == sizeof(testagentd))
    {
        set_status(ST_ERROR, "unable to get the current process filename (%lu, le=%lu)", rc, GetLastError());
        return 0;
    }

    fh = fopen(script, "w");
    if (!fh)
    {
        set_status(ST_ERROR, "unable to open '%s' for writing: %s", script, strerror(errno));
        return 0;
    }
    /* Allow time for the server to exit */
    fprintf(fh, "ping -n 1 -w 1000 1.1.1.1 >/nul\r\n");
    /* Note that preserving the server filename is necessary and sufficient
     * in order to get through the Windows firewall.
     */
    fprintf(fh, "copy /y \"%s\" \"%s\"\r\n", tmpserver, testagentd);
    fprintf(fh, "del \"%s\"\r\n", tmpserver);
    fprintf(fh, "%s\r\n", GetCommandLine());
    fclose(fh);

    return 1;
}

struct msg_thread_t
{
    char* message;
    message_dismissed_func dismissed;
};

DWORD WINAPI msg_thread(LPVOID parameter)
{
    struct msg_thread_t* data = parameter;

    MessageBoxA(NULL, data->message, "Message", MB_OK);
    free(data->message);
    if (data->dismissed)
        (*data->dismissed)();
    free(data);
    return 0;
}

void platform_show_message(const char* message, message_dismissed_func dismissed)
{
    HANDLE thread;
    struct msg_thread_t* data = malloc(sizeof(struct msg_thread_t));

    fprintf(stderr, message);

    data->message = strdup(message);
    data->dismissed = dismissed;
    thread = CreateThread(NULL, 0, &msg_thread, data, 0, NULL);
    CloseHandle(thread);
}

int sockretry(void)
{
    return (WSAGetLastError() == WSAEINTR);
}

const char* sockerror(void)
{
    static char msg[1024];

    msg[0] = '\0';
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS  | FORMAT_MESSAGE_MAX_WIDTH_MASK,
                   NULL, WSAGetLastError(), LANG_USER_DEFAULT,
                   msg, sizeof(msg), NULL);
    msg[sizeof(msg)-1] = '\0';
    return msg;
}

char* sockaddr_to_string(struct sockaddr* sa, socklen_t len)
{
    /* Store the name in a buffer large enough for DNS hostnames */
    static char name[256+6];
    DWORD size = sizeof(name);
    /* This also appends the port number */
    if (WSAAddressToString(sa, len, NULL, name, &size))
        sprintf(name, "unknown host (family %d)", sa->sa_family);
    return name;
}

int (WINAPI *pgetaddrinfo)(const char *node, const char *service,
                           const struct addrinfo *hints,
                           struct addrinfo **addresses);
void (WINAPI *pfreeaddrinfo)(struct addrinfo *addresses);

int ta_getaddrinfo(const char *node, const char *service,
                   struct addrinfo **addresses)
{
    struct servent* sent;
    u_short port;
    char dummy;
    struct hostent* hent;
    char** addr;
    struct addrinfo *ai;
    struct sockaddr_in *sin4;
    struct sockaddr_in6 *sin6;

    if (pgetaddrinfo)
    {
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_flags = AI_PASSIVE;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        return pgetaddrinfo(node, service, &hints, addresses);
    }

    sent = getservbyname(service, "tcp");
    if (sent)
        port = sent->s_port;
    else if (!service)
        port = 0;
    else if (sscanf(service, "%hu%c", &port, &dummy) == 1)
        port = htons(port);
    else
        return EAI_SERVICE;

    *addresses = NULL;
    hent = gethostbyname(node);
    if (!hent)
        return EAI_NONAME;
    for (addr = hent->h_addr_list; *addr; addr++)
    {
        ai = malloc(sizeof(*ai));
        switch (hent->h_addrtype)
        {
        case AF_INET:
            ai->ai_addrlen = sizeof(*sin4);
            ai->ai_addr = malloc(ai->ai_addrlen);
            sin4 = (struct sockaddr_in*)ai->ai_addr;
            sin4->sin_family = hent->h_addrtype;
            sin4->sin_port = port;
            memcpy(&sin4->sin_addr, *addr, hent->h_length);
            break;
        case AF_INET6:
            ai->ai_addrlen = sizeof(*sin6);
            ai->ai_addr = malloc(ai->ai_addrlen);
            sin6 = (struct sockaddr_in6*)ai->ai_addr;
            sin6->sin6_family = hent->h_addrtype;
            sin4->sin_port = port;
            sin6->sin6_flowinfo = 0;
            memcpy(&sin6->sin6_addr, *addr, hent->h_length);
            break;
        default:
            debug("ignoring unknown address type %u\n", hent->h_addrtype);
            free(ai);
            continue;
        }
        ai->ai_flags = 0;
        ai->ai_family = hent->h_addrtype;
        ai->ai_socktype = SOCK_STREAM;
        ai->ai_protocol = IPPROTO_TCP;
        ai->ai_canonname = NULL; /* We don't use it anyway */
        ai->ai_next = *addresses;
        *addresses = ai;
    }
    if (!node)
    {
        /* Add INADDR_ANY last so it is tried first */
        ai = malloc(sizeof(*ai));
        ai->ai_addrlen = sizeof(*sin4);
        ai->ai_addr = malloc(ai->ai_addrlen);
        sin4 = (struct sockaddr_in*)ai->ai_addr;
        sin4->sin_family = ai->ai_family = AF_INET;
        sin4->sin_port = port;
        sin4->sin_addr.S_un.S_addr = INADDR_ANY;
        ai->ai_flags = 0;
        ai->ai_socktype = SOCK_STREAM;
        ai->ai_protocol = IPPROTO_TCP;
        ai->ai_canonname = NULL; /* We don't use it anyway */
        ai->ai_next = *addresses;
        *addresses = ai;
    }
    return 0;
}

void ta_freeaddrinfo(struct addrinfo *addresses)
{
    if (pfreeaddrinfo)
        pfreeaddrinfo(addresses);
    else
    {
        while (addresses)
        {
            free(addresses->ai_addr);
            addresses = addresses->ai_next;
        }
    }
}

void platform_detach_console(void)
{
    FreeConsole();
}

int platform_init(void)
{
    HMODULE hdll;
    WORD wVersionRequested;
    WSADATA wsaData;
    int rc;

    wVersionRequested = MAKEWORD(2, 2);
    rc = WSAStartup(wVersionRequested, &wsaData);
    if (rc)
    {
        error("unable to initialize winsock (%d)\n", rc);
        return 0;
    }

    hdll = GetModuleHandle("ws2_32");
    pgetaddrinfo = (void*)GetProcAddress(hdll, "getaddrinfo");
    pfreeaddrinfo = (void*)GetProcAddress(hdll, "freeaddrinfo");

    /* By default stderr is fully buffered and Windows does not support
     * line buffering. So disable buffering altogether.
     */
    setvbuf(stderr, NULL, _IONBF, 0);

    return 1;
}
