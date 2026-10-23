#ifndef FORTE_CONTROL_C_H
#define FORTE_CONTROL_C_H

#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return the per-user endpoint used by both the player and MCP bridge. */
int forte_control_endpoint(char *out, size_t capacity);

/* A single-client, nonblocking local server. */
void *forte_control_server_create(const char *endpoint);
int forte_control_server_poll(void *server, char *request, size_t capacity);
int forte_control_server_reply(void *server, const char *reply, size_t length);
void forte_control_server_destroy(void *server);

/* Send one newline-framed request and receive one newline-framed response. */
int forte_control_client_call(const char *endpoint, const char *request, size_t request_length,
                              char *response, size_t response_capacity);

/* Blocking line-oriented stdio helpers for the MCP stdio transport. */
int forte_mcp_read_line(char *buffer, size_t capacity);
int forte_mcp_write_line(const char *buffer, size_t length);

#ifdef __cplusplus
}
#endif
#endif
