#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OlicoHandle OlicoHandle;

OlicoHandle *olico_core_new(const char *data_dir);
void olico_core_free(OlicoHandle *handle);
char *olico_dispatch(OlicoHandle *handle, const char *request_json);
void olico_string_free(char *ptr);

#ifdef __cplusplus
}
#endif
