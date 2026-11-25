#ifndef _WIN32

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#if defined(__APPLE__)
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#endif

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "moonbit.h"

MOONBIT_FFI_EXPORT
void *ms_posix_opendir(moonbit_bytes_t path, int32_t path_len) {
  if (path_len < 0 || memchr(path, '\0', (size_t)path_len) != NULL) {
    errno = EINVAL;
    return NULL;
  }
  char *copy = malloc((size_t)path_len + 1);
  if (copy == NULL) {
    return NULL;
  }
  memcpy(copy, path, (size_t)path_len);
  copy[path_len] = '\0';
  DIR *dir = opendir(copy);
  int saved_errno = errno;
  free(copy);
  errno = saved_errno;
  return dir;
}

MOONBIT_FFI_EXPORT
int32_t ms_posix_dir_is_null(void *dir) {
  return dir == NULL;
}

MOONBIT_FFI_EXPORT
int32_t ms_posix_errno(void) {
  return errno;
}

/* Byte-path helpers used by the real file system tests. */
MOONBIT_FFI_EXPORT
int32_t ms_test_mkdir(moonbit_bytes_t path, int32_t path_len) {
  if (path_len < 0 || memchr(path, '\0', (size_t)path_len) != NULL) {
    errno = EINVAL;
    return -1;
  }
  char *copy = malloc((size_t)path_len + 1);
  if (copy == NULL) {
    return -1;
  }
  memcpy(copy, path, (size_t)path_len);
  copy[path_len] = '\0';
  int result = mkdir(copy, 0700);
  int saved_errno = errno;
  free(copy);
  errno = saved_errno;
  return result;
}

MOONBIT_FFI_EXPORT
int32_t ms_test_create_file(
  moonbit_bytes_t path,
  int32_t path_len,
  moonbit_bytes_t contents,
  int32_t contents_len
) {
  if (path_len < 0 || contents_len < 0 ||
      memchr(path, '\0', (size_t)path_len) != NULL) {
    errno = EINVAL;
    return -1;
  }
  char *copy = malloc((size_t)path_len + 1);
  if (copy == NULL) {
    return -1;
  }
  memcpy(copy, path, (size_t)path_len);
  copy[path_len] = '\0';
  int fd = open(copy, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  int saved_errno = errno;
  free(copy);
  if (fd < 0) {
    errno = saved_errno;
    return -1;
  }
  int32_t offset = 0;
  while (offset < contents_len) {
    ssize_t written = write(fd, contents + offset, (size_t)(contents_len - offset));
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      saved_errno = errno;
      close(fd);
      errno = saved_errno;
      return -1;
    }
    if (written == 0) {
      close(fd);
      errno = EIO;
      return -1;
    }
    offset += (int32_t)written;
  }
  return close(fd);
}

MOONBIT_FFI_EXPORT
int32_t ms_test_unlink(moonbit_bytes_t path, int32_t path_len) {
  if (path_len < 0 || memchr(path, '\0', (size_t)path_len) != NULL) {
    errno = EINVAL;
    return -1;
  }
  char *copy = malloc((size_t)path_len + 1);
  if (copy == NULL) {
    return -1;
  }
  memcpy(copy, path, (size_t)path_len);
  copy[path_len] = '\0';
  int result = unlink(copy);
  int saved_errno = errno;
  free(copy);
  errno = saved_errno;
  return result;
}

MOONBIT_FFI_EXPORT
int32_t ms_test_rmdir(moonbit_bytes_t path, int32_t path_len) {
  if (path_len < 0 || memchr(path, '\0', (size_t)path_len) != NULL) {
    errno = EINVAL;
    return -1;
  }
  char *copy = malloc((size_t)path_len + 1);
  if (copy == NULL) {
    return -1;
  }
  memcpy(copy, path, (size_t)path_len);
  copy[path_len] = '\0';
  int result = rmdir(copy);
  int saved_errno = errno;
  free(copy);
  errno = saved_errno;
  return result;
}

/*
 * Return the byte length, zero at end-of-directory, -1 on an OS error, and -2
 * when the name does not fit. The caller owns the destination buffer.
 */
