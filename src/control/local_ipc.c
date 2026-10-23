#include "control_c.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FORTE_CONTROL_MAX 8192

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <sddl.h>
#include <lmcons.h>
#include <io.h>
typedef HANDLE ForteHandle;
#else
typedef int ForteHandle;
#endif

typedef struct {
    ForteHandle listener;
    ForteHandle client;
    char pending[FORTE_CONTROL_MAX];
    size_t used;
    int request_ready;
    char endpoint[512];
} ForteControlServer;

#ifndef _WIN32
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int set_nonblocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

int forte_control_endpoint(char *out, size_t capacity) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime || runtime[0] != '/') runtime = "/tmp";
    const int n = snprintf(out, capacity, "%s/forte-player-%lu.sock", runtime, (unsigned long)getuid());
    return n > 0 && (size_t)n < capacity ? n : -1;
}

void *forte_control_server_create(const char *endpoint) {
    ForteControlServer *s = (ForteControlServer *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->listener = -1;
    s->client = -1;
    if (strlen(endpoint) >= sizeof(s->endpoint) || strlen(endpoint) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        free(s);
        return NULL;
    }
    strcpy(s->endpoint, endpoint);

    const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { free(s); return NULL; }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, endpoint);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if (errno != EADDRINUSE) { close(fd); free(s); return NULL; }
        /* Only remove stale sockets; never unlink a live server's endpoint. */
        const int probe = socket(AF_UNIX, SOCK_STREAM, 0);
        if (probe >= 0 && connect(probe, (struct sockaddr *)&address, sizeof(address)) == 0) {
            close(probe); close(fd); free(s); return NULL;
        }
        if (probe >= 0) close(probe);
        unlink(endpoint);
        if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); free(s); return NULL; }
    }
    chmod(endpoint, S_IRUSR | S_IWUSR);
    if (listen(fd, 4) != 0 || !set_nonblocking(fd)) {
        close(fd); unlink(endpoint); free(s); return NULL;
    }
    s->listener = fd;
    return s;
}

int forte_control_server_poll(void *handle, char *request, size_t capacity) {
    ForteControlServer *s = (ForteControlServer *)handle;
    if (!s || !request || capacity == 0) return -1;
    if (s->request_ready) return 0;
    if (s->client < 0) {
        s->client = accept(s->listener, NULL, NULL);
        if (s->client < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1;
        if (!set_nonblocking(s->client)) { close(s->client); s->client = -1; return -1; }
        s->used = 0;
    }
    char chunk[2048];
    const ssize_t n = read(s->client, chunk, sizeof(chunk));
    if (n == 0) { close(s->client); s->client = -1; s->used = 0; return 0; }
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
        close(s->client); s->client = -1; s->used = 0; return -1;
    }
    for (ssize_t i = 0; i < n; ++i) {
        if (chunk[i] == '\n') {
            if (s->used == 0 || s->used >= capacity) { close(s->client); s->client = -1; s->used = 0; return -1; }
            memcpy(request, s->pending, s->used);
            request[s->used] = '\0';
            s->request_ready = 1;
            return (int)s->used;
        }
        if (s->used + 1 >= sizeof(s->pending)) { close(s->client); s->client = -1; s->used = 0; return -1; }
        s->pending[s->used++] = chunk[i];
    }
    return 0;
}

int forte_control_server_reply(void *handle, const char *reply, size_t length) {
    ForteControlServer *s = (ForteControlServer *)handle;
    if (!s || s->client < 0 || !s->request_ready) return -1;
    size_t offset = 0;
    while (offset < length) {
        const ssize_t n = write(s->client, reply + offset, length - offset);
        if (n > 0) { offset += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    if (offset == length && (length == 0 || reply[length - 1] != '\n')) (void)write(s->client, "\n", 1);
    close(s->client);
    s->client = -1;
    s->used = 0;
    s->request_ready = 0;
    return offset == length ? 0 : -1;
}

void forte_control_server_destroy(void *handle) {
    ForteControlServer *s = (ForteControlServer *)handle;
    if (!s) return;
    if (s->client >= 0) close(s->client);
    if (s->listener >= 0) close(s->listener);
    unlink(s->endpoint);
    free(s);
}

int forte_control_client_call(const char *endpoint, const char *request, size_t request_length,
                              char *response, size_t response_capacity) {
    const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(endpoint) >= sizeof(address.sun_path)) { close(fd); return -1; }
    strcpy(address.sun_path, endpoint);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return -1; }
    size_t sent = 0;
    while (sent < request_length) {
        const ssize_t n = write(fd, request + sent, request_length - sent);
        if (n > 0) sent += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else { close(fd); return -1; }
    }
    if (request_length == 0 || request[request_length - 1] != '\n') (void)write(fd, "\n", 1);
    size_t used = 0;
    while (used + 1 < response_capacity) {
        const ssize_t n = read(fd, response + used, response_capacity - used - 1);
        if (n > 0) {
            for (ssize_t i = 0; i < n; ++i) if (response[used + (size_t)i] == '\n') {
                used += (size_t)i;
                response[used] = '\0';
                close(fd);
                return (int)used;
            }
            used += (size_t)n;
        } else if (n < 0 && errno == EINTR) continue;
        else { close(fd); return -1; }
    }
    close(fd);
    return -1;
}

#else
int forte_control_endpoint(char *out, size_t capacity) {
    char user[UNLEN + 1];
    DWORD user_length = UNLEN + 1;
    if (!GetUserNameA(user, &user_length)) strcpy(user, "default");
    const int n = snprintf(out, capacity, "\\\\.\\pipe\\forte-player-%s", user);
    return n > 0 && (size_t)n < capacity ? n : -1;
}

