// SPDX-License-Identifier: MIT
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>

#define _In_
#define _In_opt_
#define _Inout_
#define _Inout_opt_
#define _Out_
#define _Out_opt_
#define _In_reads_(x)
#define _In_reads_bytes_(x)
#define _Inout_updates_bytes_(x)
#define _Out_writes_bytes_(x)
#define _Out_writes_bytes_all_(x)
#define UNREFERENCED_PARAMETER(x) ((void)(x))

typedef unsigned char       UCHAR;
typedef unsigned char      *PUCHAR;
typedef unsigned long       ULONG;
typedef unsigned long      *PULONG;
typedef unsigned short      USHORT;
typedef int                 BOOLEAN;
typedef int                 INT;
typedef short               INT16;
typedef void                VOID;
typedef void               *PVOID;
typedef long                NTSTATUS;
typedef size_t              SIZE_T;

#define TRUE  1
#define FALSE 0

#define STATUS_SUCCESS                   ((NTSTATUS)0x00000000L)
#define STATUS_NO_MORE_ENTRIES           ((NTSTATUS)0x8000001AL)
#define STATUS_INVALID_PARAMETER         ((NTSTATUS)0xC000000DL)
#define STATUS_BUFFER_TOO_SMALL          ((NTSTATUS)0xC0000023L)
#define STATUS_NOT_FOUND                 ((NTSTATUS)0xC0000225L)
#define STATUS_MORE_PROCESSING_REQUIRED  ((NTSTATUS)0xC0000016L)

#define NT_SUCCESS(s) (((NTSTATUS)(s)) >= 0)

#define RtlMoveMemory(dst, src, n)  memmove((dst), (src), (n))
#define RtlCopyMemory(dst, src, n)  memcpy((dst), (src), (n))
#define RtlZeroMemory(dst, n)       memset((dst), 0, (n))
#define DbgPrint(fmt, ...)          printf("[DbgPrint] " fmt, ##__VA_ARGS__)