MOONBIT_FFI_EXPORT
int32_t ms_posix_readdir(void *handle, moonbit_bytes_t dst, int32_t capacity) {
  if (capacity < 0) {
    return -2;
  }
  errno = 0;
  struct dirent *entry = readdir((DIR *)handle);
  if (entry == NULL) {
    return errno == 0 ? 0 : -1;
  }
  size_t length = 0;
  while (length < (size_t)capacity && entry->d_name[length] != '\0') {
    length++;
  }
  if (length == (size_t)capacity && entry->d_name[length] != '\0') {
    const char *tail = entry->d_name + length;
    while (*tail != '\0') {
      length++;
      tail++;
    }
    return -2;
  }
  memcpy(dst, entry->d_name, length);
  return (int32_t)length;
}

MOONBIT_FFI_EXPORT
int32_t ms_posix_fstatat(
  void *handle,
  moonbit_bytes_t name,
  int32_t name_len,
  int64_t *out,
  int32_t out_len
) {
  if (name_len <= 0 || out_len < 6 || memchr(name, '\0', (size_t)name_len) != NULL) {
    errno = EINVAL;
    return -1;
  }
  char *name_copy = malloc((size_t)name_len + 1);
  if (name_copy == NULL) {
    return -1;
  }
  memcpy(name_copy, name, (size_t)name_len);
  name_copy[name_len] = '\0';
  struct stat info;
  int result = fstatat(
    dirfd((DIR *)handle), name_copy, &info, AT_SYMLINK_NOFOLLOW
  );
  int saved_errno = errno;
  free(name_copy);
  if (result != 0) {
    errno = saved_errno;
    return -1;
  }
  out[0] = (int64_t)info.st_mode;
  out[1] = (int64_t)info.st_size;
#if defined(__APPLE__)
  out[2] = (int64_t)info.st_mtimespec.tv_sec;
  out[3] = (int64_t)info.st_mtimespec.tv_nsec;
#else
  out[2] = (int64_t)info.st_mtim.tv_sec;
  out[3] = (int64_t)info.st_mtim.tv_nsec;
#endif
  out[4] = (int64_t)info.st_dev;
  out[5] = (int64_t)info.st_ino;
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t ms_posix_stat(
  moonbit_bytes_t path,
  int32_t path_len,
  int64_t *out,
  int32_t out_len
) {
  if (path_len < 0 || out_len < 6 || memchr(path, '\0', (size_t)path_len) != NULL) {
    errno = EINVAL;
    return -1;
  }
  char *copy = malloc((size_t)path_len + 1);
  if (copy == NULL) {
    return -1;
  }
  memcpy(copy, path, (size_t)path_len);
  copy[path_len] = '\0';
  struct stat info;
  int result = stat(copy, &info);
  int saved_errno = errno;
  free(copy);
  if (result != 0) {
    errno = saved_errno;
    return -1;
  }
  out[0] = (int64_t)info.st_mode;
  out[1] = (int64_t)info.st_size;
#if defined(__APPLE__)
  out[2] = (int64_t)info.st_mtimespec.tv_sec;
  out[3] = (int64_t)info.st_mtimespec.tv_nsec;
#else
  out[2] = (int64_t)info.st_mtim.tv_sec;
  out[3] = (int64_t)info.st_mtim.tv_nsec;
#endif
  out[4] = (int64_t)info.st_dev;
  out[5] = (int64_t)info.st_ino;
  return 0;
}

MOONBIT_FFI_EXPORT
void ms_posix_closedir(void *handle) {
  if (handle != NULL) {
    closedir((DIR *)handle);
  }
}

/* Return 0 on success, -1 on an OS error, and -2 when the result is too long. */
MOONBIT_FFI_EXPORT
int32_t ms_posix_realpath(
  moonbit_bytes_t path,
  int32_t path_len,
  moonbit_bytes_t dst,
  int32_t capacity
) {
  if (path_len < 0 || capacity < 0 || memchr(path, '\0', (size_t)path_len) != NULL) {
    errno = EINVAL;
    return -1;
  }
  char *copy = malloc((size_t)path_len + 1);
  if (copy == NULL) {
    return -1;
  }
  memcpy(copy, path, (size_t)path_len);
  copy[path_len] = '\0';
  char *resolved = realpath(copy, NULL);
  int saved_errno = errno;
  free(copy);
  if (resolved == NULL) {
    errno = saved_errno;
    return -1;
  }
  size_t length = strlen(resolved);
  if (length > (size_t)capacity) {
    free(resolved);
    return -2;
  }
  memcpy(dst, resolved, length);
  free(resolved);
  return 0;
}

#endif