void *forte_control_server_create(const char *endpoint) {
    ForteControlServer *s = (ForteControlServer *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->listener = INVALID_HANDLE_VALUE;
    s->client = INVALID_HANDLE_VALUE;
    if (strlen(endpoint) >= sizeof(s->endpoint)) { free(s); return NULL; }
    strcpy(s->endpoint, endpoint);
    PSECURITY_DESCRIPTOR descriptor = NULL;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(
            "D:P(A;;GA;;;OW)(A;;GA;;;SY)", SDDL_REVISION_1, &descriptor, NULL)) {
        free(s);
        return NULL;
    }
    SECURITY_ATTRIBUTES security = { sizeof(security), descriptor, FALSE };
    s->listener = CreateNamedPipeA(endpoint, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT,
        1, FORTE_CONTROL_MAX, FORTE_CONTROL_MAX, 0, &security);
    LocalFree(descriptor);
    if (s->listener == INVALID_HANDLE_VALUE) { free(s); return NULL; }
    s->client = s->listener;
    return s;
}

int forte_control_server_poll(void *handle, char *request, size_t capacity) {
    ForteControlServer *s = (ForteControlServer *)handle;
    if (!s || !request || capacity == 0) return -1;
    if (s->request_ready) return 0;
    BOOL connected = ConnectNamedPipe(s->listener, NULL);
    if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = TRUE;
    if (!connected && GetLastError() != ERROR_PIPE_LISTENING && GetLastError() != ERROR_NO_DATA) return -1;
    if (!connected && GetLastError() != ERROR_NO_DATA) return 0;
    char chunk[2048];
    DWORD read_count = 0;
    if (!ReadFile(s->listener, chunk, sizeof(chunk), &read_count, NULL)) {
        const DWORD error = GetLastError();
        if (error == ERROR_NO_DATA || error == ERROR_PIPE_LISTENING) return 0;
        if (error == ERROR_BROKEN_PIPE) { (void)DisconnectNamedPipe(s->listener); s->used = 0; return 0; }
        return -1;
    }
    for (DWORD i = 0; i < read_count; ++i) {
        if (chunk[i] == '\n') {
            if (s->used == 0 || s->used >= capacity) { (void)DisconnectNamedPipe(s->listener); s->used = 0; return -1; }
            memcpy(request, s->pending, s->used);
            request[s->used] = '\0';
            s->request_ready = 1;
            return (int)s->used;
        }
        if (s->used + 1 >= sizeof(s->pending)) { (void)DisconnectNamedPipe(s->listener); s->used = 0; return -1; }
        s->pending[s->used++] = chunk[i];
    }
    return 0;
}

int forte_control_server_reply(void *handle, const char *reply, size_t length) {
    ForteControlServer *s = (ForteControlServer *)handle;
    if (!s || s->listener == INVALID_HANDLE_VALUE || !s->request_ready) return -1;
    size_t offset = 0;
    while (offset < length) {
        DWORD written = 0;
        if (!WriteFile(s->listener, reply + offset, (DWORD)(length - offset), &written, NULL) || written == 0) break;
        offset += written;
    }
    if (offset == length && (length == 0 || reply[length - 1] != '\n')) {
        DWORD written = 0;
        (void)WriteFile(s->listener, "\n", 1, &written, NULL);
    }
    (void)FlushFileBuffers(s->listener);
    (void)DisconnectNamedPipe(s->listener);
    s->used = 0;
    s->request_ready = 0;
    return offset == length ? 0 : -1;
}

void forte_control_server_destroy(void *handle) {
    ForteControlServer *s = (ForteControlServer *)handle;
    if (!s) return;
    (void)DisconnectNamedPipe(s->listener);
    CloseHandle(s->listener);
    free(s);
}

int forte_control_client_call(const char *endpoint, const char *request, size_t request_length,
                              char *response, size_t response_capacity) {
    if (!WaitNamedPipeA(endpoint, 1000)) return -1;
    HANDLE pipe = CreateFileA(endpoint, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (pipe == INVALID_HANDLE_VALUE) return -1;
    DWORD written = 0;
    if (!WriteFile(pipe, request, (DWORD)request_length, &written, NULL) || written != request_length) { CloseHandle(pipe); return -1; }
    if (request_length == 0 || request[request_length - 1] != '\n') {
        if (!WriteFile(pipe, "\n", 1, &written, NULL)) { CloseHandle(pipe); return -1; }
    }
    size_t used = 0;
    while (used + 1 < response_capacity) {
        DWORD got = 0;
        if (!ReadFile(pipe, response + used, (DWORD)(response_capacity - used - 1), &got, NULL) || got == 0) { CloseHandle(pipe); return -1; }
        for (DWORD i = 0; i < got; ++i) if (response[used + i] == '\n') {
            used += i;
            response[used] = '\0';
            CloseHandle(pipe);
            return (int)used;
        }
        used += got;
    }
    CloseHandle(pipe);
    return -1;
}
#endif

int forte_mcp_read_line(char *buffer, size_t capacity) {
    if (!buffer || capacity < 2) return -1;
    size_t used = 0;
    int overflow = 0;
    for (;;) {
        const int ch = getchar();
        if (ch == EOF) return used == 0 && !overflow ? 0 : -1;
        if (ch == '\n') {
            if (overflow) return -1;
            buffer[used] = '\0';
            return (int)used;
        }
        if (ch == '\r') continue;
        if (used + 1 >= capacity) { overflow = 1; continue; }
        buffer[used++] = (char)ch;
    }
}

int forte_mcp_write_line(const char *buffer, size_t length) {
    if (!buffer || fwrite(buffer, 1, length, stdout) != length || fputc('\n', stdout) == EOF || fflush(stdout) != 0)
        return -1;
    return 0;
}
