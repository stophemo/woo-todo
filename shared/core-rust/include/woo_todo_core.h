#ifndef WOO_TODO_CORE_H
#define WOO_TODO_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/* 返回值均为 UTF-8 JSON；调用方必须使用 woo_todo_string_free 释放。 */
char *woo_todo_core_call(const char *request_json);
char *woo_todo_repository_open(const char *database_path);
char *woo_todo_repository_call(uint64_t handle, const char *request_json);
char *woo_todo_repository_close(uint64_t handle);
void woo_todo_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
