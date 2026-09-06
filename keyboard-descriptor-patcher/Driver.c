// SPDX-License-Identifier: MIT
//
// MagicKbDesc — KMDF lower filter driver entry points.
// See MagicKbDesc.h for architectural overview.

#include "MagicKbDesc.h"

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG config;
    NTSTATUS status;

    KdPrint(("MagicKbDesc: DriverEntry\n"));

    WDF_DRIVER_CONFIG_INIT(&config, MagicKbDescEvtDeviceAdd);
    config.DriverPoolTag = MAGICKBDESC_POOL_TAG;

    status = WdfDriverCreate(DriverObject,
                             RegistryPath,
                             WDF_NO_OBJECT_ATTRIBUTES,
                             &config,
                             WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        KdPrint(("MagicKbDesc: WdfDriverCreate failed 0x%X\n", status));
    }
    return status;
}

NTSTATUS
MagicKbDescEvtDeviceAdd(
    _In_    WDFDRIVER       Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
{
    WDF_OBJECT_ATTRIBUTES   deviceAttributes;
    WDFDEVICE               device;
    WDF_IO_QUEUE_CONFIG     queueConfig;
    NTSTATUS                status;

    UNREFERENCED_PARAMETER(Driver);

    // Register as a lower filter — hidbth.sys is still the function
    // driver; we sit between it and BthEnum.
    WdfFdoInitSetFilter(DeviceInit);

    WDF_OBJECT_ATTRIBUTES_INIT(&deviceAttributes);

    status = WdfDeviceCreate(&DeviceInit, &deviceAttributes, &device);
    if (!NT_SUCCESS(status)) {
        KdPrint(("MagicKbDesc: WdfDeviceCreate failed 0x%X\n", status));
        return status;
    }

    // Default queue dispatches IRP_MJ_INTERNAL_DEVICE_CONTROL — that's
    // where IOCTL_HID_GET_REPORT_DESCRIPTOR arrives.
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queueConfig,
                                           WdfIoQueueDispatchParallel);
    queueConfig.EvtIoInternalDeviceControl = MagicKbDescEvtIoInternalDeviceControl;

    status = WdfIoQueueCreate(device,
                              &queueConfig,
                              WDF_NO_OBJECT_ATTRIBUTES,
                              WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        KdPrint(("MagicKbDesc: WdfIoQueueCreate failed 0x%X\n", status));
        return status;
    }

    KdPrint(("MagicKbDesc: device added as filter on HID stack\n"));
    return STATUS_SUCCESS;
}
